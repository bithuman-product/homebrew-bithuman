// bithuman_realtime — OpenAI Realtime session wired to the bitHuman avatar.
//
// Audio I/O is owned by the plugin's native VP-IO graph (see
// macos/Classes/RealtimeAudioIO.swift). This session is responsible for
// the WebSocket only: it forwards mic chunks to OpenAI and routes bot
// audio chunks back to the plugin. The plugin then plays them through
// the speaker AND pushes the same chunks into the avatar lipsync queue
// at the same instant — A/V cannot drift, and Apple's VP-IO subtracts
// the bot's voice from the mic so self-talk is impossible.
//
// Wire format (per https://platform.openai.com/docs/guides/realtime):
//   - Transport: wss://api.openai.com/v1/realtime?model=…
//   - Auth: `Authorization: Bearer <api_key>` (GA — no Beta header)
//   - Audio: PCM16 mono @ 24 kHz, base64-encoded inside JSON events
//   - session.update uses the GA shape: top-level `type: 'realtime'`,
//     `output_modalities`, nested `audio.input.*` / `audio.output.*`.
//     The old beta shape (top-level `modalities`/`voice`/`input_audio_format`)
//     is now rejected with `beta_api_shape_disabled`.
//
// Apache-2.0; (c) bitHuman.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';

import 'bithuman.dart';

/// One Realtime session over a single WebSocket.
///
/// Lifecycle: `start()` → bidirectional audio for the session's lifetime →
/// `stop()`. The session is single-use; create a new one for the next
/// conversation. Use [statusStream] and [onError] to drive the UI.
class BithumanRealtimeSession {
  BithumanRealtimeSession({
    required this.apiKey,
    required this.avatar,
    this.model = 'gpt-realtime',
    this.systemPrompt = '',
    this.voice = 'alloy',
    required this.vadThreshold,
  }) {
    _liveSystemPrompt = systemPrompt;
  }

  final String apiKey;
  final BithumanAvatar avatar;
  final String model;
  final String systemPrompt;
  final String voice;
  final int vadThreshold;

  /// TEST HOOK (e2e harness): when non-null, the session dials this WebSocket
  /// URL instead of the production OpenAI endpoint — lets the hermetic mock
  /// realtime server (flutter/bithuman/e2e/mock_realtime) stand in for OpenAI
  /// in integration tests. Settable in-process (integration tests share the
  /// app process) or at build time via
  /// `--dart-define=BITHUMAN_REALTIME_WS_URL=ws://…`. Inert in production:
  /// null + empty define → the real endpoint.
  static String? debugEndpointOverride;
  static const String _envEndpointOverride =
      String.fromEnvironment('BITHUMAN_REALTIME_WS_URL');

  /// The WebSocket URL this session dials (override-aware).
  String get _endpoint =>
      debugEndpointOverride ??
      (_envEndpointOverride.isNotEmpty
          ? _envEndpointOverride
          : 'wss://api.openai.com/v1/realtime?model=$model');

  WebSocketChannel? _ws;
  StreamSubscription? _wsSub;
  StreamSubscription<Uint8List>? _micSub;
  bool _open = false;

  // Reconnect-with-backoff state. Active only while `_open == true` —
  // a user-initiated `stop()` clears these and prevents further retries.
  // Backoff schedule: 1, 2, 4, 8, 16, 30, 30, 30 seconds (cap 30 s);
  // after [_maxReconnectAttempts] consecutive failures we give up and
  // surface RealtimeStatus.error so the UI can offer a manual retry.
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  static const int _maxReconnectAttempts = 8;

  // True once the server has acknowledged the connection with any
  // inbound event (e.g. `session.created`). Used to gate the
  // `_reconnectAttempt = 0` reset — earlier code reset on TCP-level
  // success, which made server-side close-after-handshake (e.g. the
  // beta API deprecation) loop forever in `connecting` instead of
  // surfacing the error.
  bool _serverAcked = false;

  // True between `speech_started` (we sent response.cancel) and the
  // next `response.created` (OpenAI confirmed it's composing a fresh
  // reply). While true, drop any `response.audio.delta` events that
  // are still arriving — those are from the cancelled response, were
  // already in flight when we cancelled, and would otherwise keep the
  // lipsync animating after the speaker has gone silent.
  bool _droppingCancelledAudio = false;

