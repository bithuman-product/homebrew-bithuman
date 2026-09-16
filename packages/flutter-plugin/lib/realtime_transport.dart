// Realtime-transport adapter: thin shim over the two concrete OpenAI
// Realtime client implementations the example app uses, so the UI
// (lib/main.dart's AvatarScreen) can speak ONE interface regardless of
// platform.
//
// Two underlying transports today:
//   - WebSocketTransport  → wraps `BithumanRealtimeSession` (the
//     plugin's WebSocket Realtime client + native VP-IO RealtimeAudioIO
//     for mic/speaker). The cloud path on macOS AND iOS — ONE audio unit
//     (ours) owns mic + speaker, Apple's local AEC references our own
//     playout, and the elevate utterance gate holds agent speech until
//     the avatar's first frame. (iOS previously ran WebRTC here; running
//     a second audio unit beside libwebrtc's caused ducking + echo
//     outside the AEC reference → self-interruption storms. task #62.)
//   - WebRTCTransport     → wraps `OpenAIWebRTCSession` (flutter_webrtc
//     + libwebrtc native pipeline). The cloud path on Android —
//     libwebrtc's APM handles AEC + audio routing there. Kept available
//     on iOS/macOS behind BITHUMAN_TRANSPORT=webrtc for A/B tests.
// Local mode on either platform goes through LocalConverseTransport,
// which also drives the native VP-IO RealtimeAudioIO directly.
//
// Both adapters expose the same `RealtimeTransport` surface; the UI
// doesn't know or care which one it's holding. `pickTransport()` is the
// platform-conditional factory at the bottom of this file.
//
// Apache-2.0; (c) bitHuman.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:bithuman/bithuman.dart';
import 'package:bithuman/bithuman_realtime.dart';

import 'openai_webrtc_session.dart';
import 'src/dev_levers.dart';

/// Lifecycle states that any underlying transport can be in. Maps the
/// concrete `RealtimeStatus` (WebSocket) and `WebRTCStatus` (WebRTC)
/// onto a single enum the UI can switch on.
enum TransportStatus {
  /// Initial state, no connection in flight.
  closed,

  /// Dialing / negotiating / authenticating.
  connecting,

  /// Connected; the bot is silent and waiting for the user to talk.
  listening,

  /// Server VAD detected user speech; the bot's playback (if any) was
  /// cancelled by the barge-in path.
  userSpeaking,

  /// User stopped talking; server is generating a response.
  thinking,

  /// Bot is actively replying (audio + transcript streaming back).
  responding,

  /// Last response completed cleanly. UI typically returns to
  /// `listening` immediately after.
  responseDone,

  /// Transport-level error. Specifics surface as a separate event /
  /// log; the UI can show a snack and offer to reconnect.
  error,
}

/// Common surface for any OpenAI Realtime transport the example app
/// can drive. New transports (e.g. LiveKit) implement this and slot
/// into `pickTransport()` below — the UI doesn't change.
///
/// Stream contracts:
///   - `statusStream` always emits at least once before any other
///     stream; UI uses it to swap chrome (status pill, mic-button
///     state, captions visibility).
///   - `botTranscriptStream` emits each bot-transcript delta as it
///     arrives. Empty deltas are valid (just don't append). Resets to
///     empty caption on a new `responding` transition.
///   - `micLevelStream` / `botLevelStream` emit a 0..1 float at ~10 Hz
///     when the underlying transport surfaces audio levels. WebRTC
///     transport currently emits nothing — UI should treat absent
///     emissions as "level not available" (not "level is zero").
///   - `interruptStream` pulses (no payload) when the bot's in-flight
///     reply was cancelled mid-stream. UI uses this to flush
///     captions / re-arm the avatar's idle frame.
abstract class RealtimeTransport {
  Stream<TransportStatus> get statusStream;
  Stream<String> get botTranscriptStream;
  Stream<double> get micLevelStream;
  Stream<double> get botLevelStream;
  Stream<void> get interruptStream;

  /// Mute the local mic. Implementations may delay the underlying
  /// effect until `start()` has produced a live capture node.
  bool get muted;
  set muted(bool value);

  /// Whether mic-mute is actually wired for this transport. The UI hides the
  /// mute button when false so the control never lies (local mode has no
  /// native mic-mute hook yet).
  bool get canMute;

  /// Open the connection + start the audio loop. Returns once the
  /// transport is at `listening` (or has surfaced an error via
  /// `statusStream`). [mic] false = text-only (speaker, no mic / no permission).
  Future<void> start({bool mic = true});

