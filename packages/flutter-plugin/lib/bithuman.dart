// bithuman — Flutter plugin entrypoint.
//
// One-package access to the bitHuman avatar engine on iOS and macOS.
// See ARCHITECTURE.md for the per-platform delivery story.
//
// Apache-2.0; (c) bitHuman.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, HttpClient, HttpClientResponse, Process;
import 'dart:typed_data' show Int16List, Uint8List;

import 'package:flutter/services.dart';

const _channel = MethodChannel('ai.bithuman.avatar');

/// One loaded avatar. Owns a native texture; render with
/// `Texture(textureId: avatar.textureId)`.
class BithumanAvatar {
  BithumanAvatar._(this.textureId);

  /// Flutter texture id — pass to `Texture(textureId: ...)`.
  final int textureId;

  bool _disposed = false;

  // Live avatars by texture id, for routing native→Dart pushes
  // (frameDimsChanged / pipEvent) to the right instance.
  static final Map<int, BithumanAvatar> _instances = {};
  static bool _nativeCallbacksInstalled = false;

  /// Native→Dart pushes on the shared channel. Installed once, before the
  /// first load. Unknown texture ids (e.g. an event racing a dispose) are
  /// dropped.
  static void _installNativeCallbacks() {
    if (_nativeCallbacksInstalled) return;
    _nativeCallbacksInstalled = true;
    _channel.setMethodCallHandler((call) async {
      final args = call.arguments as Map?;
      final id = args?['textureId'];
      final avatar = id is int ? _instances[id] : null;
      if (avatar == null) return null;
      switch (call.method) {
        case 'frameDimsChanged':
          // The native stream's dims changed (Essence2 HEAD/FULL display-mode
          // switch, Essence's lazy first report). Adopt + notify so layouts
          // driven by frameWidth/frameHeight re-fit instead of stretching
          // the new stream into a stale box.
          final w = args?['width'] as int? ?? 0;
          final h = args?['height'] as int? ?? 0;
          if (w > 0 && h > 0) {
            avatar._frameWidth = w;
            avatar._frameHeight = h;
            avatar._frameSizeController.add(null);
          }
        case 'pipEvent':
          // iOS system Picture-in-Picture lifecycle:
          // started | failed | stopped | restore (user tapped restore).
          avatar._pipController.add(args?['event'] as String? ?? '');
      }
      return null;
    });
  }

  // Monotonic generation for the mic EventChannel, bumped on every [audioStart]
  // so each VP-IO session gets a UNIQUELY-NAMED mic channel
  // (`…/<textureId>/<gen>`). This is what makes rapid voice/identity switches
  // safe: a Flutter EventChannel keys its whole lifecycle on the channel NAME
  // (one handler slot per name), so a previous session's in-flight `cancel`
  // (and its `setMessageHandler(name, null)`) on a REUSED name lands on the new
  // session's handler and nulls its native `micEventSink` → a permanently dead
  // mic ("#50/#100 DROPPED: no Dart subscriber"). A unique name per session
  // decouples them entirely. Read once per [micStream] access, right after the
  // matching [audioStart] await (the realtime session's sole caller).
  int _micGen = 0;

  /// Load a model from a local file path.
  ///
  /// Pass [apiSecret] (your bitHuman developer secret) to authenticate the
  /// metered engine before any frames are produced. The public-release
  /// libessence requires this — without a successful auth the runtime stays
  /// in the unauthenticated state and `pull_frame` returns no frames (black
  /// canvas). The dev-only `BITHUMAN_UNMETERED=1` bypass is compiled out of
  /// release builds, so a real secret is the supported path.
  ///
  /// Engine swap (the same UI, a different engine): the default is Essence
  /// (libessence, `.imx`). Pass [engine] = `'elevate'` to drive the Essence2
  /// (light-avatar photoreal) engine instead — [imxPath] is then the `.lab`
  /// path, [motionDir] the teacher-onnx dir, and [chunk] the frames-per-flush
  /// (16 = realtime on Apple Silicon; use 2 on iOS for lower latency/memory).
  /// Essence2 runs on macOS + iOS arm64.
  static Future<BithumanAvatar> load(
    String imxPath, {
    String? apiSecret,
    String engine = 'essence',
    String? motionDir,
    int chunk = 16,
  }) async {
    _installNativeCallbacks();
    final id = await _channel.invokeMethod<int>('load', {
      'path': imxPath,
      if (apiSecret != null && apiSecret.isNotEmpty) 'apiSecret': apiSecret,
      'engine': engine,
      if (motionDir != null) 'motionDir': motionDir,
      'chunk': chunk,
    });
    if (id == null) throw const BithumanAvatarException('load returned null');
    final avatar = BithumanAvatar._(id);
    _instances[id] = avatar;
    try {
      final size = await _channel
          .invokeMapMethod<String, int>('frameSize', {'textureId': id});
      avatar._frameWidth = size?['width'] ?? 0;
      avatar._frameHeight = size?['height'] ?? 0;
    } catch (_) {
      // older native side without frameSize — caller uses a layout fallback
    }
    // Seed readiness before returning (a warm engine reports ready on this
    // first probe, so [isReady] is accurate the moment load resolves); if
    // the engine is still warming, keep polling every 500 ms — a simple,
    // robust one-shot transition that needs no extra EventChannel plumbing.
    await avatar._checkReady();
    return avatar;
  }

  bool _ready = false;
  final Completer<void> _readyCompleter = Completer<void>();
  Timer? _readyPoll;

  /// True once the engine's speech path is live. Essence: immediately after
  /// [load]. Essence2: after the deferred actor/director warm-up finishes —
  /// first run on a machine pays a one-time ANE/CoreML compile (~2 min);
  /// warm launches take a few seconds. The native side DROPS audio pushed
  /// before this flips (it would be stale by ready time), so gate mic /
  /// connect UX on it.
  bool get isReady => _ready;

  /// Completes when [isReady] flips true. Also completes on [dispose] so
  /// awaiters never hang on a torn-down avatar — re-check [isReady] after
  /// awaiting if the distinction matters.
  Future<void> get ready => _readyCompleter.future;

  Future<void> _checkReady() async {
    if (_disposed) return;
    bool r;
    try {
      r = await _channel
              .invokeMethod<bool>('isReady', {'textureId': textureId}) ??
          true;
    } catch (_) {
      r = true; // older native side without isReady — never wedge callers
    }
    if (_disposed) return;
    if (r) {
      _ready = true;
      if (!_readyCompleter.isCompleted) _readyCompleter.complete();
    } else {
      _readyPoll = Timer(const Duration(milliseconds: 500), _checkReady);
    }
  }

  int _frameWidth = 0;
  int _frameHeight = 0;

