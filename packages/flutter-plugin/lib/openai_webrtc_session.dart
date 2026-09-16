// OpenAI Realtime over WebRTC — Dart client. The iOS + Android cloud
// transport: libwebrtc owns mic + speaker + AEC, and this file is the
// peer-connection lifecycle + SDP exchange + data-channel event handling.
// macOS cloud uses the WebSocket path (BithumanRealtimeSession + native
// VP-IO) instead.
//
// Lipsync IS wired: the bithuman plugin attaches an RTCAudioRenderer to this
// peer connection's remote audio track (attachWebrtcRemoteAudio) and feeds the
// exact PCM the speaker plays into the avatar's lipsync queue. On barge-in
// `avatar.interrupt()` flushes that queue.
//
// (Originally ported from the openai_realtime_android probe; Android revived
// 2026-06 — agent voice plays through flutter_webrtc's audio path: AudioSwitch
// requests audio focus, sets MODE_IN_COMMUNICATION and prefers the
// speakerphone, so the voice-call volume keys control the agent's loudness.)
//
// Apache-2.0; (c) bitHuman.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpClient, HttpClientResponse, Platform;

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'src/dev_levers.dart';
import 'src/echo_profile.dart';

enum WebRTCStatus {
  idle,
  connecting,
  open,
  userSpeaking,
  userStopped,
  responseDone,
  closed,
  error,
}

class OpenAIWebRTCSession {
  OpenAIWebRTCSession({
    required this.apiKey,
    required this.model,
    required this.voice,
    required this.systemPrompt,
    required this.vadThreshold,
  });

  final String apiKey;
  final String model;
  final String voice;
  // iOS cloud (WebRTC) leaves barge-in to OpenAI's server_vad: libwebrtc owns
  // the mic inside its own APM, so there is no native mic tap to run the energy
  // VAD against. This value is carried for parity with the other transports'
  // interface but is NOT applied here (the native energy `vad_threshold` is a
  // LOCAL-mode knob).
  final int vadThreshold;
  /// Mutable so `applySettings(systemPrompt: …)` can update the active
  /// session at runtime via a data-channel `session.update` event. The
  /// stored value tracks what the server currently has, so a subsequent
  /// reconnect / re-`_sendSessionUpdate` keeps using the latest prompt.
  String systemPrompt;

  /// VOICE POLICY (2026-06, user ruling): the agent must NEVER speak
  /// unprompted — every utterance is a response to user speech. The warm
  /// connect greeting (a8eeca9, Android-gated) violated that, so it is now
  /// DEV-ONLY: `--dart-define=BITHUMAN_DEV_GREETING=true` re-enables it as
  /// the deterministic full-path health check (token → SDP → data channel →
  /// model → remote audio → speaker) it doubled as. Default-off in every
  /// build that doesn't set the define explicitly.
  static const _devGreeting = DevLevers.greeting;

  /// Dev-only connect greeting (see the data-channel open handler).
  /// Mirrors BithumanRealtimeSession._greetingInstructions (WS transport).
  static const _greetingInstructions =
      'To open the conversation, greet the user warmly in one short, friendly sentence.';

  /// STRESS MODE (dev-only, `--dart-define=BITHUMAN_DEV_STRESS=true`): the
  /// self-interruption stress driver (task #56). Once the data channel opens
  /// the driver requests a LONG monologue, and re-requests another one a
  /// couple of seconds after each `response.done` — continuous agent speech
  /// with ZERO user input. Under that protocol every
  /// `input_audio_buffer.speech_started` the server reports is by
  /// construction SPURIOUS (the agent's own speaker echo / room noise
  /// tripping server VAD — the barge-storm signature this mode exists to
  /// measure). Pair with scripts/stress-webrtc-iphone.sh, which captures the
  /// console and computes barge-ins/min. Mutually exclusive with
  /// BITHUMAN_DEV_GREETING (both fire response.create on channel open).
  /// Default-off in every build that doesn't set the define explicitly.
  static const _devStress = DevLevers.stress;