  /// Tear the connection down cleanly. Idempotent.
  Future<void> stop();

  /// Drop all owned resources. Call after `stop()`. Any further calls
  /// on the object are undefined.
  Future<void> dispose();

  /// Update session-level config (system prompt today; voice/model
  /// follow as the underlying transports gain server-side update
  /// support). Best-effort — implementations may ignore unknown keys.
  /// Returns true if at least one key was applied.
  bool applySettings({String? systemPrompt, String? voice, String? model});

  /// Send a typed user message to the agent (text → the agent replies with voice
  /// + avatar, same as a spoken turn). No-op on transports without a text channel.
  void sendText(String text);
}

/// Wraps the WebSocket-based `BithumanRealtimeSession` (the plugin's
/// own Realtime client + native VP-IO mic/speaker). macOS + iOS path.
class WebSocketTransport implements RealtimeTransport {
  WebSocketTransport({
    required String apiKey,
    required BithumanAvatar avatar,
    required String model,
    required String voice,
    required String systemPrompt,
    required int vadThreshold,
  }) : _session = BithumanRealtimeSession(
          apiKey: apiKey,
          avatar: avatar,
          model: model,
          voice: voice,
          systemPrompt: systemPrompt,
          vadThreshold: vadThreshold,
        );

  final BithumanRealtimeSession _session;

  // Eagerly-created broadcast controller for the interrupt pulses; the
  // session itself doesn't surface a dedicated interrupt stream, so we
  // synthesise one from the status transitions (any → userSpeaking
  // implies a barge-in cancelling the bot mid-reply).
  final _interrupt = StreamController<void>.broadcast();
  StreamSubscription<RealtimeStatus>? _statusSub;
  TransportStatus _last = TransportStatus.closed;

  @override
  Stream<TransportStatus> get statusStream => _session.statusStream
      .map(_mapStatus)
      .map((s) {
        if (s == TransportStatus.userSpeaking &&
            _last == TransportStatus.responding) {
          _interrupt.add(null);
        }
        _last = s;
        return s;
      });

  @override
  Stream<String> get botTranscriptStream => _session.botTranscriptStream;
  @override
  Stream<double> get micLevelStream => _session.micLevelStream;
  @override
  Stream<double> get botLevelStream => _session.botLevelStream;
  @override
  Stream<void> get interruptStream => _interrupt.stream;

  @override
  bool get muted => _session.muted;
  @override
  set muted(bool value) => _session.muted = value;
  @override
  bool get canMute => true; // wired to the native VP-IO session

  @override
  Future<void> start({bool mic = true}) => _session.start(enableMic: mic);
  @override
  Future<void> stop() => _session.stop();

  @override
  Future<void> dispose() async {
    await _statusSub?.cancel();
    await _interrupt.close();
    // BithumanRealtimeSession doesn't have its own dispose; stop()
    // releases the WS + audio graph, and Dart GC takes the rest.
  }

  @override
  bool applySettings({String? systemPrompt, String? voice, String? model}) {
    return _session.applySettings(systemPrompt: systemPrompt);
  }

  @override
  void sendText(String text) {
    // Typed input is a committed user turn → the session emits userStopped
    // (→ TransportStatus.thinking) so the neon rim shows immediately, just like a
    // spoken turn (cloud has no speech_stopped event for typed text).
    _session.sendText(text); // fire-and-forget; barges, marks thinking, then sends
  }

  static TransportStatus _mapStatus(RealtimeStatus s) {
    return switch (s) {
      RealtimeStatus.connecting   => TransportStatus.connecting,
      RealtimeStatus.open         => TransportStatus.listening,
      RealtimeStatus.userSpeaking => TransportStatus.userSpeaking,
      RealtimeStatus.userStopped  => TransportStatus.thinking,
      RealtimeStatus.responseDone => TransportStatus.responseDone,
      RealtimeStatus.closed       => TransportStatus.closed,
      RealtimeStatus.error        => TransportStatus.error,
    };
  }
}

/// Wraps the WebRTC-based `OpenAIWebRTCSession`. The Android cloud path
/// (iOS/macOS only via the BITHUMAN_TRANSPORT=webrtc A/B opt-in). Also
/// wires the lipsync feed: when libwebrtc attaches the remote audio
/// track, the avatar's `attachWebrtcRemoteAudio` is called so the
/// plugin's lipsync queue is fed from the exact PCM the speaker plays.
/// On barge-in, `avatar.interrupt()` is called to flush the queue so
/// the mouth doesn't keep articulating cancelled audio.
class WebRTCTransport implements RealtimeTransport {
  WebRTCTransport({
    required String apiKey,
    required this.avatar,
    required String model,
    required String voice,
    required String systemPrompt,
    required int vadThreshold,
  }) : _session = OpenAIWebRTCSession(
          apiKey: apiKey,
          model: model,
          voice: voice,
          systemPrompt: systemPrompt,
          vadThreshold: vadThreshold,
        );