  /// Native frame width/height in pixels. 0 when the engine hasn't reported
  /// yet (the essence fixture reports lazily) — use a layout fallback then.
  int get frameWidth => _frameWidth;
  int get frameHeight => _frameHeight;

  final StreamController<void> _frameSizeController =
      StreamController<void>.broadcast();

  /// Fires whenever the NATIVE stream's frame dims change post-load —
  /// Essence2 HEAD/FULL display-mode switches re-size the stream (full
  /// portrait canvas ↔ square head frames), and Essence reports lazily.
  /// [frameWidth]/[frameHeight] are already updated when this fires;
  /// listeners should relayout anything fitted to them (the avatar canvas
  /// would otherwise STRETCH the new stream into the stale box).
  Stream<void> get frameSizeChanges => _frameSizeController.stream;

  /// Re-query the native frame size (it changes when the display mode
  /// switches — see [setDisplayMode]). Returns true when the size changed.
  Future<bool> refreshFrameSize() async {
    if (_disposed) return false;
    try {
      final size = await _channel
          .invokeMapMethod<String, int>('frameSize', {'textureId': textureId});
      final w = size?['width'] ?? 0;
      final h = size?['height'] ?? 0;
      if (w > 0 && h > 0 && (w != _frameWidth || h != _frameHeight)) {
        _frameWidth = w;
        _frameHeight = h;
        return true;
      }
    } catch (_) {/* older native side */}
    return false;
  }

  /// Switch the Essence2 engine's display mode: 'full' (the composited
  /// canvas) or 'head' (the actor's square talking-head frames — much
  /// cheaper; what the macOS bubble mode shows). The engine's continuous
  /// clock keeps running across switches, so lipsync continues mid-
  /// utterance. Returns true when the native engine accepted the switch;
  /// false on Essence, on engines without the symbol, or on older plugin
  /// builds — callers keep their UI-side fallback (e.g. the bubble's
  /// center-crop) when this returns false. The reported [frameWidth]/
  /// [frameHeight] converge to the new mode's dims shortly after the
  /// switch — poll [refreshFrameSize] (the native side resizes the texture
  /// per pulled frame regardless).
  Future<bool> setDisplayMode(String mode) async {
    if (_disposed) return false;
    assert(mode == 'full' || mode == 'head');
    try {
      final ok = await _channel.invokeMethod<bool>('setDisplayMode', {
            'textureId': textureId,
            'mode': mode,
          }) ??
          false;
      if (ok) await refreshFrameSize();
      return ok;
    } catch (_) {
      return false; // older native side / engine without be_essence2_set_mode
    }
  }

  /// Bubble battery saver: while the head-only bubble is shown
  /// ([setDisplayMode] 'head'), let the native render tick PAUSE frame pulls
  /// once the stream has been idle ~30 s. The Essence2 engine paces production
  /// to pulls, so its idle (DiT breathing) generation quiesces and the bubble
  /// freezes on the last head frame; the next utterance's audio resumes pulls
  /// the same tick. No-op on Essence and older native sides.
  Future<void> setIdleHold(bool hold) async {
    if (_disposed) return;
    try {
      await _channel.invokeMethod('setIdleHold', {
        'textureId': textureId,
        'hold': hold,
      });
    } catch (_) {/* older native side without setIdleHold */}
  }

  final StreamController<String> _pipController =
      StreamController<String>.broadcast();

  /// iOS system Picture-in-Picture lifecycle events:
  /// `started` (PiP window is up), `failed` (didn't come up — fall back to
  /// an in-app presentation), `stopped` (PiP window closed), `restore`
  /// (the user tapped the PiP restore button — bring the full UI back).
  Stream<String> get pipEvents => _pipController.stream;

  /// iOS: whether system Picture-in-Picture is supported on this device.
  /// Always false on macOS / the simulator without PiP support.
  Future<bool> pipAvailable() async {
    if (_disposed) return false;
    try {
      return await _channel.invokeMethod<bool>('pipAvailable') ?? false;
    } catch (_) {
      return false; // older native side
    }
  }

  /// iOS: float this avatar over the SYSTEM in Picture-in-Picture (the
  /// minimize-to-bubble presentation that survives going home / app
  /// switching). The native side tees the engine's pixel-buffer stream into
  /// a sample-buffer PiP layer, rendering the circular bubble mask into the
  /// frames. Pair with [setDisplayMode]('head') for the cheap square head
  /// stream. Returns false when PiP can't even be attempted (unsupported
  /// device / macOS / older native side) — keep an in-app fallback then.
  /// The async outcome arrives on [pipEvents] (`started` / `failed`).
  Future<bool> pipStart() async {
    if (_disposed) return false;
    try {
      return await _channel
              .invokeMethod<bool>('pipStart', {'textureId': textureId}) ??
          false;
    } catch (_) {
      return false; // older native side without PiP
    }
  }

  /// Tear down the system PiP session (no-op when inactive).
  Future<void> pipStop() async {
    if (_disposed) return;
    try {
      await _channel.invokeMethod('pipStop', {'textureId': textureId});
    } catch (_) {/* older native side */}
  }

  /// macOS: resize the app window to the canvas aspect (portrait canvas ->
  /// portrait window), spanning ~90% of the limiting screen dimension,
  /// centered, with the aspect locked for user resizes. No-op on iOS.
  /// Uses the engine-reported frame size; [fallbackWidth]/[fallbackHeight]
  /// apply when the engine hasn't reported (legacy essence canvas).
  Future<void> fitWindowToCanvas({
    int fallbackWidth = 1248,
    int fallbackHeight = 704,
  }) async {
    final w = _frameWidth > 0 ? _frameWidth : fallbackWidth;
    final h = _frameHeight > 0 ? _frameHeight : fallbackHeight;
    await _channel.invokeMethod('fitWindowToCanvas', {'width': w, 'height': h});
  }

  /// Push 16 kHz mono int16 PCM. Native side schedules `tick_compose` at
  /// 25 fps as the queue drains; new frames flow into the texture
  /// automatically.
  Future<void> pushAudio(Int16List pcm) async {
    if (_disposed) throw const BithumanAvatarException('avatar is disposed');
    await _channel.invokeMethod('pushAudio', {
      'textureId': textureId,
      'pcm': pcm.buffer.asUint8List(pcm.offsetInBytes, pcm.lengthInBytes),
    });
  }