  // True between `response.created` and `response.done` / cancellation
  // — i.e., when the agent has an in-flight reply. Used to gate
  // `response.cancel`: sending cancel when nothing is in flight makes
  // OpenAI return an "error" event ("Cancellation failed: no active
  // response found") which we'd otherwise misclassify as a connection
  // error.
  bool _haveActiveResponse = false;

  // Real-time pacing for bot audio. OpenAI streams `response.output_audio.delta`
  // FASTER than real time (the whole reply arrives in a burst). The speaker
  // (AVAudioPlayerNode) self-paces, but the avatar's lipsync queue drains at a
  // hard 1x and backlogs under a burst, so video lags audio over a long reply.
  // LOCAL mode never has this because its TTS source (ConverseSession) is
  // metered to ~1x. We mirror that here: release each delta to the plugin only
  // as fast as it will play, keeping the lipsync queue near-empty.
  //
  // `_audioBufferedUntil` is the wall-clock time the audio handed to the plugin
  // so far will finish playing. Reserved SYNCHRONOUSLY (before any await) so
  // concurrently-dispatched delta handlers each claim the next slot rather than
  // racing on a stale value. `_audioGen` invalidates deltas left parked in a
  // pacing delay across a barge / cancel / turn boundary.
  static const Duration _paceLead = Duration(milliseconds: 180);
  DateTime _audioBufferedUntil = DateTime.fromMillisecondsSinceEpoch(0);
  int _audioGen = 0;

  // Bump the audio generation and clear the pacing clock — call at every turn
  // boundary (barge, cancel, new response, stop) so a fresh turn starts playing
  // immediately and any delta still parked in a pacing delay is dropped.
  void _resetAudioPacing() {
    _audioGen++;
    _audioBufferedUntil = DateTime.fromMillisecondsSinceEpoch(0);
  }

  // Connection self-validation. Every connect ends by asking the agent to speak
  // a short warm greeting — a nicer UX AND a full-path health check
  // (token → WS → model → audio → lipsync). If the server doesn't START that
  // response within _validateTimeout, the socket is "stuck" (open but dead), so
  // we force it closed to trigger the reconnect-with-backoff path (self-heal).
  // The validation budget is SEPARATE from the WS-drop reconnect budget and is
  // NOT reset by `_serverAcked` (a stuck socket may still deliver session.created
  // and would otherwise loop forever); it only resets once a real response lands.
  static const _greetingInstructions =
      'To open the conversation, greet the user warmly in one short, friendly sentence.';
  static const _validateTimeout = Duration(seconds: 8);
  static const _maxValidationFailures = 3;
  Timer? _validateTimer;
  int _validationFailures = 0;

  // STRESS MODE (dev-only, `--dart-define=BITHUMAN_DEV_STRESS=true`) — the
  // WS-path twin of openai_webrtc_session's stress driver (tasks #56/#62):
  // a couple of seconds after each `response.done`, request another ~60 s
  // monologue, so the run is continuous agent speech with ZERO user input
  // and every speech_started / native barge in the log is by construction
  // SPURIOUS (speaker echo / room noise tripping server VAD). The connect
  // greeting doubles as turn 0. Paired with scripts/stress-webrtc-iphone.sh
  // + stress-webrtc-metrics.py. Default-off (define unset) in every
  // production build, so shipped behavior on both platforms is unchanged.
  static const _devStress = bool.fromEnvironment('BITHUMAN_DEV_STRESS');
  static const _stressInstructions =
      'Speak an uninterrupted monologue of roughly sixty seconds on any '
      'interesting topic. Do not pause for questions, do not address the '
      'listener, do not stop early.';
  Timer? _stressTimer;
  int _stressTurn = 0;

  /// Stress driver (see [_devStress]): request the next long monologue.
  /// Single pending timer — cancel→done bursts must not stack queued turns.
  void _scheduleStressTurn(Duration delay) {
    _stressTimer?.cancel();
    _stressTimer = Timer(delay, () {
      if (!_open || _ws == null) return;
      _stressTurn += 1;
      // ignore: avoid_print
      print('[stress] turn $_stressTurn requested');
      _send({
        'type': 'response.create',
        'response': {'instructions': _stressInstructions},
      });
    });
  }

  void _armConnectionWatchdog() {
    _validateTimer?.cancel();
    _validateTimer = Timer(_validateTimeout, _onConnectionStuck);
  }