  /// Stress-turn instructions: long uninterrupted speech maximises the
  /// echo-exposure window per turn. `response.instructions` REPLACES the
  /// session instructions for the one response, so keep it self-contained.
  static const _stressInstructions =
      'Speak an uninterrupted monologue of roughly sixty seconds on any '
      'interesting topic. Do not pause for questions, do not address the '
      'listener, do not stop early.';

  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  RTCDataChannel? _dc;
  MediaStreamTrack? _remoteAudioTrack;
  Timer? _stressTimer;
  int _stressTurn = 0;

  final _status = StreamController<WebRTCStatus>.broadcast();
  Stream<WebRTCStatus> get statusStream => _status.stream;

  final _transcript = StreamController<String>.broadcast();
  Stream<String> get botTranscriptStream => _transcript.stream;

  /// Fires whenever OpenAI cancels its in-flight audio (user
  /// barge-in, response.cancelled, etc.). Subscribe and call
  /// `avatar.interrupt()` so the lipsync queue is wiped — otherwise
  /// the mouth keeps articulating audio the user never hears.
  final _interrupt = StreamController<void>.broadcast();
  Stream<void> get interruptStream => _interrupt.stream;

  /// Fires when libwebrtc has attached the remote audio track and
  /// the data channel has reached the `session.updated` state, i.e.
  /// when it's safe to call `attachWebrtcRemoteAudio` on the avatar.
  final _remoteReady = StreamController<MediaStreamTrack>.broadcast();
  Stream<MediaStreamTrack> get remoteAudioReadyStream =>
      _remoteReady.stream;

  /// The remote audio track libwebrtc just attached. Phase 2 reads
  /// this from the Dart side and forwards its id to the bithuman
  /// plugin so the plugin's Kotlin code can attach an AudioTrackSink.
  MediaStreamTrack? get remoteAudioTrack => _remoteAudioTrack;

  /// True while the agent's voice is audibly playing on the speaker —
  /// tracks `output_audio_buffer.started/stopped/cleared` (the WebRTC
  /// outbound buffer, not OpenAI's generation state, so it matches what
  /// the user actually hears). The Android transport forwards this to the
  /// avatar plugin (`setSpeaking`) so the frames-path mouth goes quiet
  /// between responses.
  final _agentSpeaking = StreamController<bool>.broadcast();
  Stream<bool> get agentSpeakingStream => _agentSpeaking.stream;

  /// Mute/unmute the mic by toggling the local audio track(s)'s `enabled`
  /// flag. No-op until getUserMedia has produced the local stream.
  void setMicMuted(bool muted) {
    final s = _localStream;
    if (s == null) return;
    for (final t in s.getAudioTracks()) {
      t.enabled = !muted;
    }
  }

  bool _open = false;
  // True between `output_audio_buffer.started` and
  // `output_audio_buffer.stopped`. Kept ONLY as a diagnostic flag
  // for the `[AEC-PROBE]` line so we can correlate user-mic
  // transcripts with whether the bot was audibly playing at the
  // moment OpenAI transcribed our uplink. The mic is never muted —
  // full duplex always. AEC has to do its job.
  bool _agentAudioOut = false;

  Future<void> start() async {
    if (_open) return;
    _open = true;
    _status.add(WebRTCStatus.connecting);
    try {
      await _setUpPeerConnection();
      await _negotiateWithOpenAI();
      _status.add(WebRTCStatus.open);
    } catch (e) {
      // ignore: avoid_print
      print('[webrtc] start failed: $e');
      _status.add(WebRTCStatus.error);
      await stop();
      rethrow;
    }
  }

  /// Stress driver (see [_devStress]): request the next long monologue.
  /// Single pending timer — a barge-storm's cancel→done bursts must not
  /// stack multiple queued turns (response.create while one is active
  /// surfaces as a harmless `error` event, but it muddies the metric log).
  void _scheduleStressTurn(Duration delay) {
    _stressTimer?.cancel();
    _stressTimer = Timer(delay, () {
      if (!_open || _dc == null) return;
      _stressTurn += 1;
      // ignore: avoid_print
      print('[stress] turn $_stressTurn requested');
      _sendEvent({
        'type': 'response.create',
        'response': {'instructions': _stressInstructions},
      });
    });
  }