  /// Start the unified VP-IO audio engine on the platform side. Owns
  /// mic capture (returned via [micStream]) AND speaker playback (fed
  /// via [playSpeakerPCM]) in a single AVAudioEngine with Apple's Voice
  /// Processing I/O enabled. This is what gives you:
  ///   - Acoustic echo cancellation: bot's voice is subtracted from
  ///     the mic input → no self-talk feedback loop
  ///   - Sample-accurate A/V sync: speaker and avatar lipsync drain
  ///     from the SAME source buffer at the SAME instant
  /// Must be called before [playSpeakerPCM] or [micStream] yield data.
  /// [enableMic] false = speaker-only session (no VP-IO mic, no mic-permission
  /// prompt) — used for a TEXT-only conversation. Voice sessions pass true.
  Future<void> audioStart({int vadThreshold = 0, bool enableMic = true}) async {
    if (_disposed) throw const BithumanAvatarException('avatar is disposed');
    // Bump BEFORE the await so the value native receives equals the one
    // [micStream] reads next (called right after this resolves) — the unique
    // mic-channel name must match byte-for-byte on both sides.
    _micGen++;
    await _channel.invokeMethod('audioStart', {
      'textureId': textureId,
      'vadThreshold': vadThreshold,
      'micGen': _micGen,
      'enableMic': enableMic,
    });
  }

  /// Tear down the VP-IO audio engine. Mic tap stops; pending speaker
  /// buffers are discarded.
  Future<void> audioStop() async {
    if (_disposed) return;
    await _channel.invokeMethod('audioStop', {'textureId': textureId});
  }

  /// Whether LOCAL mode (the on-device converse brain) can run on this OS.
  /// The brain binds Apple's SpeechAnalyzer, which is `@available(macOS 26.0,
  /// iOS 26.0)`, so on older systems [localAudioStart] would fail with
  /// UNSUPPORTED_OS at session start. Probe this once at startup and disable the
  /// LOCAL-mode toggle (with a clear reason) when it returns false, rather than
  /// surfacing a cryptic runtime error. False on non-Apple platforms and on
  /// older plugin builds without the probe.
  static Future<bool> isLocalModeSupported() async {
    try {
      return await _channel.invokeMethod<bool>('isLocalModeSupported') ?? false;
    } catch (_) {
      return false; // non-Apple platform / older native side without the probe
    }
  }

  /// LOCAL mode (macOS): run the on-device converse brain (Apple SpeechAnalyzer
  /// → Qwen → Supertonic) instead of the cloud Realtime WebSocket. Reuses the
  /// same VP-IO audio + avatar Texture as [audioStart]; the brain feeds the
  /// avatar lipsync + speaker directly on-device. [ggufPath] is the local LLM
  /// .gguf; [supertonicAssets] is the Supertonic ONNX assets dir. The metered
  /// avatar render still needs BITHUMAN_API_SECRET set when the avatar loaded.
  Future<void> localAudioStart({
    required String ggufPath,
    String? supertonicAssets,
    String? voice,
    int vadThreshold = 0,
    String systemPrompt = '',
  }) async {
    if (_disposed) throw const BithumanAvatarException('avatar is disposed');
    await _channel.invokeMethod('localAudioStart', {
      'textureId': textureId,
      'ggufPath': ggufPath,
      if (supertonicAssets != null) 'supertonicAssets': supertonicAssets,
      if (voice != null) 'voice': voice,
      'vadThreshold': vadThreshold,
      'systemPrompt': systemPrompt,
    });
  }

  /// Tear down the local converse brain + audio engine.
  Future<void> localAudioStop() async {
    if (_disposed) return;
    await _channel.invokeMethod('localAudioStop', {'textureId': textureId});
  }

  /// LOCAL mode: feed a typed user message to the on-device brain (same as a
  /// spoken turn — the agent replies with voice + avatar). Forwards to the
  /// active LocalConverseController's `ConverseSession.pushText`.
  Future<void> localPushText(String text) async {
    if (_disposed) return;
    await _channel.invokeMethod('localPushText', {'text': text});
  }

  /// LOCAL mode: mute/unmute the local mic. Gates the mic→brain (STT) forward
  /// in the native RealtimeAudioIO; everything else (speaker, avatar) is
  /// untouched, so the user can mute themselves mid-conversation.
  Future<void> localSetMuted(bool muted) async {
    if (_disposed) return;
    await _channel.invokeMethod('localSetMuted', {'muted': muted});
  }

  /// Converse brain events (local mode) for captions + status:
  /// `{"kind":"state","state":int}` (0 idle/1 listening/2 thinking/3 speaking)
  /// or `{"kind":"bot"|"user","text":String}`.
  Stream<Map<dynamic, dynamic>> get converseEvents {
    final ch = EventChannel('ai.bithuman.avatar.converse/$textureId');
    return ch.receiveBroadcastStream().map((e) => e as Map);
  }

  /// Cut the agent off mid-sentence. Flushes the VP-IO player's
  /// scheduled-buffer queue (so the speaker stops within ~10 ms) and
  /// wipes the avatar's lipsync audio buffer (so the mouth stops
  /// animating the cancelled response and returns to looping idle).
  /// Call from the Realtime session's `speech_started` handler so
  /// barge-in fires the instant the user opens their mouth, not at
  /// end-of-sentence.
  Future<void> interrupt() async {
    if (_disposed) return;
    await _channel.invokeMethod('interrupt', {'textureId': textureId});
  }

  /// Hint whether the agent is audibly speaking right now. Android
  /// frames-path only: the plugin maps drive-protocol playback onto the
  /// bundle's TALKING frame ranges while true and its IDLE (mouth-closed)
  /// ranges while false (`motion_ranges.json` sidecar; no sidecar = no-op).
  /// Other platforms drive the mouth from real lipsync audio and don't
  /// implement this method — call sites must gate on Platform.isAndroid.
  Future<void> setSpeaking(bool speaking) async {
    if (_disposed) return;
    await _channel.invokeMethod('setSpeaking', {
      'textureId': textureId,
      'speaking': speaking,
    });
  }

  /// Play 24 kHz mono PCM16 bot audio AND drive the avatar's lipsync
  /// from the same chunk. The native side schedules the buffer on the
  /// VP-IO player node and simultaneously pushes a 16 kHz copy into
  /// the avatar runtime — they share a clock so A/V cannot drift.
  Future<void> playSpeakerPCM(Uint8List pcm24kPcm16le) async {
    if (_disposed) throw const BithumanAvatarException('avatar is disposed');
    await _channel.invokeMethod('playSpeakerPCM', {
      'textureId': textureId,
      'pcm': pcm24kPcm16le,
    });
  }

  /// Signal the avatar that the bot's turn has ended (e.g. OpenAI
  /// `response.done`). The native side flushes the final partial lipsync chunk
  /// so the last word isn't clipped. Call ONLY after all of the turn's audio has
  /// been handed to [playSpeakerPCM] (defer past any client-side pacing), and not
  /// after a barge. Safe to call repeatedly; a no-op when nothing is pending.
  Future<void> notifyTurnEnd() async {
    if (_disposed) return;
    await _channel.invokeMethod('notifyTurnEnd', {'textureId': textureId});
  }