  void _cancelConnectionWatchdog() {
    _validateTimer?.cancel();
    _validateTimer = null;
  }

  // First real response landed → the connection is proven healthy.
  void _markConnectionValidated() {
    _cancelConnectionWatchdog();
    _validationFailures = 0;
  }

  void _onConnectionStuck() {
    if (!_open) return;
    // Guard the fire→callback gap: a one-shot Timer can't be un-queued once it
    // has fired, so if `response.created` validated the socket in that gap
    // (which nulls `_validateTimer` via _markConnectionValidated) we'd be about
    // to kill a HEALTHY connection. Bail if validation already happened.
    if (_validateTimer == null) return;
    _validationFailures++;
    if (_validationFailures >= _maxValidationFailures) {
      // ignore: avoid_print
      print('[realtime] connection failed validation $_validationFailures× — giving up');
      // Surface the failure and stop retrying, but DO NOT clear `_open`: the
      // caller's stop() is the only path that shuts the native VP-IO audio
      // engine + mic down, and it early-returns on `!_open`. Clearing _open
      // here would leak the audio engine (socket dead, mic still hot). This
      // mirrors the reconnect-budget give-up in _scheduleReconnect. Cancelling
      // _wsSub before closing means _handleDone never fires → no reconnect.
      _status.add(RealtimeStatus.error);
      _wsSub?.cancel();
      _wsSub = null;
      try {
        _ws?.sink.close();
      } catch (_) {}
      _ws = null;
      return;
    }
    // ignore: avoid_print
    print('[realtime] no greeting response — socket stuck; reconnecting '
        '(validation failure $_validationFailures)');
    // Force the dead socket closed → _handleDone → _scheduleReconnect.
    try {
      _ws?.sink.close();
    } catch (_) {}
  }

  final _status = StreamController<RealtimeStatus>.broadcast();
  Stream<RealtimeStatus> get statusStream => _status.stream;

  /// Streaming text of what the bot is saying — emitted from
  /// `response.audio_transcript.delta` events. Each event carries one
  /// partial chunk; callers concatenate to build the full reply.
  final _botTranscript = StreamController<String>.broadcast();
  Stream<String> get botTranscriptStream => _botTranscript.stream;

  /// User's transcribed speech (when OpenAI returns it). Useful for
  /// captions of "what you just said". Emitted on
  /// `conversation.item.input_audio_transcription.completed`.
  final _userTranscript = StreamController<String>.broadcast();
  Stream<String> get userTranscriptStream => _userTranscript.stream;

  /// Live mic loudness in [0, 1] (peak per ~85 ms chunk). Drives the
  /// "mic is hot" pulse on the primary button so users see immediate
  /// visual feedback that their microphone is working.
  final _micLevel = StreamController<double>.broadcast();
  Stream<double> get micLevelStream => _micLevel.stream;

  /// Live bot audio loudness in [0, 1] (peak per response.audio.delta
  /// chunk). Animates a "speaking" pulse so the button glows in time
  /// with the agent's voice while the avatar's lips move.
  final _botLevel = StreamController<double>.broadcast();
  Stream<double> get botLevelStream => _botLevel.stream;

  /// Open the WebSocket, start the VP-IO audio engine, and begin
  /// forwarding echo-cancelled mic chunks to OpenAI.
  /// [enableMic] false = TEXT-only session: speaker-only audio (no VP-IO mic, no
  /// mic-permission prompt) and no mic→OpenAI forwarding. The agent still replies
  /// with voice + avatar; the user drives it by typing.
  Future<void> start({bool enableMic = true}) async {
    if (_open) return;
    _open = true;
    _status.add(RealtimeStatus.connecting);
    try {
      // Bring up the native audio engine FIRST so VP-IO is already
      // running by the time the WS opens — the very first mic packet
      // we send is already echo-cancelled.
      //
      // vadThreshold: 0 — the native energy barge is intentionally OFF on the
      // cloud path. Barge here is driven by OpenAI server_vad (speech_started →
      // response.cancel + avatar.interrupt), which cancels the cloud response at
      // its source. A local energy cut would silence the speaker without telling
      // OpenAI to stop generating. The vad_threshold knob drives LOCAL mode only.
      await avatar.audioStart(vadThreshold: 0, enableMic: enableMic);
      if (enableMic) {
        _micSub = avatar.micStream.listen(_sendMicBytes);
      }

      await _connectAndConfigure();
      _status.add(RealtimeStatus.open);
    } catch (e) {
      _status.add(RealtimeStatus.error);
      rethrow;
    }
  }

