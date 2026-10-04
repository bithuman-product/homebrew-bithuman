// voice_host.dart — the ONE edge the Dart voice module has on the render module,
// inverted. This is the Dart twin of `shared/Classes/Protocol/LipsyncSink.swift`.
//
// ★WHY THIS EXISTS. `bithuman_realtime.dart` (the OpenAI Realtime client) and
// `realtime_transport.dart` (the three transports + the factory) are the VOICE
// module. Until now both opened with `import 'bithuman.dart'` and typed their
// audio host as the concrete render class `BithumanAvatar` — four constructors
// carrying `required BithumanAvatar avatar`. That import is the whole reason
// "voice with no render" was untypeable in Dart, and it is the same defect the
// Swift side carried until 2026-09-16: the dependency lived in the TYPE, not in
// the behaviour. Every call the voice module makes on that object is a VOICE
// verb on the `ai.bithuman.avatar` channel — mic, speaker, echo canceller, the
// on-device brain — plus the four the ARCHITECTURE.md census classes as "both".
// Not one of them is `load`, `setDisplayMode`, `pushAudio`, PiP or a texture id.
//
// So the edge is turned rather than cut: voice declares the surface it needs,
// render CONFORMS to it. `BithumanAvatar implements VoiceHost` in bithuman.dart
// with no new code — every member below already existed there, with these exact
// signatures — and the arrow now points render → voice.
//
// ★THE MEMBER SET IS MEASURED, NOT DESIGNED. It is every member the two voice
// files invoke on the avatar and no other, read off the source on 2026-09-16:
//   bithuman_realtime.dart  nativeLog · audioStart · micStream · playSpeakerPCM ·
//                           notifyTurnEnd · interrupt · audioStop
//   realtime_transport.dart attachWebrtcRemoteAudio · detachWebrtcRemoteAudio ·
//                           interrupt · localAudioStart · localAudioStop ·
//                           localPushText · localSetMuted · converseEvents
// `scripts/check_voice_render_edge_dart.sh` re-derives that list from the source
// on every push and fails if the voice files grow a member this protocol does
// not name, or name the render class again.
//
// ★WHAT A SECOND CONFORMER BUYS. "To test voice chat we do not even need
// visuals" — a conformer with no engine, no texture and no platform channel lets
// a REAL `BithumanRealtimeSession` run end to end against a recorded host.
// `test/e2e/headless_voice_host_test.dart` is exactly that and it RUNS in CI; a
// headless lipsync recorder, an Android-shaped bridge or a second app's audio
// stack conform by writing these sixteen.
//
// ★2.6.25 ADDED ONE: [VoiceHost.audioInterruptions]. The platform taking the
// session's sound away (a phone call answered from its banner leaves the app on
// screen) is a voice fact the session must act on: the call was billed under it.
//
// ★2.6.27 ADDED ONE: [VoiceHost.speechPlayout]. How much of the agent's audio the
// listener has actually heard is a voice fact too: a reply's audio is handed over
// in a burst, so only the host knows where the voice is, and captions released
// on arrival ran seconds ahead of it (src/spoken_captions.dart).
//
// ★2.6.29 ADDED ONE: [VoiceHost.modelRejections]. An engine that refuses the model file it
// was asked to render (an Essence 2 avatar file published before the engine's current format)
// left a still face and a session that talked on behind it. It is terminal, like a paywall:
// the session ends with `MODEL_REJECTED` on its errorStream.
//
// The engine side of the same line is `src/engine_protocol.dart`; the native
// side is `Protocol/LipsyncSink.swift` and `Protocol/BithumanEngine.swift`.
//
// Apache-2.0; (c) bitHuman.

import 'dart:typed_data' show Uint8List;

/// The platform surface a realtime voice session drives: a microphone, a
/// speaker, an echo canceller, and — optionally — a mouth to move with the
/// audio it is handed.
///
/// `BithumanAvatar` is the conformer that ships (it is the Dart handle on the
/// `ai.bithuman.avatar` channel, and 11 of that channel's verbs are voice-only
/// with 4 more shared — see ARCHITECTURE.md "which half is voice"). Nothing
/// here is render: a conformer that draws nothing is a valid voice host and is
/// what the headless harness uses.
abstract class VoiceHost {
  // ── diagnostics ────────────────────────────────────────────────────────────

  /// Write one line into the host's native log stream, beside the presenter's
  /// own lines, so a reader has one stream with one clock. A release iOS build's
  /// Dart `print` never reaches the console a device debugger attaches to, which
  /// is why every transport event an instrument must see goes through here.
  /// Implementations MUST NOT throw — callers fire and forget.
  Future<void> nativeLog(String line);

  // ── the cloud path: native mic + speaker ───────────────────────────────────