  /// Point the on-device expression-2 runtime at a DOWNLOADED per-agent model dir
  /// (student + audiotokenizer + canon). Pass null/'' to revert to the bundled
  /// default (A42). MUST be called BEFORE [load] (engine: expression2 (alias: embody)) — the next
  /// load warms the runtime from this dir; the shared w2v/taehv graphs always
  /// come from the app bundle. Static channel call (no live texture needed).
  static Future<void> setExpression2AgentDir(String? dir) async {
    await _channel.invokeMethod('setExpression2AgentDir', {'dir': dir ?? ''});
  }

  /// Current microphone authorization: `authorized` | `notDetermined` | `denied`.
  /// Drives the main-screen status chip (yellow when not yet `authorized`).
  static Future<String> micPermissionStatus() async =>
      (await _channel.invokeMethod<String>('micPermissionStatus')) ?? 'authorized';

  /// Request microphone access: prompts when undetermined, opens System Settings
  /// (Microphone) when previously denied. Returns the resulting status.
  static Future<String> requestMicPermission() async =>
      (await _channel.invokeMethod<String>('requestMicPermission')) ?? 'denied';

  /// Echo-cancelled mic capture as 24 kHz mono PCM16 chunks. Yields
  /// only between [audioStart] and [audioStop]. Forward the chunks
  /// straight to OpenAI Realtime — VP-IO has already removed the
  /// bot's voice from the signal.
  Stream<Uint8List> get micStream {
    // Name MUST match the native FlutterEventChannel exactly, gen and all.
    final ch = EventChannel('ai.bithuman.avatar.mic/$textureId/$_micGen');
    return ch.receiveBroadcastStream().map((event) {
      if (event is Uint8List) return event;
      if (event is List<int>) return Uint8List.fromList(event);
      return Uint8List(0);
    });
  }

  /// Attach the plugin's lipsync queue to OpenAI's bot-output audio
  /// flowing over a flutter_webrtc remote track. The iOS cloud path:
  /// the Swift side uses ObjC-runtime reflection against
  /// `FlutterWebRTCPlugin` + an `RTCAudioRenderer` that resamples the
  /// remote `RTCAudioTrack` for [trackId] to 16 kHz mono and pushes it
  /// into the same audio queue [pushAudio] uses. (macOS uses the
  /// WebSocket transport instead and never calls this.)
  ///
  /// **The source is the REMOTE WebRTC track only — the mic stream
  /// is never tapped.** That track on the bithuman WebRTC
  /// example is exclusively OpenAI's TTS output, so the avatar's
  /// mouth tracks what the user hears.
  ///
  /// Call AFTER [load] returns AND the WebRTC peer connection's
  /// `onTrack` callback has fired (so the track is registered with
  /// FlutterWebRTCPlugin). Pass `trackId = remoteAudioTrack.id`.
  /// Throws if the app doesn't actually ship flutter_webrtc.
  Future<void> attachWebrtcRemoteAudio(String trackId) async {
    if (_disposed) throw const BithumanAvatarException('avatar is disposed');
    await _channel.invokeMethod('attachWebrtcRemoteAudio', {
      'textureId': textureId,
      'trackId': trackId,
    });
  }

  /// Reverse of [attachWebrtcRemoteAudio] — also flushes any in-
  /// flight lipsync chunks so the mouth returns to idle when the
  /// session ends.
  Future<void> detachWebrtcRemoteAudio() async {
    if (_disposed) return;
    await _channel.invokeMethod('detachWebrtcRemoteAudio', {
      'textureId': textureId,
    });
  }

  /// Drop the underlying native runtime. Idempotent.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _instances.remove(textureId);
    _readyPoll?.cancel();
    _readyPoll = null;
    if (!_readyCompleter.isCompleted) _readyCompleter.complete();
    unawaited(_frameSizeController.close());
    unawaited(_pipController.close());
    await _channel.invokeMethod('dispose', {'textureId': textureId});
  }
}

class BithumanAvatarException implements Exception {
  const BithumanAvatarException(this.message);
  final String message;
  @override
  String toString() => 'BithumanAvatarException: $message';
}

/// One public agent from bithuman.ai/#explore.
class BithumanAgent {
  const BithumanAgent({
    required this.id,
    required this.name,
    required this.description,
    required this.category,
    required this.imageUrl,
    required this.modelUrl,
    required this.systemPrompt,
    required this.voiceId,
  });

  final String id;
  final String name;
  final String description;
  final String category;
  final String imageUrl;
  final String modelUrl;
  final String systemPrompt;
  final String voiceId;

  factory BithumanAgent.fromJson(Map<String, dynamic> j) => BithumanAgent(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        description: j['description'] as String? ?? '',
        category: j['category'] as String? ?? '',
        imageUrl: (j['image_url'] ?? j['poster'] ?? '') as String,
        modelUrl: (j['model_url'] ?? '') as String,
        systemPrompt: (j['system_prompt'] ?? j['prompt'] ?? '') as String,
        voiceId: (j['voice_id'] ?? '') as String,
      );
}

/// Fetch the public agent catalog from bithuman.ai.
///
/// Download + install a downloadable ON-DEVICE expression-2 agent bundle (a `.tar.gz`
/// of the per-identity CoreML files: student + audiotokenizer + canon.f32) into
/// `<cacheDir>/<code>/` and return that directory. Pass the result to
/// [BithumanAvatar.setExpression2AgentDir] before loading the expression-2 engine. The
/// shared w2v/taehv graphs ship in the app, so a bundle is only ~85 MB.
///
/// Cache-aware (re-returns an already-installed dir), https-only + optional host
/// allow-list (the bundle feeds CoreML), streams to a `.partial` then extracts
/// with the system `tar`. `onProgress(received,total)` ticks during download.
Future<String> downloadExpression2Agent(
  String code,
  String bundleUrl,
  String cacheDir, {
  Set<String>? allowedHosts,
  void Function(int received, int? total)? onProgress,
}) async {
  final safe = code.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  final destDir = Directory('$cacheDir/$safe');
  final marker = File('${destDir.path}/student_v4_forward_frame_cpuAndNE.mlpackage/Manifest.json');
  if (await marker.exists()) return destDir.path;   // already installed

  final uri = Uri.parse(bundleUrl);
  if (uri.scheme != 'https') {
    throw BithumanAvatarException('refusing non-https bundle_url: $bundleUrl');
  }
  if (allowedHosts != null && allowedHosts.isNotEmpty && !allowedHosts.contains(uri.host)) {
    throw BithumanAvatarException('bundle_url host not allowed: ${uri.host}');
  }
  final tmpDir = Directory(cacheDir);
  if (!await tmpDir.exists()) await tmpDir.create(recursive: true);
  final tgz = File('$cacheDir/$safe.tar.gz.partial');

  final client = HttpClient();
  try {
    final req = await client.getUrl(uri);
    req.followRedirects = false;
    final res = await req.close();
    if (res.statusCode != 200) {
      throw BithumanAvatarException('expression-2 bundle HTTP ${res.statusCode} from $bundleUrl');
    }
    final total = res.contentLength <= 0 ? null : res.contentLength;
    var received = 0;
    final sink = tgz.openWrite();
    try {
      await for (final chunk in res) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
      await sink.close();
    } catch (e) {
      try { await sink.close(); } catch (_) {}
      try { await tgz.delete(); } catch (_) {}
      rethrow;
    }
  } finally {
    client.close(force: true);
  }

  // Extract into a fresh dir (atomic-ish: extract to .tmp then rename).
  final stageDir = Directory('${destDir.path}.tmp');
  if (await stageDir.exists()) await stageDir.delete(recursive: true);
  await stageDir.create(recursive: true);
  final r = await Process.run('tar', ['-xzf', tgz.path, '-C', stageDir.path]);
  if (r.exitCode != 0) {
    try { await stageDir.delete(recursive: true); } catch (_) {}
    try { await tgz.delete(); } catch (_) {}
    throw BithumanAvatarException('expression-2 bundle extract failed: ${r.stderr}');
  }
  if (await destDir.exists()) await destDir.delete(recursive: true);
  await stageDir.rename(destDir.path);
  try { await tgz.delete(); } catch (_) {}
  if (!await marker.exists()) {
    throw BithumanAvatarException('expression-2 bundle missing student model after extract');
  }
  return destDir.path;
}