  /// Open the WebSocket and push the session.update config. Used both
  /// by the initial `start()` path and by `_reconnect()` on drops — the
  /// mic subscription + native audio graph stay up across reconnects,
  /// only the WS underneath is rebuilt.
  Future<void> _connectAndConfigure() async {
    // ignore: avoid_print
    print('[realtime] connecting to $_endpoint');
    _serverAcked = false;
    _ws = IOWebSocketChannel.connect(
      Uri.parse(_endpoint),
      headers: {
        'Authorization': 'Bearer $apiKey',
      },
    );
    _wsSub = _ws!.stream.listen(_handleMessage,
        onError: _handleError,
        onDone: _handleDone);
    // Configure the session — GA shape. Audio I/O is nested under
    // `audio.input` / `audio.output`; turn_detection lives inside
    // `audio.input`. PCM16 mono @ 24 kHz both directions.
    _send({
      'type': 'session.update',
      'session': {
        'type': 'realtime',
        // Use the LIVE persona (seeded from `systemPrompt`, kept current by
        // applySettings) — not the immutable constructor field — so a reconnect
        // after a hot persona change doesn't silently revert to the original.
        'instructions': _liveSystemPrompt,
        'output_modalities': ['audio'],
        'audio': {
          'input': {
            'format': {'type': 'audio/pcm', 'rate': 24000},
            // Server-side noise reduction. `far_field` is the hands-free /
            // speakerphone profile — it strips the AEC residual + AGC pumping
            // that was tripping the VAD into a self-talk loop. Mirrors the
            // iOS WebRTC cloud path.
            'noise_reduction': {'type': 'far_field'},
            // server_vad fires `speech_started` on speech ONSET (energy-based),
            // so `interrupt_response` cancels the agent the MOMENT the user
            // starts talking — not after a full sentence. semantic_vad
            // eagerness=low waited for a confident, COMPLETE turn before
            // committing, so the agent talked over the user until they
            // finished. The `far_field` noise reduction above strips the AEC
            // residual that used to make energy-VAD self-fire on the bot's own
            // voice, so onset barge-in is both instant AND echo-safe.
            // `threshold` is the sensitivity dial: RAISE it (e.g. 0.7) if the
            // agent ever interrupts itself on echo; LOWER it if a soft barge-in
            // is missed.
            // semantic_vad: a model decides when you've actually taken a turn, so
            // ambient noise / brief sounds don't interrupt the agent — it replaces
            // the raw energy threshold + duration (server_vad) that were too
            // twitchy. 'eagerness: low' = least eager to end-turn / barge; bump to
            // 'medium' if it feels too slow to respond or to let you interrupt.
            'turn_detection': {
              'type': 'semantic_vad',
              'eagerness': 'low',
              'create_response': true,
              'interrupt_response': true,
            },
            // Surface user transcripts so captions of "what you just said"
            // work. Also doubles as an AEC probe — if transcripts come back
            // with the bot's words, mic is leaking into input.
            'transcription': {'model': 'whisper-1'},
          },
          'output': {
            'format': {'type': 'audio/pcm', 'rate': 24000},
            'voice': voice,
          },
        },
      },
    });
    // Open with a warm greeting — both a friendlier start AND the health check
    // the watchdog validates. Fires on every (re)connect so a recovered socket
    // re-proves itself end to end. NOTE: `response.instructions` REPLACES the
    // session instructions for this one response (it does NOT merge), so we
    // prepend the live persona — otherwise the greeting comes out generic,
    // stripped of the agent's character.
    final greeting = _liveSystemPrompt.isEmpty
        ? _greetingInstructions
        : '$_liveSystemPrompt\n\n$_greetingInstructions';
    _send({
      'type': 'response.create',
      'response': {'instructions': greeting},
    });
    _armConnectionWatchdog();
  }

  void _handleDone() {
    // ignore: avoid_print
    print('[realtime] ws closed');
    if (_open) {
      // Unsolicited drop — caller still wants the session up. Schedule
      // a reconnect; the status flip to `closed` is suppressed so the
      // UI doesn't blink "Disconnected" between attempts.
      _scheduleReconnect();
    } else {
      _status.add(RealtimeStatus.closed);
    }
  }