  /// Start the host's audio unit (echo-cancelled mic capture + the speaker the
  /// bot's PCM is scheduled on). [enableMic] false = speaker only (text-driven
  /// turns, or no microphone permission). [vpioAgc] is the per-device automatic
  /// gain decision — `EchoProfile.current.vpioAgc` carries the measurement.
  Future<void> audioStart({int vadThreshold, bool enableMic, bool vpioAgc});

  /// Tear the audio unit down. Idempotent.
  Future<void> audioStop();

  /// Echo-cancelled mic capture as 24 kHz mono PCM16 chunks, yielding only
  /// between [audioStart] and [audioStop]. The bot's own voice is already out
  /// of this signal, so the chunks go straight up to the provider.
  Stream<Uint8List> get micStream;

  /// Hand the host 24 kHz mono PCM16 of the bot speaking. A host with a mouth
  /// drives lipsync from the SAME chunk on the same clock, so A/V cannot drift;
  /// a host without one just plays it.
  Future<void> playSpeakerPCM(Uint8List pcm24kPcm16le);

  /// The bot's turn is over and all of its audio has been handed over — flush
  /// any final partial chunk so the last word is not clipped. Never call this
  /// after a barge-in; safe to call repeatedly.
  Future<void> notifyTurnEnd();

  /// Cut the agent off mid-sentence: drop the scheduled speaker queue and wipe
  /// whatever audio is queued for the mouth, so both stop within ~10 ms.
  /// [reason] is carried into the native log for the barge-in audit.
  Future<void> interrupt({String reason});

  // ── the WebRTC path: the bot's audio arrives on someone else's track ───────

  /// Feed the host from the remote WebRTC audio track [trackId] instead of from
  /// [playSpeakerPCM] — libwebrtc owns the speaker on that path, so this is the
  /// only way the mouth can track what the user actually hears.
  Future<void> attachWebrtcRemoteAudio(String trackId);

  /// Reverse of [attachWebrtcRemoteAudio]; also flushes in-flight audio so the
  /// host returns to rest when the session ends.
  Future<void> detachWebrtcRemoteAudio();

  // ── the local path: the on-device brain ───────────────────────────────────

  /// Run the on-device converse brain (ASR → LLM → TTS) instead of a cloud
  /// provider. Registers the event channel synchronously and returns promptly;
  /// the model load runs off-thread and reports through [converseEvents].
  /// [replyMode] `'host'` (Android): speech in and the voice stay on-device and
  /// the app streams the reply text in ([localReplyText]) for each
  /// `reply_request` event — [ggufPath] is then unused.
  Future<void> localAudioStart({
    required String ggufPath,
    String? supertonicAssets,
    String? voice,
    int vadThreshold,
    String systemPrompt,
    String replyMode,
    String? sttDir,
    int maxSentences,
  });

  /// replyMode `'host'`: one piece of the reply to the `reply_request` event
  /// [id]; [done] ends it ([result] 0 ok, 1 refused, 3 error). Pieces for a
  /// request the brain cancelled (`reply_cancel`) are dropped.
  Future<void> localReplyText(int id, String text, {bool done, int result});

  /// Tear down the local brain and its audio unit.
  Future<void> localAudioStop();

  /// Inject a user turn as text (also barges any in-flight reply).
  Future<void> localPushText(String text);

  /// Gate the mic → brain forward. The local path has no server VAD, so this is
  /// the whole duplex gate.
  Future<void> localSetMuted(bool muted);

  /// Brain events for captions + status:
  /// `{"kind":"state","state":int}` (0 idle / 1 listening / 2 thinking /
  /// 3 speaking) or `{"kind":"bot"|"user","text":String}`.
  Stream<Map<dynamic, dynamic>> get converseEvents;

  // ── the platform taking the sound away ─────────────────────────────────────

  /// The platform took this host's sound away, or gave it back — see
  /// [BithumanAudioInterruption]. Only between [audioStart] and [audioStop].
  /// A host on a platform without interruptions (macOS) never emits.
  Stream<BithumanAudioInterruption> get audioInterruptions;

  // ── how much of the agent's voice has been heard ───────────────────────────

  /// Where playout stands on the audio handed to [playSpeakerPCM] since
  /// [audioStart] (see [BithumanPlayout]): reported as the voice is heard, at
  /// most ten times a second, at once when everything handed over has been heard,
  /// and after every [interrupt]. Captions follow it
  /// (`BithumanRealtimeSession.spokenTranscriptStream`). A host that cannot tell
  /// may never emit; the session then estimates from the handover.
  Stream<BithumanPlayout> get speechPlayout;

  // ── the engine refusing the model ──────────────────────────────────────────

  /// The engine refused to create from the model file it was given (see
  /// [BithumanModelRejected]). Terminal for this host: a
  /// `BithumanRealtimeSession` on it ends with `MODEL_REJECTED` on its
  /// errorStream, the same teardown as a paywall. A host that has already
  /// refused replays the refusal to every new listener; a host whose engine
  /// opened never emits.
  Stream<BithumanModelRejected> get modelRejections;
}