  final BithumanAvatar avatar;
  final OpenAIWebRTCSession _session;
  StreamSubscription<dynamic>? _remoteAudioSub;
  StreamSubscription<dynamic>? _interruptForwardSub;
  // WebRTC transport doesn't surface mic/bot levels yet — getStats()
  // audio levels are wireable but TBD. Empty broadcast controllers
  // satisfy the contract (no emissions ≠ "level is zero").
  final _micLevel = StreamController<double>.broadcast();
  final _botLevel = StreamController<double>.broadcast();

  @override
  Stream<TransportStatus> get statusStream =>
      _session.statusStream.map(_mapStatus);
  @override
  Stream<String> get botTranscriptStream => _session.botTranscriptStream;
  @override
  Stream<double> get micLevelStream => _micLevel.stream;
  @override
  Stream<double> get botLevelStream => _botLevel.stream;
  @override
  Stream<void> get interruptStream => _session.interruptStream;

  // Mute flips the local audio track's `enabled` flag via the session
  // (setMicMuted). `_muted` is the cached intent, re-applied at the end of
  // start() because the track only exists once getUserMedia has run.
  bool _muted = false;
  @override
  bool get muted => _muted;
  @override
  set muted(bool value) {
    _muted = value;
    _session.setMicMuted(value); // flips the local audio track's enabled flag
  }
  @override
  bool get canMute => true;

  @override
  Future<void> start({bool mic = true}) async {
    // (iOS WebRTC is always full-duplex; `mic` is accepted for interface parity.)
    // Lipsync attach: feed the bot's PCM into the avatar's queue as
    // soon as libwebrtc has the remote track. NOT the mic.
    _remoteAudioSub = _session.remoteAudioReadyStream.listen((track) async {
      try {
        await avatar.attachWebrtcRemoteAudio(track.id ?? '');
      } catch (_) {/* swallowed; lipsync simply won't be driven */}
    });
    // On barge-in / cancel, flush avatar's lipsync queue so the mouth
    // stops articulating audio the user never hears (phantom talk).
    _interruptForwardSub = _session.interruptStream.listen((_) async {
      try {
        await avatar.interrupt(reason: 'webrtc_speech_started');
      } catch (_) {/* swallowed */}
    });
    await _session.start();
    // The local audio track only exists after getUserMedia (inside start), so a
    // mute requested before start() (e.g. restart-while-muted) would otherwise
    // be lost — re-apply the cached state now so the UI never lies.
    _session.setMicMuted(_muted);
  }

  @override
  Future<void> stop() async {
    try {
      await avatar.detachWebrtcRemoteAudio();
    } catch (_) {/* swallowed */}
    await _session.stop();
  }

  @override
  Future<void> dispose() async {
    await _remoteAudioSub?.cancel();
    await _interruptForwardSub?.cancel();
    await _micLevel.close();
    await _botLevel.close();
    await _session.dispose();
  }

  @override
  bool applySettings({String? systemPrompt, String? voice, String? model}) {
    // Forward to the underlying WebRTC session — sends a partial
    // session.update over the data channel so the server applies the
    // change to the next turn (no reconnect required for the prompt).
    // voice + model still need a reconnect today; a future patch can
    // tear down + redial the peer connection on those fields.
    return _session.applySettings(systemPrompt: systemPrompt);
  }

  @override
  void sendText(String text) {
    // iOS WebRTC text input isn't wired yet (would send over the data channel);
    // voice works today, typed text is a follow-up.
  }

  static TransportStatus _mapStatus(WebRTCStatus s) {
    return switch (s) {
      WebRTCStatus.idle         => TransportStatus.closed,
      WebRTCStatus.connecting   => TransportStatus.connecting,
      WebRTCStatus.open         => TransportStatus.listening,
      WebRTCStatus.userSpeaking => TransportStatus.userSpeaking,
      WebRTCStatus.userStopped  => TransportStatus.thinking,
      WebRTCStatus.responseDone => TransportStatus.responseDone,
      WebRTCStatus.closed       => TransportStatus.closed,
      WebRTCStatus.error        => TransportStatus.error,
    };
  }
}