/// Download + install a downloadable ON-DEVICE expression-2 **`.avatar`** (the
/// self-describing identity container: a zip of manifest.json + student +
/// audiotokenizer + canon.f32 + idle.mp4) into `<cacheDir>/<code>/` and return
/// that directory. See docs/MODEL_FORMAT.md.
///
/// vs the legacy [downloadExpression2Agent] (.tar.gz): this verifies the package on
/// install — `unzip` CRC-checks every entry (catches a truncated/corrupt
/// download), then the manifest is checked for format + `requires_engine_abi`
/// compatibility with the app's bundled engine ([engineAbi]) + the required
/// per-identity files. A mismatch throws instead of loading a broken identity.
/// https-only + optional host allow-list; cache-aware (keyed on manifest.json so
/// a legacy tar-cache re-installs as a verified `.avatar`).
Future<String> downloadExpression2Avatar(
  String code,
  String avatarUrl,
  String cacheDir, {
  int engineAbi = 1,
  Set<String>? allowedHosts,
  void Function(int received, int? total)? onProgress,
}) async {
  final safe = code.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  final destDir = Directory('$cacheDir/$safe');
  final marker = File('${destDir.path}/manifest.json');
  final student = File('${destDir.path}/student_v4_forward_frame_cpuAndNE.mlpackage/Manifest.json');
  if (await marker.exists() && await student.exists()) return destDir.path;   // already installed

  final uri = Uri.parse(avatarUrl);
  if (uri.scheme != 'https') {
    throw BithumanAvatarException('refusing non-https avatar_url: $avatarUrl');
  }
  if (allowedHosts != null && allowedHosts.isNotEmpty && !allowedHosts.contains(uri.host)) {
    throw BithumanAvatarException('avatar_url host not allowed: ${uri.host}');
  }
  final tmpDir = Directory(cacheDir);
  if (!await tmpDir.exists()) await tmpDir.create(recursive: true);
  final zip = File('$cacheDir/$safe.avatar.partial');

  final client = HttpClient();
  try {
    final req = await client.getUrl(uri);
    req.followRedirects = false;
    final res = await req.close();
    if (res.statusCode != 200) {
      throw BithumanAvatarException('expression-2 avatar HTTP ${res.statusCode} from $avatarUrl');
    }
    final total = res.contentLength <= 0 ? null : res.contentLength;
    var received = 0;
    final sink = zip.openWrite();
    try {
      await for (final chunk in res) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
      await sink.close();
    } catch (e) {
      try { await sink.close(); } catch (_) {}
      try { await zip.delete(); } catch (_) {}
      rethrow;
    }
  } finally {
    client.close(force: true);
  }

  // Extract into a fresh staging dir. ★ ACCEPTS BOTH container forms (Phase-3):
  // sniff the 4-byte magic — a unified `IMX\0` container unpacks via the flat
  // TOC (same on-disk layout the zip path produced); else the legacy zip path
  // (`unzip` CRC-checks each entry → a corrupt/truncated download fails there).
  // Rollout is reversible: every shipped zip `.avatar` keeps loading unchanged.
  final stageDir = Directory('${destDir.path}.tmp');
  if (await stageDir.exists()) await stageDir.delete(recursive: true);
  await stageDir.create(recursive: true);
  try {
    await _extractAvatarContainer(zip, stageDir);
  } catch (e) {
    try { await stageDir.delete(recursive: true); } catch (_) {}
    try { await zip.delete(); } catch (_) {}
    throw BithumanAvatarException('expression-2 avatar extract failed (corrupt download?): $e');
  }

  Future<void> reject(String msg) async {
    try { await stageDir.delete(recursive: true); } catch (_) {}
    try { await zip.delete(); } catch (_) {}
    throw BithumanAvatarException(msg);
  }

  // Verify the manifest: format + ABI compatibility + required files present.
  final manFile = File('${stageDir.path}/manifest.json');
  if (!await manFile.exists()) { await reject('expression-2 avatar missing manifest.json'); }
  Map<String, dynamic> man;
  try {
    man = jsonDecode(await manFile.readAsString()) as Map<String, dynamic>;
  } catch (e) { await reject('expression-2 avatar manifest unreadable: $e'); return ''; }
  if (man['format'] != 'embody-avatar/1') { await reject('unexpected avatar format: ${man['format']}'); }
  final reqAbi = (man['requires_engine_abi'] as num?)?.toInt() ?? -1;
  if (reqAbi != engineAbi) {
    await reject('avatar engine ABI mismatch: needs $reqAbi, app engine is $engineAbi (update the app)');
  }
  for (final f in const [
    'student_v4_forward_frame_cpuAndNE.mlpackage/Manifest.json',
    'audiotokenizer_cpuAndNE.mlpackage/Manifest.json',
    'canon.f32',
  ]) {
    if (!await File('${stageDir.path}/$f').exists()) { await reject('avatar missing required file: $f'); }
  }

  if (await destDir.exists()) await destDir.delete(recursive: true);
  await stageDir.rename(destDir.path);
  try { await zip.delete(); } catch (_) {}
  return destDir.path;
}