  Future<void> stop() async {
    if (!_open && _pc == null) return;
    _open = false;
    _stressTimer?.cancel();
    _stressTimer = null;
    try { await _dc?.close(); } catch (_) {}
    _dc = null;
    try {
      _localStream?.getTracks().forEach((t) => t.stop());
      await _localStream?.dispose();
    } catch (_) {}
    _localStream = null;
    try { await _pc?.close(); } catch (_) {}
    _pc = null;
    _remoteAudioTrack = null;
    if (!_agentSpeaking.isClosed) _agentSpeaking.add(false);
    _status.add(WebRTCStatus.closed);
  }

  Future<void> dispose() async {
    await stop();
    await _status.close();
    await _transcript.close();
    await _interrupt.close();
    await _remoteReady.close();
    await _agentSpeaking.close();
  }

  Future<void> _setUpPeerConnection() async {
    final pc = await createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
      'sdpSemantics': 'unified-plan',
    });
    _pc = pc;
    pc.onConnectionState = (state) {
      // ignore: avoid_print
      print('[webrtc] pc state: $state');
      // iOS WebRTC defaults to playAndRecord + voiceChat with NO
      // defaultToSpeaker, so output routes to the EARPIECE and is attenuated
      // ("super low volume even at max"). setSpeakerphoneOn(true) ORs in
      // .defaultToSpeaker + overrideOutputAudioPort(.speaker) while leaving
      // category=playAndRecord and mode=voiceChat UNCHANGED — so libwebrtc's
      // APM/AEC reference (the playAndRecord render path) is preserved and only
      // the physical output port flips earpiece→loud speaker (barge-in intact).
      // Fire it once the session is provably active; the route override does not
      // survive a pre-activation call. (Android retired → the old
      // after-getUserMedia AEC-desync caveat below no longer applies.)
      if (Platform.isIOS &&
          state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        Helper.setSpeakerphoneOn(true);
      }
    };
    pc.onTrack = (event) {
      if (event.track.kind == 'audio') {
        _remoteAudioTrack = event.track;
        // ignore: avoid_print
        print('[webrtc] remote audio attached: ${event.track.id}');
        // libwebrtc auto-renders the remote audio through the Android
        // WebRtcAudio module. Surface the track so the avatar plugin
        // can `attachWebrtcRemoteAudio(track.id)` and feed lipsync
        // from the EXACT same PCM the speaker is playing.
        if (!_remoteReady.isClosed) _remoteReady.add(event.track);
      }
    };

    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
      },
      'video': false,
    });
    for (final track in _localStream!.getAudioTracks()) {
      await pc.addTrack(track, _localStream!);
    }

    // NOTE: deliberately NOT calling Helper.setSpeakerphoneOn here.
    // Doing it AFTER getUserMedia desyncs libwebrtc's AEC reference
    // path on Android — the APM was initialized against one routing
    // and then the audio mode flipped under it. The validated probe
    // runs on whatever routing the system inherits (Z Fold 5 sticks
    // on speakerphone once another VOIP-mode app set it), and AEC
    // works there. We rely on that here too.

    final dc = await pc.createDataChannel(
        'oai-events', RTCDataChannelInit()..ordered = true);
    _dc = dc;
    dc.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        _sendSessionUpdate();
        // VOICE POLICY: no proactive speech — the agent only responds to
        // the user. The old Android connect greeting is opt-in dev-only
        // now (BITHUMAN_DEV_GREETING dart-define; see _devGreeting). NOTE:
        // `response.instructions` REPLACES the session instructions for
        // this one response, so the live persona is prepended — otherwise
        // the greeting comes out generic.
        if (_devGreeting) {
          final greeting = systemPrompt.isEmpty
              ? _greetingInstructions
              : '$systemPrompt\n\n$_greetingInstructions';
          _sendEvent({
            'type': 'response.create',
            'response': {'instructions': greeting},
          });
        }
        // Stress driver: first long turn shortly after the session config
        // lands (the delay lets session.updated apply before the response).
        if (_devStress) _scheduleStressTurn(const Duration(seconds: 2));
      }
    };
    dc.onMessage = _handleDataMessage;
  }

  Future<void> _negotiateWithOpenAI() async {
    final pc = _pc!;
    final offer = await pc.createOffer({});
    await pc.setLocalDescription(offer);
    final uri =
        Uri.parse('https://api.openai.com/v1/realtime/calls?model=$model');
    final client = HttpClient();
    try {
      final req = await client.postUrl(uri);
      req.headers.set('Authorization', 'Bearer $apiKey');
      req.headers.set('Content-Type', 'application/sdp');
      req.add(utf8.encode(offer.sdp!));
      final HttpClientResponse res = await req.close();
      if (res.statusCode != 200 && res.statusCode != 201) {
        final body = await res.transform(utf8.decoder).join();
        throw StateError(
            'OpenAI Realtime SDP exchange HTTP ${res.statusCode}: $body');
      }
      final answerSdp = await res.transform(utf8.decoder).join();
      await pc.setRemoteDescription(RTCSessionDescription(answerSdp, 'answer'));
    } finally {
      client.close();
    }
  }

  void _sendSessionUpdate() {
    // New (2026-Q2) OpenAI Realtime session schema. Everything
    // audio-related moved under `session.audio.{input,output}.*`,
    // and `modalities` was renamed to `output_modalities`. Sending
    // the old shape silently invalidates the entire session.update
    // — the server keeps a fully-default config and you only find
    // out because `session.created` echoes back the wrong values
    // and a stray `error` event mentions a single unknown
    // parameter. The default config has threshold=0.5/silence=200,
    // which is hair-trigger and turns any speaker→mic residual
    // into a self-talk loop.
    _sendEvent({
      'type': 'session.update',
      'session': {
        'type': 'realtime',
        'output_modalities': ['audio'],
        'instructions': systemPrompt,
        'audio': {
          'input': {
            'format': {'type': 'audio/pcm', 'rate': 24000},
            // Server-side noise reduction. `far_field` is the
            // hands-free / speakerphone profile — it strips the
            // exact kind of AEC residual + AGC pumping that was
            // tripping server_vad on empty audio.
            'noise_reduction': {'type': 'far_field'},
            'transcription': {
              'model': 'gpt-4o-mini-transcribe',
            },
            // server_vad fires `speech_started` on speech ONSET (energy-based
            // on the user's mic stream), so `interrupt_response` cancels the
            // agent the MOMENT the user starts — matching the WebSocket path and
            // the native energy barge. (semantic_vad eagerness=low, the old
            // config, waited for a confident COMPLETE turn, so the bot talked
            // over the user — the wrong behaviour for instant barge.) The native
            // `vad_threshold` knob has no effect here: WebRTC owns the mic inside
            // libwebrtc, so the server's own threshold is the dial — the DEVICE
            // row in EchoProfile, the same table the WebSocket path reads.
            // far_field noise reduction (above) keeps AEC residual from
            // false-tripping it.
            'turn_detection': {
              'type': 'server_vad',
              'threshold': EchoProfile.current.serverVadThreshold,
              'prefix_padding_ms': 300,
              'silence_duration_ms': 500,
              'create_response': true,
              'interrupt_response': true,
            },
          },
          'output': {
            'voice': voice,
          },
        },
      },
    });
  }

  void _sendEvent(Map<String, dynamic> evt) {
    final dc = _dc;
    if (dc == null) return;
    dc.send(RTCDataChannelMessage(jsonEncode(evt)));
  }

  /// Live-update session settings (today: just the system prompt) on
  /// an open peer connection. Sends a partial `session.update` event
  /// over the data channel so the server applies the change to the
  /// next turn — no reconnect required. Returns true if at least one
  /// field was applied.
  ///
  /// No-ops when the data channel isn't open yet (called before
  /// `start()` returns or after `stop()`); callers should still update
  /// their own copy of the prompt so a subsequent reconnect picks it
  /// up.
  bool applySettings({String? systemPrompt}) {
    var applied = false;
    if (systemPrompt != null && systemPrompt != this.systemPrompt) {
      this.systemPrompt = systemPrompt;
      applied = true;
    }
    final dc = _dc;
    if (!applied || dc == null) return applied;
    // Send ONLY the changed fields. The Realtime API merges with the
    // current session config so we don't need to repeat audio.input.*
    // / audio.output.* / output_modalities each time — those stay as
    // _sendSessionUpdate set them.
    _sendEvent({
      'type': 'session.update',
      'session': {
        'type': 'realtime',
        'instructions': this.systemPrompt,
      },
    });
    return true;
  }

  void _handleDataMessage(RTCDataChannelMessage msg) {
    if (msg.isBinary) return;
    try {
      final evt = jsonDecode(msg.text) as Map<String, dynamic>;
      final type = evt['type'] as String?;
      // Log every event type so we can see the full server-side flow
      // (especially response.* events that confirm the bot is
      // actually producing audio).
      if (type != null &&
          type != 'response.audio.delta' &&
          type != 'response.audio_transcript.delta') {
        // ignore: avoid_print
        print('[webrtc] ← $type');
      }
      switch (type) {
        // Transcript deltas — note BOTH old + new schema names so
        // this code keeps working if OpenAI flips again.
        case 'response.output_audio_transcript.delta':
        case 'response.audio_transcript.delta':
          final delta = evt['delta'] as String?;
          if (delta != null && delta.isNotEmpty) _transcript.add(delta);
          break;
        case 'response.done':
          _status.add(WebRTCStatus.responseDone);
          // Stress driver: keep the agent talking. The 2.5 s gap lets the
          // outbound audio buffer drain (response.done fires while the tail
          // is still playing) without ever leaving a long silence — the
          // point is maximum continuous speaker output.
          if (_devStress && _open) {
            _scheduleStressTurn(const Duration(milliseconds: 2500));
          }
          break;
        case 'response.cancelled':
          // Server cancelled the response mid-stream. Wipe the avatar's
          // lipsync queue (same as output_audio_buffer.cleared below) so the
          // mouth doesn't keep animating audio the user never hears, THEN mark
          // the response done for the UI. Previously this shared the
          // response.done case and the interrupt never fired.
          if (!_interrupt.isClosed) _interrupt.add(null);
          _status.add(WebRTCStatus.responseDone);
          break;
        // The TRUE "bot is producing sound on the speaker" window —
        // tracks the WebRTC outbound buffer, not OpenAI's generation
        // state. Used only as a diagnostic flag on the AEC probe;
        // no muting happens.
        case 'output_audio_buffer.started':
          _agentAudioOut = true;
          if (!_agentSpeaking.isClosed) _agentSpeaking.add(true);
          break;
        case 'output_audio_buffer.stopped':
          _agentAudioOut = false;
          if (!_agentSpeaking.isClosed) _agentSpeaking.add(false);
          break;
        case 'output_audio_buffer.cleared':
          // User barged in / response cancelled mid-stream. We MUST
          // wipe the avatar's lipsync queue or the mouth will keep
          // animating audio the user never hears — phantom talking.
          _agentAudioOut = false;
          if (!_agentSpeaking.isClosed) _agentSpeaking.add(false);
          if (!_interrupt.isClosed) _interrupt.add(null);
          break;
        case 'input_audio_buffer.speech_started':
          // ignore: avoid_print
          print('[webrtc] speech_started '
              '(agentAudioOut=$_agentAudioOut)');
          _status.add(WebRTCStatus.userSpeaking);
          break;
        case 'input_audio_buffer.speech_stopped':
          _status.add(WebRTCStatus.userStopped);
          break;
        case 'session.created':
        case 'session.updated':
          // Useful to confirm what config OpenAI actually accepted.
          // ignore: avoid_print
          print('[webrtc] $type — session: ${evt['session']}');
          break;
        case 'conversation.item.input_audio_transcription.completed':
          final txt = (evt['transcript'] as String?)?.trim() ?? '';
          // ignore: avoid_print
          print('[AEC-PROBE] user-mic transcript '
              '(agentAudioOut=$_agentAudioOut): "$txt"');
          break;
        case 'conversation.item.input_audio_transcription.delta':
          final delta = (evt['delta'] as String?)?.trim() ?? '';
          if (delta.isNotEmpty) {
            // ignore: avoid_print
            print('[AEC-PROBE] (delta, agentAudioOut=$_agentAudioOut): "$delta"');
          }
          break;
        case 'conversation.item.input_audio_transcription.failed':
          // ignore: avoid_print
          print('[AEC-PROBE] transcription failed: ${evt['error']}');
          break;
        case 'error':
          // ignore: avoid_print
          print('[webrtc] error event: ${evt['error']}');
          _status.add(WebRTCStatus.error);
          break;
      }
    } catch (e) {
      // ignore: avoid_print
      print('[webrtc] dc parse: $e');
    }
  }
}