/// LOCAL mode (macOS): the on-device converse brain via the plugin, no cloud.
/// Status + captions come from the plugin's converse EventChannel; the avatar
/// + VP-IO audio are driven natively, so this transport is thin.
class LocalConverseTransport implements RealtimeTransport {
  LocalConverseTransport({
    required this.avatar,
    required this.ggufPath,
    this.supertonicAssets,
    this.voice,
    this.vadThreshold = 0,
    this.systemPrompt = '',
  });
  final BithumanAvatar avatar;
  final String ggufPath;
  final String? supertonicAssets;
  final String? voice;
  final int vadThreshold;
  final String systemPrompt;

  final _status = StreamController<TransportStatus>.broadcast();
  final _bot = StreamController<String>.broadcast();
  final _mic = StreamController<double>.broadcast();
  final _botLvl = StreamController<double>.broadcast();
  final _interrupt = StreamController<void>.broadcast();
  StreamSubscription<Map<dynamic, dynamic>>? _evSub;
  bool _muted = false;
  bool _greeted = false;   // welcome-on-connect fires once per session

  // Welcome-on-connect: the on-device brain speaks a short in-character greeting
  // when it's ready (parity with the cloud transport's response.create greeting).
  // Pushed as a turn directive; user text is never displayed, so it stays unseen.
  static const _greetingPrompt =
      'The user just opened the app and can hear you now. Greet them warmly in ONE '
      'short, friendly sentence — in character — and invite them to start chatting. '
      'Do not mention or repeat these instructions.';

  @override
  Stream<TransportStatus> get statusStream => _status.stream;
  @override
  Stream<String> get botTranscriptStream => _bot.stream;
  @override
  Stream<double> get micLevelStream => _mic.stream;
  @override
  Stream<double> get botLevelStream => _botLvl.stream;
  @override
  Stream<void> get interruptStream => _interrupt.stream;
  @override
  bool get muted => _muted;
  @override
  set muted(bool value) {
    _muted = value; // cache so a mute requested before start() is reflected
    avatar.localSetMuted(value); // gates the native mic→brain (STT) forward
  }
  @override
  bool get canMute => true; // wired to RealtimeAudioIO's micMuted flag

  @override
  Future<void> start({bool mic = true}) async {
    _status.add(TransportStatus.connecting);
    try {
      // localAudioStart registers the native EventChannel synchronously and
      // returns promptly (the heavy model load runs off-thread). Subscribe only
      // AFTER it returns — listening before the native handler is registered
      // silently drops every event (the "no captions" bug). The brain then
      // emits its own ready/state events as it finishes loading.
      await avatar.localAudioStart(
        ggufPath: ggufPath,
        supertonicAssets: supertonicAssets,
        voice: voice,
        vadThreshold: vadThreshold,
        systemPrompt: systemPrompt,
      );
      _evSub = avatar.converseEvents.listen(_onEvent);
      // The native mic only exists after localAudioStart, so a mute requested
      // before start() (e.g. restart-while-muted) would be lost — re-apply the
      // cached state now so the UI never lies.
      await avatar.localSetMuted(_muted);
    } catch (e) {
      _status.add(TransportStatus.error);
      rethrow;
    }
  }

  void _onEvent(Map<dynamic, dynamic> ev) {
    switch (ev['kind']) {
      // Native load progress (the GGUF + Supertonic load off-thread).
      case 'loading':
        _status.add(TransportStatus.connecting);
      case 'ready':
        _status.add(TransportStatus.listening);
        if (!_greeted) {
          _greeted = true;
          _status.add(TransportStatus.thinking);   // rim on until the greeting plays
          avatar.localPushText(_greetingPrompt);
        }
      case 'error':
        _status.add(TransportStatus.error);
      case 'state':
        switch (ev['state'] as int? ?? 0) {
          case 1:
            _status.add(TransportStatus.listening);
            _botLvl.add(0); // bot silent → stop the speaking pulse
          case 2:
            _status.add(TransportStatus.thinking);
            _botLvl.add(0);
          case 3:
            // SPEAKING → keep the "thinking" neon rim ON, matching cloud (which
            // stays TransportStatus.thinking from userStopped until responseDone —
            // it has no separate responding status). The bot's speaking pulse is
            // driven independently by bot_level, so the rim + pulse coexist exactly
            // like cloud. The rim turns off when the engine returns to listening (1).
            _status.add(TransportStatus.thinking);
        }
      // Real audio levels from the native pipeline (mic tap + TTS chunk) so the
      // primary button pulses exactly like the cloud session (UI parity).
      case 'mic_level':
        _mic.add((((ev['level'] as num?) ?? 0).toDouble()).clamp(0.0, 1.0));
      case 'bot_level':
        _botLvl.add((((ev['level'] as num?) ?? 0).toDouble()).clamp(0.0, 1.0));
      case 'user':
        _status.add(TransportStatus.userSpeaking);
        _interrupt.add(null); // new user turn → flush the bot caption
      case 'bot':
        _bot.add(ev['text'] as String? ?? '');
    }
  }