/// Anonymous, no auth needed — these are the `visibility = public` agents
/// users see on https://www.bithuman.ai/#explore. Pass [category] (e.g.
/// 'Education') to scope to one of the site's catalog categories; omit it for
/// the full community catalog.
Future<List<BithumanAgent>> fetchPublicAgents({int limit = 60, String? category}) async {
  final query = StringBuffer(
      'https://www.bithuman.ai/api/agents?type=community&limit=$limit');
  if (category != null && category.isNotEmpty) {
    query.write('&category=${Uri.encodeQueryComponent(category)}');
  }
  final url = Uri.parse(query.toString());
  final client = HttpClient();
  try {
    final req = await client.getUrl(url);
    final HttpClientResponse res = await req.close();
    if (res.statusCode != 200) {
      throw BithumanAvatarException(
          'bithuman.ai catalog HTTP ${res.statusCode}');
    }
    final body = await res.transform(utf8.decoder).join();
    final j = jsonDecode(body) as Map<String, dynamic>;
    final list = (j['agents'] as List).cast<Map<String, dynamic>>();
    return list
        .where((a) => (a['model_url'] as String?)?.isNotEmpty ?? false)
        .map(BithumanAgent.fromJson)
        .toList(growable: false);
  } finally {
    client.close();
  }
}

/// Download `agent.modelUrl` into `<cacheDir>/<id>.imx`. Cached by id so
/// re-tapping the same avatar doesn't re-download. Creates the cache
/// directory if it doesn't exist (some platforms — especially macOS
/// sandbox — return a tmp path that hasn't been mkdir'd yet).
Future<String> downloadAgentImx(
  BithumanAgent agent,
  String cacheDir, {
  Set<String>? allowedHosts,
  void Function(int received, int? total)? onProgress,
}) async {
  final dir = Directory(cacheDir);
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
  // The catalog `id` comes from a public / MITM-able JSON feed, so never use
  // it raw in a filesystem path — a crafted '../' would escape cacheDir. Real
  // ids are alphanumeric, so this is a no-op for legit data (cache stays warm).
  final safeId = agent.id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  final local = File('$cacheDir/$safeId.imx');
  if (await local.exists() && (await local.length()) > 1024 * 1024) {
    return local.path;
  }
  // Refuse a non-https model_url: dart:io's HttpClient is NOT subject to App
  // Transport Security, so a catalog-supplied http:// (or loopback/LAN) URL
  // would otherwise be fetched in cleartext on macOS and fed to the native
  // .imx parser. Require TLS before opening the connection.
  final modelUri = Uri.parse(agent.modelUrl);
  if (modelUri.scheme != 'https') {
    throw BithumanAvatarException(
        'refusing non-https model_url: ${agent.modelUrl}');
  }
  // A poisoned/MITM'd catalog could point model_url at an attacker host whose
  // bytes then reach the closed-source native .imx parser. When the caller
  // supplies an allow-list, require the model to come from one of those hosts.
  if (allowedHosts != null &&
      allowedHosts.isNotEmpty &&
      !allowedHosts.contains(modelUri.host)) {
    throw BithumanAvatarException(
        'model_url host not allowed: ${modelUri.host}');
  }
  final client = HttpClient();
  try {
    final req = await client.getUrl(modelUri);
    // Don't follow redirects: legit catalog models are a direct 200 from the
    // allowlisted host, so a 30x can only be an attempt to bounce the download
    // off-allowlist (the scheme/host checks above validate the initial URL
    // only). A redirect therefore fails the status check below.
    req.followRedirects = false;
    final res = await req.close();
    if (res.statusCode != 200) {
      throw BithumanAvatarException(
          '.imx download HTTP ${res.statusCode} from ${agent.modelUrl}');
    }
    // Stream to a `.partial` file then rename, so a cancelled / failed
    // download doesn't leave a half-baked file that passes the "size > 1 MB"
    // cache check next time.
    final tmp = File('${local.path}.partial');
    final sink = tmp.openWrite();
    final total = res.contentLength <= 0 ? null : res.contentLength;
    var received = 0;
    try {
      await for (final chunk in res) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
      await sink.close();
    } catch (e) {
      try { await sink.close(); } catch (_) {}
      try { await tmp.delete(); } catch (_) {}
      rethrow;
    }
    await tmp.rename(local.path);
    // Validate the downloaded file before returning. An .imx must
    // start with the literal bytes "IMX\0" and be at least a few MB.
    final size = await local.length();
    if (size < 1024 * 1024) {
      await local.delete();
      throw BithumanAvatarException(
          'downloaded .imx is suspiciously small: $size bytes');
    }
    final magic = await local.openRead(0, 4).first;
    if (magic.length < 4 ||
        magic[0] != 0x49 || magic[1] != 0x4D ||
        magic[2] != 0x58 || magic[3] != 0x00) {
      await local.delete();
      throw BithumanAvatarException(
          'downloaded .imx has wrong magic header (expected "IMX\\0")');
    }
    return local.path;
  } finally {
    client.close();
  }
}

// ── Essence 2 (on-device Elevate) `.elevatedir` delivery ─────────────────────
// The Essence-2 on-device engine (`engine: 'essence2'` / the frozen `elevate`
// alias) loads from a local `.elevatedir` directory (meta.json + CoreML/ONNX).
// This is the Elevate twin of the Essence `.imx` model_url flow (fetchPublicAgents
// -> downloadAgentImx): a content-addressed catalog maps agent_id -> a gzip
// tarball of the bundle's contents + its sha256, and the client fetches the
// index, downloads a bundle, verifies it, and extracts it into a ready-to-load
// `.elevatedir`. Producer: essence-2 engine/light/*/ml/pipeline/publish_elevatedir.py
// (catalog "elevate-catalog-v1"; bundle "elevatedir-v*"). Before this the app had
// NO essence-2 download path — on-device Essence 2 could only run from a bundle
// baked on a dev machine (main.dart `_essence2GalleryEntries` TODO), so users
// could not download the Essence-2 demo agent to run it offline.

/// One entry from the Essence-2 (Elevate) delivery catalog: an agent id, the
/// https URL of its content-addressed `.tar.gz` bundle, the bundle's canonical
/// SHA-256 (verified on install so a tampered/substituted bundle is rejected
/// before it reaches the native loader), its byte size (for a progress bar), and
/// the bundle `format_version` (`elevatedir-v*`).
class Essence2CatalogEntry {
  const Essence2CatalogEntry({
    required this.agentId,
    required this.url,
    required this.sha256,
    required this.size,
    required this.formatVersion,
  });

  final String agentId;
  final String url;
  final String sha256; // lowercase-hex SHA-256 of the canonical tarball
  final int size; // bytes (0 when the catalog omits it)
  final String formatVersion; // e.g. 'elevatedir-v3'