  void _scheduleReconnect() {
    if (!_open) return;
    if (_reconnectTimer != null) return; // already pending
    if (_reconnectAttempt >= _maxReconnectAttempts) {
      // ignore: avoid_print
      print('[realtime] giving up after $_reconnectAttempt reconnect attempts');
      _status.add(RealtimeStatus.error);
      return;
    }
    // 1, 2, 4, 8, 16, 30, 30, 30 …
    final raw = 1 << _reconnectAttempt;
    final delaySec = raw > 30 ? 30 : raw;
    _reconnectAttempt++;
    // ignore: avoid_print
    print('[realtime] reconnect attempt $_reconnectAttempt in ${delaySec}s');
    // Tear down the dead WS before the next dial — leaving the old
    // _wsSub bound would route the next failure back through this same
    // path while we're already mid-retry.
    _wsSub?.cancel();
    _wsSub = null;
    _ws = null;
    _status.add(RealtimeStatus.connecting);
    _reconnectTimer = Timer(Duration(seconds: delaySec), _reconnect);
  }

  Future<void> _reconnect() async {
    _reconnectTimer = null;
    if (!_open) return;
    try {
      await _connectAndConfigure();
      // NOTE: do NOT reset `_reconnectAttempt` here. `_connectAndConfigure`
      // only awaits the TCP dial — the server can still close the WS
      // immediately afterwards with an event-level error (e.g. when the
      // beta API was deprecated, every dial succeeded then got 4000-closed
      // a beat later). Resetting on TCP-success masked that as an infinite
      // `connecting` loop. The reset now lives in `_handleMessage` on the
      // first inbound event, which proves the server actually accepted us.
      _status.add(RealtimeStatus.open);
    } catch (e) {
      // ignore: avoid_print
      print('[realtime] reconnect failed: $e');
      _ws = null;
      await _wsSub?.cancel();
      _wsSub = null;
      _scheduleReconnect();
    }
  }

  /// When true, mic capture keeps running natively (VP-IO needs it for
  /// echo cancellation reference) but the encoded bytes are NOT
  /// forwarded to OpenAI. The agent stays "deaf" until unmuted.
  bool muted = false;

  /// Live mirror of the system prompt so `applySettings()` can
  /// short-circuit when the value hasn't actually changed (OpenAI
  /// charges a round-trip for every `session.update`).
  String _liveSystemPrompt = '';

  /// Hot-apply the system prompt to the in-flight session via
  /// `session.update { instructions: … }`. Takes effect on the NEXT
  /// agent turn. Returns true if an update was actually sent (the
  /// caller can use this to surface a toast). Safe to call when no
  /// session is open — it just no-ops and returns false.
  ///
  /// IMPORTANT: this method DOES NOT change voice. OpenAI Realtime
  /// locks the session's voice after the model has emitted any audio
  /// — `session.update { voice: … }` mid-call is silently ignored on
  /// the server. To switch voice live, end the WebSocket and start a
  /// new session (see `BithumanRealtimeSession`'s constructor in
  /// main.dart's `_toggleSession`).
  bool applySettings({String? systemPrompt}) {
    if (!_open || _ws == null) return false;
    if (systemPrompt == null || systemPrompt == _liveSystemPrompt) return false;
    _liveSystemPrompt = systemPrompt;
    _send({
      'type': 'session.update',
      'session': {'instructions': systemPrompt},
    });
    // ignore: avoid_print
    print('[realtime] session.update instructions (${systemPrompt.length} chars)');
    return true;
  }