/// The on-device engine refused to create from the model file (`MODEL_REJECTED`).
///
/// - **Essence 2:** the avatar file was published before the engine's current
///   format (`be_essence2_create` -4 on Apple; the same refusal by its sentence on
///   Android, after the plugin fetched the file again once), or the engine could
///   not open it (-2).
/// - **Expression 2:** the engine refused the model's files at create (Android)
///   or its warm-up could not load them (Apple).
///
/// Download the avatar again (or update the app) — retrying the same file
/// cannot heal it. Thrown by `BithumanAvatar.load` when the refusal comes
/// while it runs; otherwise reported on [VoiceHost.modelRejections].
class BithumanModelRejected implements Exception {
  const BithumanModelRejected({required this.engine, this.nativeCode, required this.message});

  /// The error code, the same one a realtime session reports (`RealtimeSessionError.code`).
  static const String errorCode = 'MODEL_REJECTED';
  String get code => errorCode;

  /// `essence2` or `expression2`.
  final String engine;

  /// The engine's own number for the refusal (`be_essence2_create`'s return
  /// code; -4 = out-of-date avatar file), or null when the engine has none.
  final int? nativeCode;

  /// What refused, with the native code and the engine's own sentence.
  final String message;

  /// The native push / error details `{engine, nativeCode, message}`; null when it is not one.
  static BithumanModelRejected? fromMap(Map<dynamic, dynamic>? m) {
    final msg = m?['message'];
    if (msg is! String || msg.isEmpty) return null;
    final e = m?['engine'], c = m?['nativeCode'];
    return BithumanModelRejected(
      engine: e is String && e.isNotEmpty ? e : 'unknown',
      nativeCode: c is int ? c : null,
      message: msg,
    );
  }

  @override
  String toString() => '$errorCode: $message';
}

/// How much of the agent's audio has been heard, as the voice host reports it
/// (`speechPlayout`). Both counts are 24 kHz samples of the audio handed to the
/// host since its audio unit started ([VoiceHost.audioStart]):
///
/// - [fed]: every sample received, counted as it arrives;
/// - [played]: the position heard up to — everything before it was made audible
///   or discarded (a barge-in, a stop). Never above [fed], never backwards; both
///   restart at zero on the next [VoiceHost.audioStart].
class BithumanPlayout {
  const BithumanPlayout({required this.played, required this.fed});

  /// Samples heard (or discarded) so far.
  final int played;

  /// Samples handed to the host so far.
  final int fed;

  /// Everything handed over has been heard.
  bool get caughtUp => played >= fed;

  /// The native push `{played, fed}`; null when it is not one.
  static BithumanPlayout? fromMap(Map<dynamic, dynamic>? m) {
    final p = m?['played'], f = m?['fed'];
    if (p is! int || f is! int || p < 0 || f < 0) return null;
    return BithumanPlayout(played: p > f ? f : p, fed: f);
  }

  @override
  String toString() => 'BithumanPlayout(played: $played, fed: $fed)';
}

/// The platform took a voice session's sound away ([began]), or gave it back.
///
/// - **iOS:** an audio-session interruption: a phone call ringing or answered
///   (also from its banner, with the app still on screen), Siri, an alarm.
/// - **Android:** the session's audio focus lost for a while or for good: a
///   phone call rings or is answered, another app's call, an assistant. A
///   notification that only asks the session to duck is not one.
/// - **macOS:** never.
///
/// While the sound is taken the microphone hears nothing the session can use
/// and the speaker is not the session's, but a realtime session stays open
/// (and billed) until it is stopped. `BithumanRealtimeSession` therefore ends
/// itself on [began] by default (`endOnAudioInterruption`).
class BithumanAudioInterruption {
  const BithumanAudioInterruption({
    required this.began,
    required this.reason,
    this.shouldResume = false,
  });

  /// True: the sound was taken. False: it came back.
  final bool began;

  /// `call`: a phone or VoIP call rings or runs. `focus` (Android): another
  /// app took the audio. `system` (iOS): any other interruption.
  final String reason;

  /// On an end ([began] false): the platform says the app may resume.
  final bool shouldResume;

  /// A phone or VoIP call took the sound.
  bool get isCall => reason == 'call';

  /// The native push `{state: began|ended, reason, shouldResume}`; null when
  /// it is not one.
  static BithumanAudioInterruption? fromMap(Map<dynamic, dynamic>? m) {
    final state = m?['state'];
    if (state != 'began' && state != 'ended') return null;
    return BithumanAudioInterruption(
      began: state == 'began',
      reason: (m?['reason'] as String?) ?? 'system',
      shouldResume: m?['shouldResume'] == true,
    );
  }

  @override
  String toString() =>
      'BithumanAudioInterruption(${began ? 'began' : 'ended'}, $reason'
      '${began ? '' : ', shouldResume: $shouldResume'})';
}