  factory Essence2CatalogEntry.fromJson(String id, Map<String, dynamic> j) =>
      Essence2CatalogEntry(
        agentId: (j['agent_id'] as String?)?.isNotEmpty == true
            ? j['agent_id'] as String
            : id,
        url: (j['url'] ?? '') as String,
        sha256: ((j['sha256'] ?? '') as String).toLowerCase(),
        size: (j['size'] as num?)?.toInt() ?? 0,
        formatVersion: (j['format_version'] ?? '') as String,
      );
}

/// Fetch the Essence-2 (Elevate) `.elevatedir` delivery catalog and return its
/// entries. [catalogUrl] must be https; when [allowedHosts] is non-empty the
/// catalog host must be on it (same poisoned-catalog rationale as
/// [downloadAgentImx]). Entries with an empty `url` are dropped (mirrors
/// [fetchPublicAgents] dropping empty model_url), so a broken row never reaches
/// the gallery. Throws on a non-https URL, a disallowed host, a non-200, or an
/// unexpected catalog `format`.
Future<List<Essence2CatalogEntry>> fetchEssence2Catalog(
  String catalogUrl, {
  Set<String>? allowedHosts,
}) async {
  final uri = Uri.parse(catalogUrl);
  if (uri.scheme != 'https') {
    throw BithumanAvatarException('refusing non-https catalog_url: $catalogUrl');
  }
  if (allowedHosts != null &&
      allowedHosts.isNotEmpty &&
      !allowedHosts.contains(uri.host)) {
    throw BithumanAvatarException('catalog_url host not allowed: ${uri.host}');
  }
  final client = HttpClient();
  try {
    final req = await client.getUrl(uri);
    final res = await req.close();
    if (res.statusCode != 200) {
      throw BithumanAvatarException(
          'elevate catalog HTTP ${res.statusCode} from $catalogUrl');
    }
    final body = await res.transform(utf8.decoder).join();
    final j = jsonDecode(body) as Map<String, dynamic>;
    final fmt = j['format'];
    if (fmt != 'elevate-catalog-v1') {
      throw BithumanAvatarException('unexpected elevate catalog format: $fmt');
    }
    final agents = (j['agents'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final out = <Essence2CatalogEntry>[];
    agents.forEach((id, v) {
      if (v is Map<String, dynamic>) {
        final e = Essence2CatalogEntry.fromJson(id, v);
        if (e.url.isNotEmpty) out.add(e);
      }
    });
    return out;
  } finally {
    client.close();
  }
}

/// Download + install an Essence-2 (Elevate) `.elevatedir` bundle into
/// `<cacheDir>/<agentId>.elevatedir/` and return that directory — ready to pass
/// to `BithumanAvatar.load(dir, engine: 'essence2')`.
///
/// Mirrors [downloadExpression2Agent]'s hardening: cache-aware (re-returns an
/// already-installed bundle, keyed on the extracted `meta.json` marker),
/// https-only, optional host allow-list, streams to a `.partial` then verifies
/// the canonical SHA-256 (a length match alone can't catch substitution — the
/// bytes feed the native loader) BEFORE extracting with the system `tar` into a
/// staging dir that is atomically renamed into place. macOS delivery path
/// (`Process.run('tar')`), same as the expression-2 `.tar.gz` flow.
/// `onProgress(received,total)` ticks during download.
Future<String> downloadEssence2Bundle(
  Essence2CatalogEntry entry,
  String cacheDir, {
  Set<String>? allowedHosts,
  void Function(int received, int? total)? onProgress,
}) async {
  // The agent id comes from a public / MITM-able catalog, so never use it raw
  // in a filesystem path — a crafted '../' would escape cacheDir. Real ids are
  // alphanumeric, so this is a no-op for legit data (cache stays warm).
  final safe = entry.agentId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  final destDir = Directory('$cacheDir/$safe.elevatedir');
  final marker = File('${destDir.path}/meta.json');
  if (await marker.exists()) return destDir.path; // already installed

  final uri = Uri.parse(entry.url);
  if (uri.scheme != 'https') {
    throw BithumanAvatarException('refusing non-https bundle url: ${entry.url}');
  }
  if (allowedHosts != null &&
      allowedHosts.isNotEmpty &&
      !allowedHosts.contains(uri.host)) {
    throw BithumanAvatarException('elevate bundle host not allowed: ${uri.host}');
  }
  final tmpDir = Directory(cacheDir);
  if (!await tmpDir.exists()) await tmpDir.create(recursive: true);
  final tgz = File('$cacheDir/$safe.elevatedir.tar.gz.partial');

  final client = HttpClient();
  try {
    final req = await client.getUrl(uri);
    // Don't follow redirects: a legit content-addressed bundle is a direct 200
    // from the allowlisted host, so a 30x can only bounce the download
    // off-allowlist (the scheme/host checks validate the initial URL only).
    req.followRedirects = false;
    final res = await req.close();
    if (res.statusCode != 200) {
      throw BithumanAvatarException(
          'elevate bundle HTTP ${res.statusCode} from ${entry.url}');
    }
    final total =
        entry.size > 0 ? entry.size : (res.contentLength <= 0 ? null : res.contentLength);
    var received = 0;
    final sink = tgz.openWrite();
    try {
      await for (final chunk in res) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
      await sink.close();
    } catch (e) {
      try { await sink.close(); } catch (_) {}
      try { await tgz.delete(); } catch (_) {}
      rethrow;
    }
  } finally {
    client.close(force: true);
  }

  // Integrity: verify the canonical SHA-256 before trusting a byte of the
  // tarball (a length match can't catch a tampered/substituted bundle). Computed
  // with the system `shasum` — same macOS-only Process dependency as the `tar`
  // extraction below, so no new package dependency is pulled into the plugin.
  if (entry.sha256.isNotEmpty) {
    final got = await _sha256OfFile(tgz.path);
    if (got != entry.sha256) {
      try { await tgz.delete(); } catch (_) {}
      throw BithumanAvatarException(
          'elevate bundle sha256 mismatch (expected ${entry.sha256}, got $got)');
    }
  }

  // Extract into a fresh staging dir, then atomically rename into place. The
  // tarball holds the bundle's contents at the archive root (see
  // publish_elevatedir.py), so it extracts directly into the `.elevatedir`.
  final stageDir = Directory('${destDir.path}.tmp');
  if (await stageDir.exists()) await stageDir.delete(recursive: true);
  await stageDir.create(recursive: true);
  final r = await Process.run('tar', ['-xzf', tgz.path, '-C', stageDir.path]);
  if (r.exitCode != 0) {
    try { await stageDir.delete(recursive: true); } catch (_) {}
    try { await tgz.delete(); } catch (_) {}
    throw BithumanAvatarException('elevate bundle extract failed: ${r.stderr}');
  }
  if (!await File('${stageDir.path}/meta.json').exists()) {
    try { await stageDir.delete(recursive: true); } catch (_) {}
    try { await tgz.delete(); } catch (_) {}
    throw BithumanAvatarException(
        'elevate bundle missing meta.json after extract (not an .elevatedir?)');
  }
  if (await destDir.exists()) await destDir.delete(recursive: true);
  await stageDir.rename(destDir.path);
  try { await tgz.delete(); } catch (_) {}
  return destDir.path;
}

/// Lowercase-hex SHA-256 of [path] via the system `shasum` (macOS/BSD). Kept
/// dependency-free (the download path is already macOS-only via `tar`); throws
/// if `shasum` is unavailable or its output can't be parsed.
Future<String> _sha256OfFile(String path) async {
  final r = await Process.run('shasum', ['-a', '256', path]);
  if (r.exitCode != 0) {
    throw BithumanAvatarException('shasum failed: ${r.stderr}');
  }
  final out = (r.stdout as String).trim();
  final hex = out.split(RegExp(r'\s+')).first.toLowerCase();
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hex)) {
    throw BithumanAvatarException('shasum produced unparseable digest: $out');
  }
  return hex;
}

