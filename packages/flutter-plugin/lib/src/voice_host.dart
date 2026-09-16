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
// stack conform by writing these fourteen.
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
  Future<void> localAudioStart({
    required String ggufPath,
    String? supertonicAssets,
    String? voice,
    int vadThreshold,
    String systemPrompt,
  });

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
}