  int _micDbgN = 0;
  void _sendMicBytes(Uint8List pcm24kPcm16le) {
    if (!_open || _ws == null || pcm24kPcm16le.isEmpty) return;
    // Compute peak/32768 for the "mic is hot" UI pulse. Cannot use
    // Int16List.view here — Flutter's EventChannel may hand back a
    // Uint8List whose offsetInBytes is odd, which fails the
    // BYTES_PER_ELEMENT alignment check and throws RangeError. Decode
    // little-endian Int16 pairs manually instead; no alignment
    // requirement and the throw was previously taking down _sendMicBytes
    // BEFORE the WS send, so OpenAI was getting zero audio.
    int peak = 0;
    final n = pcm24kPcm16le.length & ~1; // round down to even
    for (int i = 0; i < n; i += 16) {
      final lo = pcm24kPcm16le[i];
      final hi = pcm24kPcm16le[i + 1];
      var s = (hi << 8) | lo;
      if ((s & 0x8000) != 0) s -= 0x10000;
      final v = s < 0 ? -s : s;
      if (v > peak) peak = v;
    }
    _micLevel.add(peak / 32768.0);
    if (muted) {
      if (++_micDbgN % 50 == 0) print('[mic-dbg] MUTED, not sending (peak=$peak)');
      return;
    }
    _send({
      'type': 'input_audio_buffer.append',
      'audio': base64Encode(pcm24kPcm16le),
    });
    if (++_micDbgN % 50 == 0) print('[mic-dbg] sent #$_micDbgN to OpenAI, peak=$peak');
  }

  /// Mark the end of the user's turn explicitly (when server VAD is off).
  void commitInputAudio() {
    _send({'type': 'input_audio_buffer.commit'});
    _send({'type': 'response.create'});
  }

  /// Send a typed user message. This BARGES exactly like a spoken turn: if a
  /// response is in flight it cancels it + stops the speaker/lipsync (mirrors the
  /// `input_audio_buffer.speech_started` path) BEFORE adding the user's text and
  /// requesting a new response — so typing never stacks onto a reply the agent is
  /// still giving (the inconsistency this fixes).
  Future<void> sendText(String text) async {
    final t = text.trim();
    if (t.isEmpty || !_open) return;
    if (_haveActiveResponse) {
      _send({'type': 'response.cancel'});
    }
    _droppingCancelledAudio = true;
    _resetAudioPacing();
    try {
      await avatar.interrupt();
    } catch (_) {}
    if (!_open) return;
    _send({
      'type': 'conversation.item.create',
      'item': {
        'type': 'message',
        'role': 'user',
        'content': [
          {'type': 'input_text', 'text': t},
        ],
      },
    });
    _send({'type': 'response.create'});
    // Typed input is a committed user turn with no speech_stopped event — emit
    // userStopped (→ TransportStatus.thinking) so the neon "thinking" rim shows
    // immediately, exactly like a spoken turn, until response.done.
    _status.add(RealtimeStatus.userStopped);
  }

  Future<void> stop() async {
    if (!_open) return;
    _open = false;
    // Cancel any pending reconnect — must come BEFORE clearing _open's
    // effects so a timer firing mid-stop sees `!_open` and bails. The
    // guard inside `_reconnect()` already double-checks this.
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempt = 0;
    // Kill the validation watchdog too — a user hang-up inside the 8 s
    // greeting window must not leave a timer that later fires (it would
    // no-op on `!_open`, but cancelling is cleaner and avoids the leak).
    _cancelConnectionWatchdog();
    _stressTimer?.cancel();
    _stressTimer = null;
    // Drop any post-disconnect audio.delta that's still in flight on
    // the WS read buffer — without this they'd push lipsync into the
    // avatar even after we've torn the session down.
    _droppingCancelledAudio = true;
    _resetAudioPacing(); // release any delta parked in a pacing delay

    // Wipe the lipsync queue + stop the speaker player IMMEDIATELY.
    // Without this, the avatar keeps animating the agent's last
    // buffered audio for ~1-2 s after the user hangs up.
    try { await avatar.interrupt(); } catch (_) {}
    await _micSub?.cancel();
    _micSub = null;
    await _wsSub?.cancel();
    await _ws?.sink.close();
    _ws = null;
    try { await avatar.audioStop(); } catch (_) {}
    _status.add(RealtimeStatus.closed);
  }

  // -------- internals --------

  void _send(Map<String, dynamic> evt) {
    final ws = _ws;
    if (ws == null) return;
    ws.sink.add(jsonEncode(evt));
  }