/// Plugin version stamp the native side reports for diagnostics.
Future<String?> nativeEngineVersion() async {
  return _channel.invokeMethod<String>('engineVersion');
}


// ── Phase-3 unified `.imx` container — consumer accept-both ──────────────────
// The on-device `.model`/`.avatar` are zip archives today; Phase-3 optionally
// FOLDS the exact same members into the unified `IMX\0` v2 flat-TOC container
// (the producer-side `UNIFIED_CONTAINER` flag governs which form is emitted —
// see expression-2 tools/expression2-model/Archive.swift). The unpack here is
// the byte-exact Dart mirror of Swift `Archive.unpackImx`: it reconstructs the
// SAME on-disk layout the legacy `unzip` produced, so every downstream reader
// (the Expression2Engine load path keyed on `activeAgentDir`) is unchanged.
//
// Container layout (little-endian throughout):
//   magic "IMX\0" (4) | version:u16 (=2) | count:u16
//   then `count` TOC entries: nameLen:u16 | name:utf8 | offset:u64 | size:u64
//   then the concatenated payloads at their absolute offsets.

const List<int> _imxMagic = [0x49, 0x4D, 0x58, 0x00]; // "IMX\0"
const int _imxVersion = 2;

/// Extract an on-device avatar/model container into [dir]. Sniffs the 4-byte
/// magic: a unified `IMX\0` container → [_unpackImxContainer]; else the legacy
/// zip path (`unzip`, which CRC-checks every entry). Throws on failure.
Future<void> _extractAvatarContainer(File archive, Directory dir) async {
  final raf = await archive.open();
  List<int> head;
  try {
    head = await raf.read(4);
  } finally {
    await raf.close();
  }
  final isImx = head.length == 4 &&
      head[0] == _imxMagic[0] && head[1] == _imxMagic[1] &&
      head[2] == _imxMagic[2] && head[3] == _imxMagic[3];
  if (isImx) {
    await _unpackImxContainer(archive, dir);
    return;
  }
  final r = await Process.run('unzip', ['-qq', archive.path, '-d', dir.path]);
  if (r.exitCode != 0) {
    throw 'unzip exit ${r.exitCode}: ${r.stderr}';
  }
}

/// Unpack a unified `IMX\0` v2 flat-TOC container into [dir], reconstructing the
/// `.mlpackage` directory trees from the flattened TOC entry names. Byte-exact
/// mirror of Swift `Archive.unpackImx` (offsets ABSOLUTE; payloads verbatim).
Future<void> _unpackImxContainer(File archive, Directory dir) async {
  final raf = await archive.open();
  try {
    int le16(List<int> b, int o) => b[o] | (b[o + 1] << 8);
    int le64(List<int> b, int o) {
      var v = 0;
      for (var i = 0; i < 8; i++) {
        v |= b[o + i] << (8 * i);
      }
      return v;
    }

    final headD = await raf.read(8);
    if (headD.length != 8) throw 'IMX: file too small for header';
    if (!(headD[0] == _imxMagic[0] && headD[1] == _imxMagic[1] &&
          headD[2] == _imxMagic[2] && headD[3] == _imxMagic[3])) {
      throw 'IMX: bad magic';
    }
    final version = le16(headD, 4);
    if (version != _imxVersion) throw 'IMX: unsupported version $version';
    final count = le16(headD, 6);

    // Parse the flat TOC.
    final entries = <_ImxEntry>[];
    var cursor = 8;
    for (var i = 0; i < count; i++) {
      await raf.setPosition(cursor);
      final lenD = await raf.read(2);
      if (lenD.length != 2) throw 'IMX: truncated TOC (nameLen)';
      final nameLen = le16(lenD, 0);
      cursor += 2;
      await raf.setPosition(cursor);
      final nameD = await raf.read(nameLen);
      if (nameD.length != nameLen) throw 'IMX: truncated TOC (name)';
      final name = utf8.decode(nameD);
      cursor += nameLen;
      await raf.setPosition(cursor);
      final osD = await raf.read(16);
      if (osD.length != 16) throw 'IMX: truncated TOC (offset/size)';
      final off = le64(osD, 0), size = le64(osD, 8);
      cursor += 16;
      // Reject path traversal (defensive — the producer never emits "..").
      if (name.startsWith('/') || name.contains('..')) {
        throw 'IMX: unsafe entry name $name';
      }
      entries.add(_ImxEntry(name, off, size));
    }

    // Stream each payload to its reconstructed on-disk path (sorted by name, to
    // match Swift's `toc.keys.sorted()` write order — irrelevant to bytes, kept
    // for deterministic behaviour).
    entries.sort((a, b) => a.name.compareTo(b.name));
    const chunkCap = 1 << 20;
    for (final e in entries) {
      final dest = File('${dir.path}/${e.name}');
      await dest.parent.create(recursive: true);
      final sink = dest.openWrite();
      try {
        await raf.setPosition(e.offset);
        var remaining = e.size;
        while (remaining > 0) {
          final want = remaining < chunkCap ? remaining : chunkCap;
          final chunk = await raf.read(want);
          if (chunk.isEmpty) throw 'IMX: truncated reading ${e.name}';
          sink.add(chunk);
          remaining -= chunk.length;
        }
      } finally {
        await sink.close();
      }
    }
  } finally {
    await raf.close();
  }
}

class _ImxEntry {
  final String name;
  final int offset;
  final int size;
  const _ImxEntry(this.name, this.offset, this.size);
}

