// LipsyncSink.swift — the ONE edge the native audio unit has on render.
//
// Canonical home: github.com/bithuman-product/homebrew-bithuman
// (packages/flutter-plugin/shared/Classes/Protocol — symlinked into
// ios/Classes/Protocol and macos/Classes/Protocol, so one edit reaches both).
//
// ★WHY THIS EXISTS. `RealtimeAudioIO` is the voice unit: one AVAudioEngine that
// owns the mic, the speaker and Apple's VP-IO echo canceller. It needs nothing
// from the avatar except somewhere to hand lipsync bytes and a per-frame release
// tick — twelve members. It nevertheless named the CONCRETE render class
// (`weak var avatarTextureForLipsync: AvatarTexture?`), which made "voice with
// no render" untypeable even though every one of those 22 references was already
// `?.`-guarded and `playSpeakerPCM24k` already carried a no-avatar branch. The
// dependency was in the TYPE, not in the behaviour.
//
// The member set below is not a design: it is the MEASURED surface — every
// member `RealtimeAudioIO` and `LocalConverseController` invoke on the render
// side, and no other. `AvatarTexture` conforms to it today with zero new code
// (see BithumanAvatarPlugin.swift); a second sink (a headless lipsync recorder,
// a test double, an Android-shaped bridge) conforms by writing these twelve.
//
// NIL IS A SUPPORTED STATE, not a degraded one: nil = a voice session with no
// avatar. `playSpeakerPCM24k` then takes its `else` branch and schedules the bot
// audio straight to the speaker, and `pushLipsync` does no work at all.
//
// This file is the RENDER→VOICE direction of the boundary. The engine side of
// the same line is Protocol/BithumanEngine.swift.
//
// Apache-2.0; (c) bitHuman.

import Foundation

/// Where the voice unit hands lipsync audio, and what it asks the render side
/// about pacing. Class-bound because `RealtimeAudioIO` holds it `weak` — the
/// sink outlives nothing and owns nothing here.
protocol LipsyncSink: AnyObject {

  // MARK: pacing policy (read)

  /// True while the render side wants the START of each utterance held until it
  /// publishes the utterance's first composited frame. Both shipped engines are
  /// frame-paced and return false; the held-start gate is kept for an engine
  /// with real head latency and no per-frame tick.
  var usesStartGate: Bool { get }

  /// Is the engine warm enough that frames will actually come? Read only on the
  /// `usesStartGate` path, to play UNGATED rather than hold to the bound while
  /// an engine is still loading.
  var startGateEngineReady: Bool { get }

  /// SPEECH lip-frames published so far. The start gate polls this for "the
  /// first frame of this utterance has landed".
  var speechFramesPublished: Int { get }

  /// Bot audio released per published SPEECH frame = 1/displayFps (expression-2
  /// 0.05 at 20 fps, essence-2 0.04 at 25 fps). A constant over-demands at the
  /// faster rate and the picture walks ahead of the sound.
  var audioReleaseSeconds: Double { get }

  // MARK: the per-frame A/V lock (read + write)

  /// Fired by the render side each time a SPEECH lip-frame is published, so the
  /// voice unit releases exactly that frame's slice of bot audio — A/V paired by
  /// construction. The voice unit INSTALLS this; the sink calls it.
  var onSpeechFramePublished: (() -> Void)? { get set }

  /// Asked by the render side BEFORE it publishes a speech frame: is this
  /// frame's audio ready? nil (no voice unit attached) means "do not gate".
  var canReleaseSpeechAudio: (() -> Bool)? { get set }

  /// Dev sync marker: the render side sets it on the frame it flashes white; the
  /// voice unit reads-and-clears it so the click lands in that frame's own slice.
  /// Debug builds only (DevLevers) — a release build never sets it.
  var markerOnNextRelease: Bool { get set }

  // MARK: the four things the voice unit tells the render side

  /// Hold/resume lipsync consumption WITHOUT dropping queued audio, so a paused
  /// bot turn resumes from the same point (the local semantic-barge hold).
  func setLipsyncPaused(_ paused: Bool)

  /// Barge-in: drop everything queued for lipsync and reset the runtime stream
  /// now, so a cut stops the mouth instantly.
  func clearAudioQueue()

  /// Stamped when speaker playback for an utterance starts.
  func noteUtteranceAudioStarted()

  /// 16 kHz mono PCM16 lipsync bytes, resampled from the 24 kHz bot stream.
  /// ★Mic bytes must never reach this.
  func enqueuePCM(_ data: Data)

  /// Brain turn-end (cloud `response.done` / local BOT_TURN_END): flush the
  /// final PARTIAL lipsync chunk so the last word is not clipped.
  func onTurnEnd()
}