  Future<void> _handleMessage(dynamic raw) async {
    if (raw is! String) return;
    final evt = jsonDecode(raw) as Map<String, dynamic>;
    final type = evt['type'] as String?;
    // Any inbound event proves the server accepted the handshake — it's
    // now safe to reset the reconnect backoff. Doing this here (not in
    // `_reconnect`) catches the case where the dial succeeds but the
    // server kills the WS right after with an event-level error.
    if (!_serverAcked) {
      _serverAcked = true;
      _reconnectAttempt = 0;
    }
    switch (type) {
      case 'response.output_audio.delta':
        if (_droppingCancelledAudio) {
          // Tail-end of a response we already cancelled — OpenAI had
          // these chunks in flight when speech_started fired. Drop
          // them or the lipsync keeps animating after the speaker
          // went silent.
          break;
        }
        final b64 = evt['delta'] as String?;
        if (b64 == null) return;
        final pcm24kBytes = base64Decode(b64);
        // Cheap peak for the "agent speaking" UI pulse. Same Int16List
        // alignment trap as the mic path — decode pairs of bytes
        // manually so an odd offsetInBytes never crashes us.
        int bpeak = 0;
        final bn = pcm24kBytes.length & ~1;
        for (int i = 0; i < bn; i += 32) {
          final lo = pcm24kBytes[i];
          final hi = pcm24kBytes[i + 1];
          var s = (hi << 8) | lo;
          if ((s & 0x8000) != 0) s -= 0x10000;
          final v = s < 0 ? -s : s;
          if (v > bpeak) bpeak = v;
        }
        _botLevel.add(bpeak / 32768.0);
        // Pace to ~1x real time before handing the chunk to the plugin, so
        // the lipsync queue can't backlog under OpenAI's faster-than-real-time
        // burst (the cause of cloud A/V drift). Reserve this chunk's playback
        // slot SYNCHRONOUSLY — `_handleMessage` is async and the stream doesn't
        // serialize it, so burst deltas run concurrently; advancing
        // `_audioBufferedUntil` before the await is what keeps them ordered
        // instead of all reading the same stale clock.
        final gen = _audioGen;
        final chunkDur = Duration(
            microseconds: ((pcm24kBytes.length ~/ 2) * 1000000 / 24000).round());
        final now = DateTime.now();
        final playAt = _audioBufferedUntil.isAfter(now) ? _audioBufferedUntil : now;
        _audioBufferedUntil = playAt.add(chunkDur);
        // Release `_paceLead` early so the speaker never starves on jitter.
        final waitMs =
            playAt.difference(now).inMilliseconds - _paceLead.inMilliseconds;
        if (waitMs > 0) {
          await Future<void>.delayed(Duration(milliseconds: waitMs));
          // A barge/cancel/new-turn/stop while we were parked invalidates this
          // chunk (it belongs to a response that's no longer playing).
          if (gen != _audioGen || _droppingCancelledAudio || !_open) break;
        }
        // Single call drives BOTH the speaker (VP-IO player node) AND
        // the avatar's lipsync queue from the same chunk in the same
        // instant. A/V cannot drift; VP-IO's AEC means the speaker
        // output never feeds back into the mic.
        await avatar.playSpeakerPCM(pcm24kBytes);
        break;
      case 'response.created':
        // OpenAI is starting a NEW response — any post-barge backlog
        // is behind us; resume forwarding audio.delta normally.
        _droppingCancelledAudio = false;
        _haveActiveResponse = true;
        _resetAudioPacing(); // fresh turn plays immediately, no carried lead
        _markConnectionValidated(); // the server is responding → socket healthy
        break;
      case 'response.cancelled':
        _haveActiveResponse = false;
        // A cancellation (ours via barge, or server-initiated) means any
        // audio.delta still in flight belongs to the killed response — drop
        // it so the lipsync doesn't animate audio the user never hears.
        // (Mirrors the WebRTC openai_webrtc_session response.cancelled fix.)
        _droppingCancelledAudio = true;
        _resetAudioPacing(); // invalidate any delta still parked in a pacing delay
        break;
      case 'response.output_audio_transcript.delta':
        final delta = evt['delta'] as String?;
        if (delta != null && delta.isNotEmpty) {
          _botTranscript.add(delta);
        }
        break;
      case 'conversation.item.input_audio_transcription.completed':
        final t = evt['transcript'] as String?;
        if (t != null && t.isNotEmpty) _userTranscript.add(t);
        // AEC probe (mirrors openai_webrtc_session): what the server heard
        // on the user-mic leg. If these come back with the BOT's words, the
        // speaker is leaking into the mic past the AEC; room voices show up
        // as themselves. Log-only — drives the stress-protocol scoring.
        // ignore: avoid_print
        print('[AEC-PROBE] user-mic transcript: "${t ?? ''}"');
        break;
      case 'response.done':
        _haveActiveResponse = false;
        _status.add(RealtimeStatus.responseDone);
        // Flush the avatar's final partial lipsync chunk so the last word isn't
        // clipped. response.done arrives BEFORE the paced audio deltas finish
        // being handed to playSpeakerPCM (client-side _paceLead pacing), so defer
        // the flush until the pacing queue (_audioBufferedUntil, reserved
        // synchronously per delta) has drained. Gate on _audioGen so a barge /
        // cancel between here and the deferred call drops the flush (the cloud
        // analogue of the native barge gen-fence) — it must never land after
        // interrupt() reset the runtime for a new turn.
        final flushGen = _audioGen;
        final flushDrainAt = _audioBufferedUntil;
        unawaited(() async {
          final waitMs = flushDrainAt.difference(DateTime.now()).inMilliseconds;
          if (waitMs > 0) {
            await Future<void>.delayed(Duration(milliseconds: waitMs));
          }
          if (_open && !_droppingCancelledAudio && flushGen == _audioGen) {
            try { await avatar.notifyTurnEnd(); } catch (_) {}
          }
        }());
        if (_devStress) _scheduleStressTurn(const Duration(seconds: 2));
        break;
      case 'input_audio_buffer.speech_started':
        // Barge-in: fire the moment server-VAD detects the user has
        // started talking. Three parallel actions:
        //   1. response.cancel — tell OpenAI to stop generating the
        //      current response.
        //   2. avatar.interrupt() — stop the local speaker + lipsync
        //      so the agent doesn't keep talking from already-buffered
        //      response.audio.delta chunks.
        //   3. _droppingCancelledAudio — drop further deltas for the
        //      cancelled response.
        // On Android this depends on USAGE_VOICE_COMMUNICATION audio
        // being routed through the speakerphone (MODE_IN_COMMUNICATION
        // + setSpeakerphoneOn=true) so the platform AcousticEchoCanceler
        // can effectively suppress the agent's voice from leaking
        // back through the mic. Without speakerphone routing the
        // earpiece-mic path has weak AEC and the server fires false
        // speech_started events on agent-self-leak.
        if (_haveActiveResponse) {
          _send({'type': 'response.cancel'});
        }
        _droppingCancelledAudio = true;
        _resetAudioPacing(); // drop any delta parked in a pacing delay
        await avatar.interrupt();
        _status.add(RealtimeStatus.userSpeaking);
        break;
      case 'input_audio_buffer.speech_stopped':
        _status.add(RealtimeStatus.userStopped);
        break;
      case 'error':
        final err = evt['error'] as Map<String, dynamic>?;
        final code = (err?['code'] as String?) ?? '';
        final msg = (err?['message'] as String?) ?? '';
        // Soft / non-fatal server errors — log but DO NOT flip the UI
        // to "Connection error". Examples:
        //   - cancellation_failed: we tried to cancel when nothing
        //     was in flight (also gated upstream, but defense in depth)
        //   - input_audio_buffer_commit_empty: server VAD didn't hear
        //     any speech in the buffer
        //   - rate_limit / similar: visible elsewhere, not a "down" state
        final soft = code.contains('cancellation_failed') ||
            code.contains('input_audio_buffer_commit_empty') ||
            msg.contains('no active response');
        // ignore: avoid_print
        print('[realtime] server ${soft ? "warning" : "error"}: '
            '${code.isEmpty ? msg : "$code — $msg"}');
        if (!soft) {
          _status.add(RealtimeStatus.error);
        }
        break;
      // Other event types (session.created, session.updated, response.created,
      // response.audio_transcript.delta, …) are informational — ignore for v0.2.
      default:
        break;
    }
  }

  void _handleError(Object e) {
    // ignore: avoid_print
    print('[realtime] ws error: $e');
    if (_open) {
      // Treat as a drop and reconnect — don't flip to .error yet, the
      // backoff schedule will surface .error itself if all retries
      // exhaust. Spurious .error here would make the UI strobe.
      _scheduleReconnect();
    } else {
      _status.add(RealtimeStatus.error);
    }
  }

}

enum RealtimeStatus {
  connecting,
  open,
  userSpeaking,
  userStopped,
  responseDone,
  closed,
  error,
}