  @override
  Future<void> stop() async {
    await avatar.localAudioStop();
    await _evSub?.cancel();
    _evSub = null;
    _status.add(TransportStatus.closed);
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _status.close();
    await _bot.close();
    await _mic.close();
    await _botLvl.close();
    await _interrupt.close();
  }

  @override
  bool applySettings({String? systemPrompt, String? voice, String? model}) => false;

  @override
  void sendText(String text) {
    // Typed turn BARGES like a spoken one: flush the bot caption now (the native
    // pushText barges the audio/lipsync), then show the "thinking" rim immediately
    // (parity with a spoken turn and with cloud typed input). The native pushText
    // then drives the engine through thinking→speaking, keeping the rim on until it
    // returns to listening at turn end.
    _interrupt.add(null); // new user turn → flush the in-flight bot caption
    _status.add(TransportStatus.thinking);
    avatar.localPushText(text); // → native pushText (now barges the in-flight reply)
  }
}

/// Cloud-transport override for A/B tests (docs/TRANSPORT.md).
/// `--dart-define=BITHUMAN_TRANSPORT=webrtc` routes macOS/iOS cloud down
/// [WebRTCTransport] (the Android path) instead of the WebSocket + native
/// VP-IO default — an A/B knob, NOT shipped behavior. Empty / unset (every
/// production build) keeps the platform defaults below. Known gap under the
/// override on macOS: the plugin's `attachWebrtcRemoteAudio` is iOS-only
/// today, so the avatar's lipsync is not driven (audio/AEC/barge behavior is
/// what the A/B measures). Local mode is unaffected — no cloud transport.
const String _kTransportDefine = DevLevers.transport;

/// Platform-conditional factory. Local mode (macOS/iOS) → on-device
/// converse; Android cloud → WebRTC (always); macOS + iOS cloud →
/// WebSocket + native VP-IO (unless [_kTransportDefine] opts into WebRTC
/// — see above). Adding a new transport = one branch here, no UI change.
///
/// Android MUST take the WebRTC branch: the Android plugin's frames-path
/// revival stubs the native VP-IO surface (`audioStart` returns false,
/// `playSpeakerPCM` is a no-op, the mic EventChannel never emits), so the
/// WebSocket transport connects fine but is mute AND deaf there. libwebrtc
/// owns mic + speaker + AEC on Android exactly as on iOS (flutter_webrtc's
/// AudioSwitchManager requests audio focus, sets MODE_IN_COMMUNICATION and
/// routes to the speakerphone by default).
RealtimeTransport pickTransport({
  required String apiKey,
  required BithumanAvatar avatar,
  required String model,
  required String voice,
  required String systemPrompt,
  required int vadThreshold,
  bool localMode = false,
  String? ggufPath,
  String? supertonicAssets,
  String? transportOverride, // test injection; defaults to the dart-define
}) {
  if (localMode &&
      (Platform.isMacOS || Platform.isIOS) &&
      ggufPath != null &&
      ggufPath.isNotEmpty) {
    return LocalConverseTransport(
      avatar: avatar,
      ggufPath: ggufPath,
      supertonicAssets: supertonicAssets,
      voice: voice,
      vadThreshold: vadThreshold,
      systemPrompt: systemPrompt,
    );
  }
  // Every platform takes the WebSocket transport by default: the plugin's native
  // audio surface (speaker + echo-cancelled mic) exists on macOS, iOS AND Android,
  // and the WebSocket path is the one whose bot PCM the avatar lipsyncs from
  // sample-accurately. WebRTC stays an explicit opt-in A/B.
  final wantWebrtc =
      (transportOverride ?? _kTransportDefine).toLowerCase() == 'webrtc';
  if (wantWebrtc) {
    return WebRTCTransport(
      apiKey: apiKey,
      avatar: avatar,
      model: model,
      voice: voice,
      systemPrompt: systemPrompt,
      vadThreshold: vadThreshold,
    );
  }
  return WebSocketTransport(
    apiKey: apiKey,
    avatar: avatar,
    model: model,
    voice: voice,
    systemPrompt: systemPrompt,
    vadThreshold: vadThreshold,
  );
}
