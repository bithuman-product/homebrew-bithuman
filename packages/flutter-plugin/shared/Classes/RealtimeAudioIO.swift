// RealtimeAudioIO — single AVAudioEngine with VP-IO that owns both mic
// capture and TTS playback. Direct port of the canonical AudioGraph used
// by `bithuman-cli avatar --openai` (bithuman-sdk/swift/.../AudioGraph.swift).
//
// SINGLE SHARED SOURCE for macOS + iOS — symlinked into macos/Classes/ and
// ios/Classes/ (like BithumanAvatarPlugin/LocalConverseController/…). The
// platform deltas are `#if os()`-guarded:
//   - iOS only: AVAudioSession (.playAndRecord/.voiceChat) configuration +
//     interruption handling (phone calls / Siri / route changes). macOS has
//     no AVAudioSession.
//   - BOTH platforms: the Elevate start-of-utterance speaker GATE (hold the
//     speaker until the texture publishes the utterance's first composited
//     frame) + its generation counter. macOS validated this single-engine
//     WS architecture first (user-blessed 2026-06); iOS now runs the SAME
//     path — one audio unit (ours), Apple AEC referencing our own playout,
//     WS transport carrying PCM both ways. (The earlier iOS failures came
//     from running TWO audio units: WebRTC's VP-IO plus a side-channel
//     engine → ducking + echo outside the AEC reference.)
//   - The opt-in energy-VAD barge uses a ~0.3 s sustain gate (+ gap tolerance)
//     on BOTH platforms (rejects coughs/clicks; the bare peak detector was
//     hair-trigger). LOCAL only — cloud paths use OpenAI server_vad.
//
// Why this exists: Flutter's `record` and `audioplayers` packages are
// independent CoreAudio clients with no shared APM, so:
//   - Speaker output leaks back into the mic (self-talk loop)
//   - The avatar's lipsync queue and the speaker's playback queue have
//     no shared clock, so video drifts ahead/behind audio
//
// Putting both into a single AVAudioEngine with `setVoiceProcessingEnabled`
// on BOTH the input and output node gives us Apple's VP-IO aggregate:
//   - Acoustic echo cancellation (no self-talk)
//   - Noise suppression + AGC for free
//   - A common reference clock for mic ↔ player ↔ lipsync
//
// Apache-2.0; (c) bitHuman.

import Foundation
import AVFoundation
import QuartzCore   // CACurrentMediaTime for the utterance-gate clock
import os           // os_unfair_lock for the cross-thread graph-mutation gate
#if os(iOS)
import Flutter
#elseif os(macOS)
import FlutterMacOS
import CoreAudio   // HAL default-device listeners for audio hot-swap (no AVAudioSession on macOS)
#endif

/// Verbose-audio logging gate. Honors the `BITHUMAN_DEBUG_AUDIO` env
/// var: set to "1" / "true" to surface per-chunk RMS, per-channel peak
/// diagnostics, mic event-channel traces, etc. Steady-state production
/// runs leave this off so logs only contain lifecycle + error lines —
/// mobile log pipes are slow + size-constrained.
private let kVerboseAudioLog: Bool = {
  let v = ProcessInfo.processInfo.environment["BITHUMAN_DEBUG_AUDIO"] ?? ""
  return v == "1" || v.lowercased() == "true"
}()

/// Barge-calibration logging gate (`BITHUMAN_DEBUG_BARGE=1`): logs the post-AEC
/// mic peak vs the effective (echo-margined) threshold and the bot-audible flag,
/// so the energy `vad_threshold` + `voicePeakThresholdDuringBot` can be tuned per device.
private let kDebugBarge: Bool = {
  let v = ProcessInfo.processInfo.environment["BITHUMAN_DEBUG_BARGE"] ?? ""
  return v == "1" || v.lowercased() == "true"
}()

@inline(__always)
private func vlog(_ msg: @autoclosure () -> String) {
  if kVerboseAudioLog { NSLog("%@", msg()) }
}

final class RealtimeAudioIO: NSObject, FlutterStreamHandler {
  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  // Mixer node between player and output. The player is connected at
  // the OpenAI native 24 kHz Int16 format; the mixer takes that input
  // and outputs at the VP-IO output's real bus format (48 kHz Float32).
  // The mixer's internal resampler maintains continuous state across
  // scheduled buffers, eliminating chunk-boundary clicks that a
  // per-chunk AVAudioConverter would introduce.
  private let mixer = AVAudioMixerNode()
  private var playerFormat: AVAudioFormat?

  // Resample target for the mic stream we hand back to Dart. OpenAI
  // Realtime wants 24 kHz mono PCM16; do the resample once in native
  // so Dart never sees 48 kHz Float32.
  private let micTarget = AVAudioFormat(
    commonFormat: .pcmFormatInt16,
    sampleRate: 24_000,
    channels: 1,
    interleaved: false)!

  // Resample target for the lipsync push. Engine wants 16 kHz int16.
  private let lipsyncTarget = AVAudioFormat(
    commonFormat: .pcmFormatInt16,
    sampleRate: 16_000,
    channels: 1,
    interleaved: false)!

  // Inbound TTS chunks from OpenAI are 24 kHz mono PCM16, but we
  // immediately convert to Float32 before scheduling — Int16 → Float32
  // is stateless and cheap, while AVAudioMixerNode reliably accepts
  // Float32 input. Routing Int16 through the mixer on macOS produces
  // a robotic "zzz" buzz because the mixer doesn't correctly type-pun
  // the channel data.
  private let serverTtsFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: 24_000,
    channels: 1,
    interleaved: false)!

  private var micConverter: AVAudioConverter?
  private var micConverterSrcFormat: AVAudioFormat?
  private let lipsyncConverter: AVAudioConverter
  private var started = false

  // Event channel sink — set when Dart subscribes.
  private var micEventSink: FlutterEventSink?

  // Forward each resampled chunk to the AvatarTexture so it lands in the
  // avatar's compose buffer at the same moment we hand it to the player.
  // The texture owns the runtime + audio queue; we just push bytes.
  weak var avatarTextureForLipsync: AvatarTexture?

  // A/V sync for the Elevate engine (macOS + iOS). Essence is frame-locked
  // (video produced in the same tick the audio is pushed → already aligned)
  // and schedules the speaker immediately. The Elevate director engine has a
  // real head latency (actor dispatch + first render, ~150-400 ms warm), so
  // the lipsync push runs IMMEDIATELY (it DRIVES video production) but the
  // SPEAKER is gated at the START of each utterance: chunks buffer until the
  // texture publishes the utterance's first composited frame (polled via
  // AvatarTexture.speechFramesPublished), then everything schedules and audio
  // + mouth begin together. Bounded by elevateGateMaxWaitSec so a stalled
  // engine can never mute the agent. Mid-utterance chunks schedule
  // immediately — the per-tick backlog pacing in composeTickElevate keeps the
  // video within ~120 ms after the gated start. This replaced the fixed
  // 0.95 s playback delay tuned for the old chunk=16 light-avatar pipeline
  // (with the director engine that constant ran audio AND video each ~0.5 s
  // late in different places — net "audio leads video" at utterance starts).
  // A generation counter lets barge() drop held chunks.
  private let speakerDelayQueue = DispatchQueue(label: "ai.bithuman.spk.delay")
  private var speakerGen = 0
  private let speakerGenLock = NSLock()
  private enum ElevateGate { case idle, holding, open }
  private var elevateGate: ElevateGate = .idle      // guarded by speakerGenLock
  private var gateHeldBuffers: [AVAudioPCMBuffer] = []
  private var gateUtteranceStart: CFTimeInterval = 0
  private var gateBaseFrames = 0
  private var lastBotChunkAt: CFTimeInterval = 0
  /// Bot-chunk arrival gap that closes an utterance (mirrors the texture's
  /// idleResetSecs, which segments the lipsync stream the same way).
  private static let elevateUtteranceGapSec: TimeInterval = 1.0
  /// Hard bound on the start-of-utterance hold. With the engine's CONTINUOUS
  /// TARGET CLOCK the utterance's first generated frame displays at slot
  /// i+K — K = ceil(headLatencyEMA/40 ms)+4, clamped to [40, 75] in the
  /// conservative (~1× feed) regime and [25, 75] in the fast-feed
  /// (head-partial) regime, i.e. up to 3.0 s + ~0.12 s queue latency after
  /// the first audio reaches the engine (typical slow K≈53 → ~2.2 s, fast
  /// K≈30-37 → ~1.2-1.5 s). The bound sits above the K clamp-high so it
  /// only trips when the engine is wedged, where audio-without-mouth beats
  /// silence. (While the engine is still WARMING the gate is skipped
  /// entirely — no frames will come.)
  private static let elevateGateMaxWaitSec: TimeInterval = 3.5
  private static let elevateGatePollSec: TimeInterval = 0.02

  // embody A/V lock: bot audio (24 kHz Float) buffered here and released exactly
  // 50 ms per published lip-frame (releaseEmbodyAudioFrame), so audio and video
  // are paired 1:1 by construction — no hold-then-flush gate, no cushion magic.
  private var embodyPaced: [Float] = []
  private let embodyPacedLock = NSLock()
  /// The texture this IO drives lipsync for (used to forward the brain turn-end).
  var lipsyncTexture: AvatarTexture? { avatarTextureForLipsync }

  // Graph-mutation gate. Set true ONLY while the macOS performDeviceSwap is
  // rebuilding the engine graph; read by every OFF-MAIN scheduleBuffer/play
  // (releaseEmbodyAudioFrame on renderQueue, the Elevate immediate-schedule +
  // gate flush, the barge player reset) so they NO-OP into a mid-rebuild graph
  // instead of raising an uncatchable NSException ("player started when in a
  // disconnected state" / "required condition is false"). os_unfair_lock:
  // uncontended sub-µs, never held across a syscall → safe on the render thread.
  // NOT #if os(macOS): releaseEmbodyAudioFrame is shared, the read must compile
  // everywhere (it's a constant-false no-op off macOS since nothing ever sets it).
  private var graphMutating = false
  private var graphGateLock = os_unfair_lock()
  @inline(__always) private func graphIsMutating() -> Bool {
    os_unfair_lock_lock(&graphGateLock)
    let m = graphMutating
    os_unfair_lock_unlock(&graphGateLock)
    return m
  }
  @inline(__always) private func setGraphMutating(_ v: Bool) {
    os_unfair_lock_lock(&graphGateLock)
    graphMutating = v
    os_unfair_lock_unlock(&graphGateLock)
  }
  /// Schedule + (re)start the player ATOMICALLY w.r.t. the swap flipping the
  /// graph-mutation flag. Closes the TOCTOU window where a render-thread caller
  /// reads graphIsMutating()==false, then the swap sets it true + disconnects the
  /// node, then the caller's player.play() raises "player started when in a
  /// disconnected state". Because setGraphMutating(true) takes the SAME lock, it
  /// cannot interleave between the check and the play here: while we hold the
  /// lock the swap is either entirely before player.pause() (graph whole) or
  /// blocked waiting to set the flag (so it hasn't disconnected yet — it sets the
  /// flag BEFORE the first graph touch). Returns false (no-op) if a swap owns the
  /// graph. os_unfair_lock is held only across two synchronous AVAudioPlayerNode
  /// calls that don't block on another queue → no priority inversion in practice.
  @inline(__always) private func scheduleAndPlayGuarded(_ buf: AVAudioPCMBuffer) -> Bool {
    os_unfair_lock_lock(&graphGateLock)
    defer { os_unfair_lock_unlock(&graphGateLock) }
    if graphMutating { return false }
    player.scheduleBuffer(buf, completionHandler: nil)
    if !player.isPlaying && !playbackPaused { player.play() }
    return true
  }
  /// Multi-buffer variant of scheduleAndPlayGuarded: schedule ALL buffers and
  /// start the player under a SINGLE lock acquisition so a device swap cannot
  /// interleave mid-flush (which would abort with "player started when in a
  /// disconnected state"). Returns false (no-op) if a swap owns the graph — the
  /// caller keeps holding the buffers and re-flushes once the graph is whole.
  @inline(__always) private func scheduleManyAndPlayGuarded(_ bufs: [AVAudioPCMBuffer]) -> Bool {
    os_unfair_lock_lock(&graphGateLock)
    defer { os_unfair_lock_unlock(&graphGateLock) }
    if graphMutating { return false }
    for b in bufs { player.scheduleBuffer(b, completionHandler: nil) }
    if !player.isPlaying && !playbackPaused { player.play() }
    return true
  }
  /// Barge reset (stop+reset+play) atomic vs a device swap. Same lock the swap
  /// takes → if a swap owns the graph this no-ops (the swap's own player.pause()
  /// already silenced it; embodyPaced was cleared by the caller; the player
  /// resumes clean post-swap). Prevents the not-atomic graphIsMutating()-then-
  /// player.stop() TOCTOU abort.
  @inline(__always) private func resetPlayerGuarded() {
    os_unfair_lock_lock(&graphGateLock)
    defer { os_unfair_lock_unlock(&graphGateLock) }
    if graphMutating { return }
    player.stop()
    player.reset()
    player.play()
  }

  // LOCAL mode hooks (nil in cloud mode). `onMicTap` receives each raw AEC'd
  // mic buffer so the local brain (Apple SpeechAnalyzer) can transcribe it
  // instead of shipping it to the OpenAI WebSocket. `onBarge` fires when the
  // energy VAD detects sustained speech, so the local brain cancels its turn
  // (hard cut, lossy) — this is the unified, energy-driven barge that replaced
  // the old ASR-word-count turn-over.
  var onMicTap: ((AVAudioPCMBuffer) -> Void)?
  var onBarge: (() -> Void)?
  // LOCAL-mode mic mute. When true the mic→brain (STT) forward (`onMicTap`) is
  // skipped so the user can mute themselves; the speaker + avatar paths are
  // untouched. Default false. Cloud mode doesn't set this (onMicTap is nil).
  var micMuted = false
  // Lossless PAUSE/RESUME edges, fired only when `lipsyncPauseControl` is true.
  // The current LOCAL path keeps lipsyncPauseControl = false (hard cut via
  // onBarge), so these are not installed — retained for a future opt-in
  // pause-instead-of-cut mode. Turn-over is energy-driven, not word-count.
  var onUserSpeechStart: (() -> Void)?
  var onUserSpeechEnd: (() -> Void)?
  // When true, playSpeakerPCM24k does NOT drop chunks while the user is active —
  // pause is lossless via pausePlayback() instead. The shipped LOCAL path leaves
  // this false (hard cut).
  var lipsyncPauseControl = false
  private var wasUserVoiceActive = false
  // True between pausePlayback() and resumePlayback(): incoming chunks still
  // SCHEDULE (buffer for lossless resume) but must NOT re-start the player.
  private var playbackPaused = false

  /// Pause the bot LOSSLESSLY: hold the speaker + the avatar lipsync queue.
  /// Audio keeps buffering, so resumePlayback() continues where it left off.
  func pausePlayback() {
    playbackPaused = true
    if started { _ = bh_tryRun { self.player.pause() } }   // pause can raise if a swap is rebuilding the graph
    avatarTextureForLipsync?.setLipsyncPaused(true)
    NSLog("[Barge] PAUSE (user speaking — bot held)")
  }

  /// Resume after a pausePlayback() (false-alarm interruption).
  func resumePlayback() {
    playbackPaused = false
    avatarTextureForLipsync?.setLipsyncPaused(false)
    if started { _ = bh_tryRun { self.player.play() } }   // play can raise if a swap is rebuilding the graph
    NSLog("[Barge] RESUME (false alarm — bot continues)")
  }

  override init() {
    self.lipsyncConverter = AVAudioConverter(from: serverTtsFormat, to: lipsyncTarget)!
    super.init()
  }

  // MARK: - FlutterStreamHandler (mic event channel)

  func onListen(withArguments arguments: Any?,
                eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    self.micEventSink = events
    vlog("[RealtimeAudioIO] mic event channel: Dart subscribed")
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    self.micEventSink = nil
    vlog("[RealtimeAudioIO] mic event channel: Dart cancelled")
    return nil
  }

  private var micChunkCount = 0
  private var spkChunkCount = 0

  // Local voice-activity detection — the LOCAL-mode barge trigger. Mic chunks
  // with post-AEC PCM16 peak above the effective threshold count as "user
  // talking", and a barge fires once that holds for `voiceSustainSecs`
  // continuously. This `vad_threshold`-driven energy barge REPLACED the old
  // ASR-word-count turn-over in LOCAL mode (onBarge cancels the brain turn). It
  // is NOT used on the cloud path: cloud barge is OpenAI server_vad (which
  // cancels the response at its source), so the cloud transports start the
  // engine with vadThreshold 0. The "still talking" window stays open for
  // voiceQuietTimeoutSecs after the last loud chunk; while open, bot audio is
  // dropped at playSpeakerPCM24k so the speaker/lipsync stay silent.
  private var lastVoiceActivityAt: Date?
  // Int16 peak (0..32767) the post-AEC mic must exceed to count as the user
  // talking. 0 = DISABLED (cloud paths pass 0 → rely on OpenAI server_vad). Set
  // via start(vadThreshold:) from DevConfig.defaultVadThreshold (ships > 0) for
  // LOCAL mode, where this is the barge trigger.
  private var voicePeakThreshold: Int32 = 0
  private let voiceQuietTimeoutSecs: TimeInterval = 0.5
  // ANTI-SELF-INTERRUPTION: while the bot is audible, the post-AEC mic peak must
  // clear this ABSOLUTE Int16 floor (not base×margin) to count as the user
  // barging in. Set from measurement: converged VP-IO AEC leaves the bot's own
  // voice at a post-AEC peak of only ~150–200, while a normal-volume interrupting
  // voice lands ~5000+. A 4000 floor sits far above the echo residual (no
  // self-barge) yet below normal speech, so conversational interruption registers
  // immediately. (The previous base×echoMargin = 2500×3 = 7500 floor was ~45× the
  // echo residual and silently ate normal-volume barge-ins — you had to shout.)
  private let voicePeakThresholdDuringBot: Int32 = 4000
  // Wall-clock until which the bot's TTS is still playing out; extended by each
  // chunk in playSpeakerPCM24k. The during-bot floor applies only while `botAudible`.
  private var botAudibleUntil = Date.distantPast
  private var botAudible: Bool { Date() < botAudibleUntil }

  #if os(iOS)
  // AEC WARM-UP SQUELCH + ECHO FLOOR (iOS only). Apple's VP-IO echo
  // canceller needs seconds of UNINTERRUPTED farend (our speaker audio) to
  // converge. On the iPhone speakerphone the unconverged echo is loud
  // enough to trip OpenAI's server_vad, which cancels the response —
  // truncating the farend exposure and re-arming the loop (observed on
  // iPhone 17 Pro: a ~50 s storm of ~1 s self-cancelled utterances at
  // session start, then clean once converged). Two-stage defense, both
  // active only WHILE THE SPEAKER IS LIVE (mic passthrough while the bot
  // is silent is untouched — there is no echo to mis-trigger on):
  //   1. WARM-UP (adaptive): mic chunks are SOFT-LIMITED to ambient level
  //      (kGateAmbientCap — never hard-zeroed: a stretch of digital zeros
  //      collapses the server VAD's adaptive noise floor, and the splice
  //      back to ordinary room tone then reads as a speech ONSET —
  //      observed on-device as speech_started firing right as playout
  //      ended, in a quiet room) until the post-AEC residual is OBSERVED
  //      quiet — peak < kAecConvergedPeak for kAecConvergedRunSecs of
  //      speaker-live time after at least kAecMinFarendSecs of farend
  //      (hard cap kAecMaxFarendSecs so a noisy room can't gate the mic
  //      forever). A fixed 8 s budget was tried first and the storm
  //      resumed the second it lapsed — exit on MEASURED convergence.
  //   2. SUSTAINED-BARGE GATE (post-warm-up): while the speaker is live,
  //      chunks are soft-limited UNLESS the post-AEC peak has sustained ≥
  //      voicePeakThresholdDuringBot (4000 — the LOCAL path's measured
  //      floor) for voiceSustainSecs within one run (sub-floor dips up to
  //      voiceGapToleranceSecs keep the run alive — the LOCAL energy
  //      barge's exact robustness recipe). Measured on-device: the
  //      converged residual is QUIET in steady state (< 1000) but spikes
  //      past a plain 4000 floor on loud onsets (speakerphone nonlinearity
  //      a linear canceller can't model) — impulsive spikes never sustain
  //      0.3 s, real interrupting speech easily does. Once sustained, the
  //      mic OPENS (everything passes, soft syllables included) and stays
  //      open while loud taps keep landing, so server_vad hears the real
  //      barge ~0.3 s after onset and cancels the turn; the barge then
  //      stops the speaker → gate disengages → full-duplex listening.
  // Cost: no barge-in during the first ~10 s of agent speech (the connect
  // greeting), and barge-ins during bot speech land ~0.3 s later and must
  // be at conversational volume — the same trade LOCAL mode already makes.
  // macOS never compiles this — its user-validated path needs no squelch.
  private static let kAecMinFarendSecs: TimeInterval = 5.0
  private static let kAecMaxFarendSecs: TimeInterval = 30.0
  private static let kAecConvergedPeak: Int32 = 1000
  private static let kAecConvergedRunSecs: TimeInterval = 2.0
  /// How long the mic stays open after the last loud tap of a sustained run.
  private static let kBargeOpenTailSecs: TimeInterval = 0.5
  /// Gated chunks are compressed to this peak (≈ quiet-room ambient, which
  /// measures ~100-250 on iPhone 17 Pro) instead of zeroed — see WARM-UP.
  private static let kGateAmbientCap: Int32 = 600
  /// Grace added to the speaker-live window. The playout clock is fed
  /// just-in-time by the Dart pacing governor (~180 ms lead); deep into a
  /// long response, arrival jitter can briefly lapse the clock while audio
  /// is STILL rendering, letting raw echo chunks slip to server_vad
  /// (observed: spurious barges clustering late in a long reply with the
  /// gate never opening). The grace also covers the room's reverb tail
  /// after playout genuinely ends.
  private static let kPlayoutGraceSecs: TimeInterval = 1.0
  /// Unconditional mic soft-limit for the first seconds after engine start:
  /// VP-IO's AGC ramps the mic gain from cold and server-side VAD
  /// initializes its noise floor — every on-device run showed 1-2 phantom
  /// speech_started events 1.5-4 s after the mic stream began, in a quiet
  /// room, before ANY audio had played. Riding out the transient at room
  /// tone kills that whole class.
  private static let kMicStartGraceSecs: TimeInterval = 3.0
  private var engineStartedAt = Date.distantPast
  /// Soft-limit `frames` samples so the chunk's (sampled) peak lands at
  /// kGateAmbientCap: ambient passes untouched, echo spikes compress to
  /// room tone, and the server-side VAD's noise floor never sees a splice.
  @inline(__always)
  private func softLimitChunk(_ p: UnsafeMutablePointer<Int16>,
                              frames: Int, peak: Int32) {
    guard peak > Self.kGateAmbientCap else { return }
    let scale = Float(Self.kGateAmbientCap) / Float(peak)
    for i in 0..<frames {
      p[i] = Int16(Float(p[i]) * scale)
    }
  }
  private var aecFarendSecs: TimeInterval = 0
  private var aecQuietRunSecs: TimeInterval = 0
  private var playoutActiveUntil = Date.distantPast
  private var aecWarmupMuteLogged = false
  private var aecWarmupDone = false
  // Sustained-barge run state (speaker-live chunks only).
  private var iosBargeRunStart: Date?
  private var iosBargeLastLoud: Date?
  private var iosMicOpenUntil = Date.distantPast
  /// Advance the "speaker is actually rendering" clock — called ONLY where
  /// chunks reach the player (immediate schedule or gate flush), never for
  /// gate-held chunks (held = silent = no farend for the AEC to learn from).
  @inline(__always)
  private func notePlayoutScheduled(_ seconds: TimeInterval) {
    playoutActiveUntil = max(playoutActiveUntil, Date()).addingTimeInterval(seconds)
  }
  #else
  @inline(__always)
  private func notePlayoutScheduled(_ seconds: TimeInterval) {}
  #endif
  // Sustain window — the robustness gate. The mic must stay above the
  // (echo-margined) threshold for this long within ONE run before we treat it
  // as the user talking. Until then NOTHING happens — not the bot-mute, not the
  // barge — so a brief transient (cough, click, "mm", a tap, a door) can't
  // interrupt. Real speech easily sustains past this. Raise for more
  // robustness, lower for a snappier cut.
  private let voiceSustainSecs: TimeInterval = 0.30
  // A run survives sub-threshold dips up to this long (the natural gaps between
  // syllables), so a normal sentence accumulates ONE continuous run instead of
  // resetting between words. Only a silence longer than this ends the run —
  // this is what stops the longer sustain window from MISSING real speech.
  private let voiceGapToleranceSecs: TimeInterval = 0.12
  #if os(macOS)
  // [barge] macOS CLOUD sustained-energy gate state: the mic the OpenAI server
  // VAD hears is soft-limited to ambient WHILE THE BOT IS AUDIBLE until the
  // post-AEC peak sustains ≥ voicePeakThresholdDuringBot for voiceSustainSecs —
  // so ambient noise / coughs / clicks can't trip an interruption; only ~0.3 s
  // of sustained, conversational-volume speech does.
  private var macBargeRunStart: Date?
  private var macBargeLastLoud: Date?
  private var macMicOpenUntil = Date.distantPast
  #endif
  // Start of the current loud run + the most recent loud tap. A loud tap more
  // than voiceGapToleranceSecs after the last one begins a fresh run.
  private var firstLoudAt: Date?
  private var lastLoudAt: Date?
  // True once we've fired a barge for the current run — prevents refiring on
  // every subsequent loud tap. Reset when a fresh run starts.
  private var bargedForCurrentRun: Bool = false

  private var isUserVoiceActive: Bool {
    guard let t = lastVoiceActivityAt else { return false }
    return Date().timeIntervalSince(t) < voiceQuietTimeoutSecs
  }

  // MARK: - Lifecycle

  /// One-time graph setup. Attaching a node twice on the same engine
  /// raises an NSException that crashes the process, so the attach +
  /// connect dance MUST happen exactly once per RealtimeAudioIO. Call
  /// this from `start()` and gate it with `graphConfigured`.
  private var graphConfigured = false
  private var micActive = false
  private func configureGraphIfNeeded(mic: Bool = true) throws {
    if graphConfigured { return }
    let output = engine.outputNode

    // VP-IO only when the mic is in use. A TEXT-only session (mic=false) is
    // speaker-only: we never touch engine.inputNode, so macOS never asks for
    // microphone permission.
    if mic {
      let input = engine.inputNode
      // VP on BOTH ends before connecting. Single-sided VP makes the two
      // IO ends run at mismatched sample rates and engine.start() fails
      // with kAudioUnitErr_FailedInitialization (-10875) on outputNode.
      // ⚠️macOS 26 regression: VP-IO transforms the 3-ch built-in mic into a
      // 9-ch bus of DIGITAL SILENCE (mic dead). BITHUMAN_NO_VPIO=1 disables VP-IO
      // → raw mic has signal (no AEC; use headphones to avoid echo).
      let noVPIO = ProcessInfo.processInfo.environment["BITHUMAN_NO_VPIO"] == "1"
      if noVPIO {
        NSLog("[RealtimeAudioIO] VP-IO DISABLED (BITHUMAN_NO_VPIO) — raw mic, no AEC")
      } else {
        try input.setVoiceProcessingEnabled(true)
        try output.setVoiceProcessingEnabled(true)
        // Let other apps' audio keep playing. VP-IO DUCKS (suppresses) non-voice
        // audio by default, so Music / video / system sounds go silent while the
        // app runs. Minimize that ducking so all sound passes through (macOS 14+ /
        // iOS 17+; older OSes keep the default ducking).
        if #available(macOS 14.0, iOS 17.0, *) {
          input.voiceProcessingOtherAudioDuckingConfiguration =
            AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
              enableAdvancedDucking: false, duckingLevel: .min)
        }
      }
    }

    // Player → Mixer → Output. The mixer is the resampler: player
    // delivers 24 kHz Float32 chunks, mixer hands the VP-IO output node
    // 48 kHz Float32 with continuous polyphase-filter state across
    // chunks. Connecting the player DIRECTLY to the output at 24 kHz
    // fails -10875 because VP-IO requires its input bus to match its
    // own output rate. The mixer is the canonical AVFoundation pattern
    // for bridging sample rates between nodes.
    // attach/connect raise an uncatchable NSException on duplicate attach or a
    // bad format. guardAV catches it and throws SwapNotReady out of this
    // `throws` function → start() fails cleanly (a reportable error), never an
    // abort(). This runs ONCE (graphConfigured gate) on a fresh engine, so a
    // raise here is genuinely fatal-to-start, not a transient swap race.
    let outBusFormat = output.inputFormat(forBus: 0)
    try guardAV("attach(player)")        { engine.attach(player) }
    try guardAV("attach(mixer)")         { engine.attach(mixer) }
    try guardAV("connect(player→mixer)") { engine.connect(player, to: mixer, format: serverTtsFormat) }
    try guardAV("connect(mixer→output)") { engine.connect(mixer, to: output, format: outBusFormat) }
    graphConfigured = true
  }

  #if os(iOS)
  /// Configure the shared AVAudioSession for full-duplex voice chat (iOS only;
  /// macOS has no AVAudioSession). The .voiceChat mode opts the session into
  /// Apple's VP-IO unit (matches what `setVoiceProcessingEnabled(true)` would
  /// request on the route). .defaultToSpeaker routes output to the loudspeaker
  /// instead of the earpiece; .allowBluetooth keeps AirPods/HFP routes.
  private func configureAudioSession() throws {
    let session = AVAudioSession.sharedInstance()
    let options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetooth]
    // .videoChat is the speaker-routed sibling of .voiceChat. Both keep VP-IO
    // echo cancellation active (Apple requires .voiceChat OR .videoChat for
    // AVAudioEngine voice processing), but .voiceChat is earpiece/telephony-
    // tuned and attenuated → "super low volume". The mode swap alone isn't
    // reliably loud, so the load-bearing fix is the explicit speaker override
    // below.
    try session.setCategory(.playAndRecord, mode: .videoChat, options: options)
    try session.setPreferredSampleRate(48_000)
    try session.setActive(true)
    // PRIMARY fix: .defaultToSpeaker is unreliable under VP-IO, so force the
    // loudspeaker route explicitly (no-op for Bluetooth/wired routes). This is
    // a route override only — it does NOT change the mode and does NOT disable
    // VP-IO, so AEC / barge-in stay intact (AEC comes from
    // setVoiceProcessingEnabled on the nodes, not the session mode).
    try session.overrideOutputAudioPort(.speaker)
    NSLog("[RealtimeAudioIO] session: category=%@ mode=%@ sr=%.0f out=%@",
          session.category.rawValue, session.mode.rawValue, session.sampleRate,
          session.currentRoute.outputs.map { $0.portType.rawValue }
            .joined(separator: ","))
  }

  // Strong refs on the notification observers so we can remove them in stop().
  private var interruptionObserver: NSObjectProtocol?
  private var routeChangeObserver: NSObjectProtocol?
  private var configChangeObserver: NSObjectProtocol?

  private func registerInterruptionHandler() {
    let nc = NotificationCenter.default
    interruptionObserver = nc.addObserver(
      forName: AVAudioSession.interruptionNotification,
      object: AVAudioSession.sharedInstance(),
      queue: .main
    ) { [weak self] note in
      guard let self = self,
            let info = note.userInfo,
            let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
      switch type {
      case .began:
        NSLog("[RealtimeAudioIO] AVAudioSession interruption BEGAN — pausing engine")
        if self.started, self.engine.isRunning {
          _ = bh_tryRun { self.engine.pause() }
          _ = bh_tryRun { self.player.pause() }
        }
      case .ended:
        let opts = (info[AVAudioSessionInterruptionOptionKey] as? UInt).map {
          AVAudioSession.InterruptionOptions(rawValue: $0)
        } ?? []
        if opts.contains(.shouldResume), self.started {
          do {
            try AVAudioSession.sharedInstance().setActive(true)
            try self.engine.start()
            _ = bh_tryRun { self.player.play() }
            NSLog("[RealtimeAudioIO] AVAudioSession interruption ENDED — resumed")
          } catch {
            NSLog("[RealtimeAudioIO] interruption resume failed: %@",
                  error.localizedDescription)
          }
        }
      @unknown default:
        break
      }
    }
    // Route changes (headphones unplugged, Bluetooth dropped) can land the
    // output on the EARPIECE (receiver) — barely audible for an avatar app.
    // Re-assert the loudspeaker whenever the route falls back there. Plug-IN
    // events keep the new route (headphones stay headphones).
    routeChangeObserver = nc.addObserver(
      forName: AVAudioSession.routeChangeNotification,
      object: AVAudioSession.sharedInstance(),
      queue: .main
    ) { [weak self] _ in
      guard let self = self, self.started else { return }
      let session = AVAudioSession.sharedInstance()
      let outs = session.currentRoute.outputs.map { $0.portType }
      NSLog("[RealtimeAudioIO] route change → %@",
            outs.map { $0.rawValue }.joined(separator: ","))
      if outs.contains(.builtInReceiver) {
        try? session.overrideOutputAudioPort(.speaker)
      }
    }
    // Output-route changes also tear the engine's render graph down and post
    // this notification; the engine stays STOPPED until restarted. Without
    // the restart, audio goes silent for the rest of the session after any
    // route flip (battle-tested on iPhone — feee578's one keeper).
    configChangeObserver = nc.addObserver(
      forName: .AVAudioEngineConfigurationChange,
      object: engine,
      queue: .main
    ) { [weak self] _ in
      guard let self = self, self.started, !self.engine.isRunning else { return }
      do {
        try self.engine.start()
        if !self.playbackPaused { _ = bh_tryRun { self.player.play() } }
        NSLog("[RealtimeAudioIO] engine restarted after configuration change (route)")
      } catch {
        NSLog("[RealtimeAudioIO] engine restart after config change failed: %@",
              error.localizedDescription)
      }
    }
  }

  private func unregisterInterruptionHandler() {
    if let obs = interruptionObserver {
      NotificationCenter.default.removeObserver(obs)
      interruptionObserver = nil
    }
    if let obs = routeChangeObserver {
      NotificationCenter.default.removeObserver(obs)
      routeChangeObserver = nil
    }
    if let obs = configChangeObserver {
      NotificationCenter.default.removeObserver(obs)
      configChangeObserver = nil
    }
  }
  #endif

  // ───────────────────────────────────────────────────────────── shared AV-exception guard
  // SHARED (NOT in the macOS #if): `guardAV` below is called from
  // configureAVAudioEngine's attach/connect (the graph-config that compiles on
  // BOTH iOS and macOS), so both `guardAV` and the `SwapNotReady` sentinel it
  // throws must live in shared class scope. They previously sat inside the
  // `#if os(macOS)` block → iOS failed to compile ("Cannot find 'guardAV' in
  // scope"). Moved out here (pre-existing iOS-path bug; the iOS target had never
  // been built before).
  //
  // Internal sentinel so a (re)validation throws a CATCHABLE Swift error (routed
  // into the bounded retry) instead of letting installTap/connect raise an
  // uncatchable Obj-C NSException.
  private struct SwapNotReady: Error {}

  /// Run an AVAudioEngine op that may RAISE an Obj-C NSException (installTap,
  /// connect, disconnectNodeInput, removeTap, attach, …). Swift do/catch cannot
  /// catch those — they abort() the process. `bh_tryRun` catches it in Obj-C; if
  /// one is raised we log and throw the CATCHABLE `SwapNotReady` so the caller
  /// routes it into the bounded reschedule instead of crashing. `op` is a
  /// logging label only (autoclosure → no string built on the success path).
  @inline(__always)
  private func guardAV(_ op: @autoclosure () -> String = "av-op",
                       _ body: () -> Void) throws {
    if let ex = bh_tryRun(body) {
      NSLog("[audio-swap] %@ raised %@: %@ — reschedule",
            op(), ex.name.rawValue, ex.reason ?? "<no reason>")
      throw SwapNotReady()
    }
  }

  // ───────────────────────────────────────────────────────────── macOS audio hot-swap
  // macOS has no AVAudioSession route notifications. AVAudioEngine binds the input tap
  // + mixer→output to whatever device is default at start() and never follows a change,
  // so connecting a Bluetooth headset mid-session silently kills the mic (stale tap) and
  // strands audio on the old device. We watch the Core Audio default input/output device
  // (authoritative) AND the engine's own configuration-change notification, coalesce them
  // on a serial queue (300 ms debounce), and rebuild the I/O for the NEW device.
  //
  // CRITICAL: this is NOT barge(). The count-based A/V lock (Nth published speech frame ↔
  // Nth 50 ms embodyPaced slice) is device-independent — so the rebuild touches ONLY the
  // input tap + the mixer→output connection + engine start/stop. It NEVER touches
  // embodyPaced / speakerGen / the Elevate gate / micMuted, and uses player.pause()/play()
  // (never reset()) so in-flight scheduled buffers — and the FIFO/frame pairing — survive.
  #if os(macOS)
  private var startedWithMic = false
  private let swapQueue = DispatchQueue(label: "ai.bithuman.audio.swap")
  private var configChangeObserverMac: NSObjectProtocol?
  private var halListenerBlock: AudioObjectPropertyListenerBlock?  // same ref for add + remove
  private var halInputListenerInstalled = false
  private var halOutputListenerInstalled = false
  private var swapPending = false        // debounce flag (swapQueue-confined)
  private var reconfigInFlight = false   // re-entrancy guard (swapQueue-confined)
  // Bounded retry when the new device's bus is still settling (0 ch / 0 Hz).
  private var swapFormatRetries = 0
  private static let swapFormatRetryMax = 40                 // 40 × 0.10 s = 4 s cap
  private static let swapFormatRetryDelay: TimeInterval = 0.10
  private var defaultInputAddr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultInputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
  private var defaultOutputAddr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)

  private func registerDeviceListenersMac() {
    // Engine-internal "render graph torn down" (route flip) → full rebuild.
    configChangeObserverMac = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
    ) { [weak self] _ in self?.scheduleDeviceSwap(reason: "engineConfigChange") }

    // Authoritative default input/output device changes (fire even when the engine
    // doesn't reconfigure on its own). Block listeners deliver onto swapQueue, so the
    // callback never runs on the Core Audio realtime thread.
    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      self?.scheduleDeviceSwap(reason: "defaultDeviceChange")
    }
    halListenerBlock = block
    let sys = AudioObjectID(kAudioObjectSystemObject)
    if AudioObjectAddPropertyListenerBlock(sys, &defaultInputAddr, swapQueue, block) == noErr {
      halInputListenerInstalled = true
    }
    if AudioObjectAddPropertyListenerBlock(sys, &defaultOutputAddr, swapQueue, block) == noErr {
      halOutputListenerInstalled = true
    }
  }

  private func unregisterDeviceListenersMac() {
    if let obs = configChangeObserverMac {
      NotificationCenter.default.removeObserver(obs)
      configChangeObserverMac = nil
    }
    let sys = AudioObjectID(kAudioObjectSystemObject)
    if let block = halListenerBlock {
      if halInputListenerInstalled {
        AudioObjectRemovePropertyListenerBlock(sys, &defaultInputAddr, swapQueue, block)
        halInputListenerInstalled = false
      }
      if halOutputListenerInstalled {
        AudioObjectRemovePropertyListenerBlock(sys, &defaultOutputAddr, swapQueue, block)
        halOutputListenerInstalled = false
      }
      halListenerBlock = nil
    }
    swapPending = false
  }

  // Coalesce a burst of notifications (device connect fires several) into ONE rebuild.
  private func scheduleDeviceSwap(reason: String) {
    swapQueue.async { [weak self] in
      guard let self = self, self.started, !self.swapPending else { return }
      self.swapPending = true
      self.swapQueue.asyncAfter(deadline: .now() + 0.30) { [weak self] in
        guard let self = self else { return }
        self.swapPending = false
        guard self.started else { return }   // no-op if stop() ran during the debounce
        self.performDeviceSwap(reason: reason)
      }
    }
  }

  @inline(__always) private func formatValid(_ f: AVAudioFormat?) -> Bool {
    guard let f = f else { return false }
    return f.channelCount > 0 && f.sampleRate > 0
  }

  // Rebuild the engine I/O for the current default device. Runs serialized on
  // swapQueue. CANNOT raise an uncaught NSException: every install/connect is
  // guarded by a valid-format precondition (else reschedule), removeTap is
  // unconditional + idempotent, and the render thread is gated out of the graph
  // for the duration via graphMutating.
  private func performDeviceSwap(reason: String) {
    dispatchPrecondition(condition: .onQueue(swapQueue))   // invariant: swapQueue only
    if reconfigInFlight { return }
    reconfigInFlight = true
    defer { reconfigInFlight = false }
    guard started else { return }   // stop() flips `started` on swapQueue → no race
    NSLog("[audio-swap] rebuilding (reason=%@)", reason)

    // Gate the render thread OUT of the graph for the WHOLE rebuild. The
    // off-main scheduleBuffer/play sites no-op while this is set; the embody
    // FIFO is NOT drained (count-based A/V lock preserved — frames resume, not
    // dropped). Set BEFORE the first graph touch (player.pause/engine.stop).
    setGraphMutating(true)
    defer { setGraphMutating(false) }

    let wasPlaying = player.isPlaying && !playbackPaused
    _ = bh_tryRun { self.player.pause() }   // NOT stop/reset — keep scheduled buffers + FIFO alignment; pause can raise on a torn graph

    // Unconditional, idempotent tap removal — removeTap on an empty bus is a
    // no-op. Doing it ALWAYS (not gated on micActive) kills the double-tap the
    // VP-IO-off retry would otherwise hit, and covers a stale micActive read.
    // removeTap + stop can ASSERT (raise) on a graph torn by the in-flight route
    // flip → guardAV converts to a thrown SwapNotReady; on raise we reschedule
    // (engine left consistent; the next pass re-runs this teardown idempotently).
    do {
      try guardAV("removeTap(pre-swap)") { engine.inputNode.removeTap(onBus: 0) }
      micActive = false
      micConverter = nil                 // self-rebuilds on the new tap's sample rate
      micConverterSrcFormat = nil
      try guardAV("engine.stop(pre-swap)") {
        engine.stop()                    // quiesce; nodes stay attached (no re-attach → no NSException)
      }
    } catch {
      swapFormatRetries += 1
      if swapFormatRetries <= Self.swapFormatRetryMax {
        NSLog("[audio-swap] teardown raised — retry %d/%d in %.0f ms",
              swapFormatRetries, Self.swapFormatRetryMax, Self.swapFormatRetryDelay * 1000)
        swapQueue.asyncAfter(deadline: .now() + Self.swapFormatRetryDelay) { [weak self] in
          self?.performDeviceSwap(reason: "retry-teardown")
        }
      } else {
        NSLog("[audio-swap] teardown never settled after %d tries — leaving engine quiesced",
              Self.swapFormatRetryMax)
        swapFormatRetries = 0
      }
      return   // defer restores graphMutating=false
    }

    // Validate the NEW device's bus formats BEFORE touching the graph. During a
    // Bluetooth↔built-in transition the bus transiently reports 0 ch / 0 Hz, and
    // installTap/connect on that raises "required condition is false". If either
    // side isn't ready, DON'T mutate — bounded reschedule (the HAL default-device
    // listener also re-fires once macOS picks a fallback). The engine is left
    // quiesced-but-consistent (player paused, no tap).
    let output = engine.outputNode
    let outReady = formatValid(output.inputFormat(forBus: 0))
    let inReady  = !startedWithMic || formatValid(engine.inputNode.outputFormat(forBus: 0))
    if !outReady || !inReady {
      swapFormatRetries += 1
      if swapFormatRetries <= Self.swapFormatRetryMax {
        NSLog("[audio-swap] device not ready (out=%@ in=%@) — retry %d/%d in %.0f ms",
              outReady ? "ok" : "0ch/0sr", inReady ? "ok" : "0ch/0sr",
              swapFormatRetries, Self.swapFormatRetryMax, Self.swapFormatRetryDelay * 1000)
        swapQueue.asyncAfter(deadline: .now() + Self.swapFormatRetryDelay) { [weak self] in
          self?.performDeviceSwap(reason: "retry-format")
        }
      } else {
        NSLog("[audio-swap] device never settled after %d tries — leaving engine quiesced",
              Self.swapFormatRetryMax)
        swapFormatRetries = 0
      }
      return   // defer restores graphMutating=false; render thread resumes (no-ops until the next swap lands a whole graph)
    }
    swapFormatRetries = 0

    // Bring the I/O back up against the NEW device. VP-IO is re-asserted on the
    // new endpoints; on failure we retry once with VP-IO off (raw mic, no AEC).
    // Formats are RE-validated immediately before each connect/install (the VP-IO
    // toggle can momentarily re-zero the bus) → throws SwapNotReady (catchable).
    func bringUp(vpio: Bool) throws {
      let output = engine.outputNode
      if startedWithMic && vpio {
        try engine.inputNode.setVoiceProcessingEnabled(true)   // Swift-throwing
        try output.setVoiceProcessingEnabled(true)
      }
      // Reconnect mixer→output at the new device's bus format (player→mixer stays 24 kHz).
      // disconnect + connect BOTH raise an uncatchable NSException on a torn /
      // zeroed bus → guardAV converts the raise to SwapNotReady (bounded retry).
      let newOut = output.inputFormat(forBus: 0)
      guard formatValid(newOut) else { throw SwapNotReady() }
      try guardAV("disconnectNodeInput(output)") {
        engine.disconnectNodeInput(output, bus: 0)
      }
      try guardAV("connect(mixer→output)") {
        // Explicit format here: the mixer's output side is the resampler
        // boundary and must be pinned to the device's input-bus rate; `nil`
        // would let AVAudioEngine pick the mixer's own format and mis-rate it.
        engine.connect(mixer, to: output, format: newOut)
      }
      if startedWithMic {
        let input = engine.inputNode
        try guardAV("removeTap(input)") {
          input.removeTap(onBus: 0)      // defensive: VP-IO toggle can re-create the node WITH a tap
        }
        // format:nil → installTap binds to the node's CURRENT hardware format
        // read ATOMICALLY inside the locked call. This removes the read/install
        // TOCTOU: there is no stale snapshot to mismatch when the BT↔Mac handoff
        // flips the bus mid-swap. If the bus is unacceptable, installTap RAISES →
        // guardAV → SwapNotReady → bounded reschedule (never abort()).
        // handleMicBuffer already rebuilds its converter per-buffer and the 9-ch
        // best-channel picker handles any channel count, so nil needs no
        // downstream change.
        try guardAV("installTap(input)") {
          input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in
            self?.handleMicBuffer(buf)
          }
        }
        micActive = true
      }
      engine.prepare()
      try engine.start()                 // Swift-throwing
    }

    let noVPIO = ProcessInfo.processInfo.environment["BITHUMAN_NO_VPIO"] == "1"
    do {
      try bringUp(vpio: !noVPIO)
    } catch {
      NSLog("[audio-swap] start failed (%@) — retrying with VP-IO off", error.localizedDescription)
      _ = bh_tryRun { self.engine.inputNode.removeTap(onBus: 0) }   // never re-raise (we're recovering)
      micActive = false
      do {
        try bringUp(vpio: false)
      } catch {
        // SwapNotReady (bus re-zeroed by the toggle), device vanished with no
        // replacement yet, or a real start failure. Bounded reschedule; engine
        // left quiesced + consistent (tap removed).
        NSLog("[audio-swap] rebuild failed (%@) — retrying in 0.5s", error.localizedDescription)
        _ = bh_tryRun { self.engine.inputNode.removeTap(onBus: 0) }
        micActive = false
        swapQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
          self?.performDeviceSwap(reason: "retry")
        }
        return
      }
    }

    playerFormat = player.outputFormat(forBus: 0)
    // Graph is freshly whole (bringUp + engine.start succeeded) and we're on
    // swapQueue with graphMutating still true, so no concurrent swap; still wrap
    // play() since a player edge case can raise.
    if wasPlaying { _ = bh_tryRun { self.player.play() } }   // resume only if it was playing (paused bot stays paused)
    NSLog("[audio-swap] recovered (mic=%@ out_sr=%.0f)",
          startedWithMic ? "on" : "off", playerFormat?.sampleRate ?? 0)
  }
  #endif

  func start(vadThreshold: Int32? = nil, mic: Bool = true) throws {
    if let th = vadThreshold, th > 0 { voicePeakThreshold = th }
    if started { return }
    #if os(iOS)
    if mic { try configureAudioSession() }
    #endif
    try configureGraphIfNeeded(mic: mic)

    if mic {
      let input = engine.inputNode
      // format:nil — atomic current-format bind (same TOCTOU fix as the swap
      // path). A cold start that races an active route change can't abort: the
      // raise is caught and rethrown as a normal Swift error out of start().
      if let ex = bh_tryRun({
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in
          self?.handleMicBuffer(buf)
        }
      }) {
        NSLog("[RealtimeAudioIO] start installTap raised %@: %@",
              ex.name.rawValue, ex.reason ?? "<no reason>")
        throw NSError(domain: "ai.bithuman.audio", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "installTap raised at start"])
      }
      micActive = true
    }

    engine.prepare()
    try engine.start()
    self.playerFormat = player.outputFormat(forBus: 0)
    player.play()
    #if os(iOS)
    started = true
    engineStartedAt = Date()
    registerInterruptionHandler()
    #elseif os(macOS)
    // ORDER: set startedWithMic, then `started`, THEN register listeners. The
    // HAL listeners (which call scheduleDeviceSwap → performDeviceSwap) can't
    // fire until after registration, by which point `started` and startedWithMic
    // are both set — so the first possible swap sees a coherent snapshot.
    startedWithMic = mic
    started = true
    registerDeviceListenersMac()
    #else
    started = true
    #endif
    NSLog("[RealtimeAudioIO] up: mic=%@ player sr=%.0f Hz",
          mic ? "on" : "off(text)", self.playerFormat?.sampleRate ?? 0)
  }

  func stop() {
    if !started { return }
    #if os(iOS)
    started = false
    unregisterInterruptionHandler()
    // player.stop / removeTap / engine.stop can raise on a route flip mid-teardown; absorb (shutting down).
    _ = bh_tryRun { self.player.stop() }
    if micActive { _ = bh_tryRun { self.engine.inputNode.removeTap(onBus: 0) }; micActive = false }
    _ = bh_tryRun { self.engine.stop() }
    // Reset converter caches but KEEP the engine graph wired so a
    // subsequent start() doesn't try to re-attach nodes (which would
    // throw NSException and crash the process).
    micConverter = nil
    micConverterSrcFormat = nil
    #elseif os(macOS)
    // Serialize the macOS engine teardown against any in-flight/queued
    // performDeviceSwap. `started` is flipped INSIDE swapQueue.sync, and both
    // performDeviceSwap and a queued swap run on the same SERIAL queue, so this
    // block executes strictly before-or-after a whole swap — never interleaved
    // (closes the swap-vs-stop double-tap / install-on-stopping-engine race).
    // unregisterDeviceListenersMac removes the HAL block listeners first; a swap
    // already dispatched onto swapQueue before removal will run, hit
    // `guard started` (now false), and bail.
    unregisterDeviceListenersMac()
    swapQueue.sync {
      started = false
      setGraphMutating(true)
      defer { setGraphMutating(false) }
      // player.stop / removeTap / engine.stop can raise on a route flip mid-teardown; absorb (shutting down).
      _ = bh_tryRun { self.player.stop() }
      _ = bh_tryRun { self.engine.inputNode.removeTap(onBus: 0) }   // unconditional / idempotent
      micActive = false
      _ = bh_tryRun { self.engine.stop() }
      micConverter = nil
      micConverterSrcFormat = nil
    }
    #endif
    #if os(iOS)
    // Release the audio session so other apps can use the mic.
    do {
      try AVAudioSession.sharedInstance().setActive(
        false, options: [.notifyOthersOnDeactivation])
    } catch {
      NSLog("[RealtimeAudioIO] session deactivate failed: %@",
            error.localizedDescription)
    }
    #endif
  }

  /// Cut the agent off mid-sentence. Fired the moment the user is detected
  /// talking (OpenAI speech_started, or the local ASR/VAD), well before the
  /// sentence finishes. Two things happen in lockstep:
  ///   1. Stop the speaker so buffered agent audio doesn't keep playing.
  ///      `player.stop()` halts FUTURE scheduled buffers but lets the CURRENT
  ///      one finish (~100 ms tail); `player.reset()` flushes the in-flight
  ///      render state so the speaker goes silent within ~10 ms.
  ///   2. Tell the avatar to stop lipsyncing the cancelled audio (clear the
  ///      audio queue → looping-idle path until the next bot chunk).
  func barge() {
    NSLog("[RealtimeAudioIO] barge: cancelling agent playback + lipsync")
    playbackPaused = false   // turn-over supersedes any pause
    // ORDER MATTERS (mirrors cloud: cancel the producer FIRST, then drop queued
    // audio). LOCAL mode: cancel the converse turn — interrupt() bumps the
    // session turnGen, which gen-fences the producer. Any onTTSChunk pulled after
    // this returns is stamped with the OLD turn and dropped by the consumer's gen
    // check, so it can NOT re-append to embodyPaced / the lipsync queue AFTER we
    // flush them just below. (No-op in cloud mode where onBarge is nil; the cloud
    // path already cancels the response at the server before calling barge.)
    onBarge?()
    // Invalidate the Elevate utterance gate: bump the generation (terminates
    // the poll chain), drop any chunks still held for the first frame, and
    // re-arm the gate so the agent's NEXT response is treated as a fresh
    // utterance.
    speakerGenLock.lock()
    speakerGen &+= 1
    gateHeldBuffers.removeAll()
    elevateGate = .idle
    speakerGenLock.unlock()
    // embody: drop the cancelled response's unreleased audio so it can't play
    // against the NEXT utterance's lip-frames (embody resets its frame stream
    // via the texture's clearAudioQueue, so no frames pull this stale audio).
    // Safe to clear AFTER onBarge: the gen fence above means no late chunk can
    // refill this between here and the next turn.
    embodyPacedLock.lock(); embodyPaced.removeAll(); embodyPacedLock.unlock()
    #if os(iOS)
    // player.reset() below silences the speaker instantly — pull the
    // AEC-warm-up playout clock back so the squelch never mutes the mic
    // against a speaker that is no longer rendering.
    playoutActiveUntil = Date()
    #endif
    if started {
      #if os(macOS)
      // If a device swap owns the graph right now, DON'T touch the player node —
      // the swap's player.pause() already silenced it and embodyPaced.removeAll()
      // above already dropped the cancelled audio; the player resumes clean when
      // the swap finishes. Touching it here would hit the mid-rebuild graph
      // (uncatchable "player started when in a disconnected state"). Done under
      // the graph lock so the check + stop/reset/play is ATOMIC vs the swap.
      resetPlayerGuarded()
      #else
      player.stop()
      player.reset()
      // Restart the player so the NEXT scheduleBuffer call (when the agent
      // resumes) actually plays — otherwise isPlaying stays false and new
      // buffers queue but never render.
      player.play()
      #endif
    }
    avatarTextureForLipsync?.setLipsyncPaused(false)  // clear any pause hold
    avatarTextureForLipsync?.clearAudioQueue()
  }

  // MARK: - Mic tap → resample → event channel

  /// Architectural invariant: this method is the ONLY path mic audio takes
  /// through the plugin, and it forwards bytes to two destinations:
  ///   1. `micEventSink` (Flutter EventChannel) — Dart forwards to the OpenAI
  ///      Realtime WebSocket as `input_audio_buffer.append`.
  ///   2. The local VAD trigger that calls `barge()` on sustained speech.
  ///
  /// Mic bytes MUST NEVER reach `avatarTextureForLipsync.enqueuePCM` — the
  /// bithuman runtime is fed ONLY by `playSpeakerPCM24k` (the bot's PCM). The
  /// avatar must lipsync the AGENT, never the USER.
  private func handleMicBuffer(_ buffer: AVAudioPCMBuffer) {
    // LOCAL mode: hand the raw AEC'd buffer to the on-device ASR. (SpeechPipeline
    // does its own ch0-extract + resample.) Cloud mode leaves this nil. When the
    // user has muted the mic, skip ONLY this brain forward — the speaker/avatar
    // and the rest of this method are untouched.
    if !micMuted { onMicTap?(buffer) }
    let src = buffer.format
    // Per-channel RMS for the first few diagnostic chunks — surfaces the
    // ch=9 multi-channel-input quirk (which channel actually has the user's
    // voice) seen on the macOS VP-IO input bus.
    if micChunkCount % 50 == 0 || micChunkCount == 0 {
      let n = Int(buffer.frameLength)
      let nch = Int(src.channelCount)
      var peaks = [Float](repeating: 0, count: nch)
      if let fchPtr = buffer.floatChannelData {
        for c in 0..<nch {
          let ch = fchPtr[c]
          var maxAbs: Float = 0
          for i in stride(from: 0, to: n, by: 8) {
            let a = ch[i] < 0 ? -ch[i] : ch[i]
            if a > maxAbs { maxAbs = a }
          }
          peaks[c] = maxAbs
        }
      }
      let peakStr = peaks.map { String(format: "%.4f", $0) }.joined(separator: ",")
      NSLog("[mic-raw] ch=%d sr=%d per-ch peak=[%@]", nch, Int(src.sampleRate), peakStr)
      // File probe: works for GUI/open-launched apps too (their NSLog/stdout
      // isn't captured). Read /tmp/embody_mic_peak.txt to see live mic signal.
      let maxCh = peaks.max() ?? 0
      try? "ch=\(nch) max=\(String(format: "%.4f", maxCh)) per=[\(peakStr)] #\(micChunkCount)"
        .write(toFile: "/tmp/embody_mic_peak.txt", atomically: true, encoding: .utf8)
    }
    // AVAudioConverter's automatic N→1 downmix produces silence when the
    // source has > 2 channels on macOS (observed: ch=9 from the VP-IO input
    // bus on M-series Macs even when the underlying device is the built-in
    // mic). Work around by manually extracting channel 0 into a mono
    // intermediate buffer FIRST, then converting 1→1 (sample-rate +
    // Float32→Int16) which the converter handles correctly.
    let monoSrcFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: src.sampleRate,
      channels: 1,
      interleaved: false)!
    guard let monoBuf = AVAudioPCMBuffer(pcmFormat: monoSrcFormat,
                                         frameCapacity: buffer.frameLength) else { return }
    monoBuf.frameLength = buffer.frameLength
    // VP-IO on M-series presents a multi-channel input bus (ch=9 observed) where
    // the LIVE mic is often NOT channel 0 — extracting ch0 yields digital silence
    // ("mic doesn't listen", peak=0). Pick the highest-energy channel this buffer
    // (during silence the real mic still carries a noise floor above a dead ch0,
    // so this locks onto the actual mic channel; during speech it's the voice).
    if let fchPtr = buffer.floatChannelData, let dst = monoBuf.floatChannelData?[0] {
      let nframes = Int(buffer.frameLength)
      let nch = Int(src.channelCount)
      var bestCh = 0
      if nch > 1 {
        var bestPeak: Float = -1
        for c in 0..<nch {
          let ch = fchPtr[c]; var m: Float = 0
          var i = 0
          while i < nframes { let a = ch[i] < 0 ? -ch[i] : ch[i]; if a > m { m = a }; i += 16 }
          if m > bestPeak { bestPeak = m; bestCh = c }
        }
      }
      dst.update(from: fchPtr[bestCh], count: nframes)
      if micChunkCount % 100 == 0 { NSLog("[mic-raw] using channel %d of %d", bestCh, nch) }
    }

    if micConverter == nil || micConverterSrcFormat?.sampleRate != monoSrcFormat.sampleRate {
      micConverter = AVAudioConverter(from: monoSrcFormat, to: micTarget)
      micConverterSrcFormat = monoSrcFormat
    }
    guard let conv = micConverter else { return }
    let ratio = micTarget.sampleRate / monoSrcFormat.sampleRate
    let outCap = AVAudioFrameCount(Double(monoBuf.frameLength) * ratio + 16)
    guard let out = AVAudioPCMBuffer(pcmFormat: micTarget, frameCapacity: outCap) else { return }
    var delivered = false
    var err: NSError?
    let status = conv.convert(to: out, error: &err) { _, statusOut in
      if delivered { statusOut.pointee = .noDataNow; return nil }
      delivered = true
      statusOut.pointee = .haveData
      return monoBuf
    }
    if status == .error || out.frameLength == 0 { return }
    guard let int16Ptr = out.int16ChannelData?[0] else { return }

    // Post-AEC peak of this chunk — measured BEFORE any iOS squelch zeroing
    // so the convergence detector below sees the TRUE residual. Also feeds
    // the LOCAL-mode energy barge further down.
    var maxAbs: Int32 = 0
    let frames = Int(out.frameLength)
    for i in stride(from: 0, to: frames, by: 8) {
      let a = int16Ptr[i] < 0 ? -Int32(int16Ptr[i]) : Int32(int16Ptr[i])
      if a > maxAbs { maxAbs = a }
    }

    #if os(iOS)
    // Mic-start grace: ride out the AGC ramp / VAD-init transient at room
    // tone (see kMicStartGraceSecs).
    if Date() < engineStartedAt.addingTimeInterval(Self.kMicStartGraceSecs) {
      softLimitChunk(int16Ptr, frames: frames, peak: maxAbs)
    } else
    // AEC warm-up squelch + sustained-barge gate (see the state block
    // above): while the speaker is live (graced for pacing jitter + reverb
    // tail), soft-limit anything the canceller hasn't provably removed so
    // echo can never reach server_vad (or the energy VAD).
    if Date() < playoutActiveUntil.addingTimeInterval(Self.kPlayoutGraceSecs) {
      let chunkSecs = Double(out.frameLength) / micTarget.sampleRate
      if !aecWarmupDone {
        aecFarendSecs += chunkSecs
        if maxAbs < Self.kAecConvergedPeak {
          aecQuietRunSecs += chunkSecs
        } else {
          aecQuietRunSecs = 0
        }
        if (aecFarendSecs >= Self.kAecMinFarendSecs
              && aecQuietRunSecs >= Self.kAecConvergedRunSecs)
            || aecFarendSecs >= Self.kAecMaxFarendSecs {
          aecWarmupDone = true
          NSLog("[RealtimeAudioIO] AEC warm-up complete (%.1f s farend, residual quiet %.1f s) — full duplex with echo floor",
                aecFarendSecs, aecQuietRunSecs)
        } else {
          if !aecWarmupMuteLogged {
            aecWarmupMuteLogged = true
            NSLog("[RealtimeAudioIO] AEC warm-up: limiting mic to ambient while speaker live (until residual < %d for %.0f s)",
                  Self.kAecConvergedPeak, Self.kAecConvergedRunSecs)
          }
          softLimitChunk(int16Ptr, frames: frames, peak: maxAbs)
        }
      }
      if aecWarmupDone {
        // Sustained-barge gate: open the mic only once the peak has stayed
        // ≥ the floor for voiceSustainSecs within one run (dips up to
        // voiceGapToleranceSecs keep the run alive). Impulsive echo spikes
        // never sustain; real interrupting speech does.
        let now = Date()
        if maxAbs >= voicePeakThresholdDuringBot {
          if iosBargeRunStart == nil ||
             (iosBargeLastLoud.map { now.timeIntervalSince($0) > voiceGapToleranceSecs } ?? true) {
            iosBargeRunStart = now
          }
          iosBargeLastLoud = now
          if now.timeIntervalSince(iosBargeRunStart!) >= voiceSustainSecs {
            if now >= iosMicOpenUntil {
              NSLog("[RealtimeAudioIO] sustained speech during bot audio (peak=%d) — mic open",
                    maxAbs)
            }
            iosMicOpenUntil = now.addingTimeInterval(Self.kBargeOpenTailSecs)
          }
        }
        if now >= iosMicOpenUntil {
          softLimitChunk(int16Ptr, frames: frames, peak: maxAbs)
        }
      }
    }
    #endif

    #if os(macOS)
    // [barge] macOS CLOUD (voicePeakThreshold == 0): require ~0.3 s of sustained,
    // conversational-volume speech before the OpenAI server VAD hears a barge.
    // While the bot is audible, soft-limit the mic to ambient until the post-AEC
    // peak stays ≥ voicePeakThresholdDuringBot for voiceSustainSecs within one
    // run (dips up to voiceGapToleranceSecs keep the run alive). Impulsive
    // ambient noise never sustains; real interruption does. macOS VP-IO AEC is
    // converged, so the bot's own residual (~150-200) stays below the 4000 floor.
    if voicePeakThreshold == 0 && botAudible {
      let now = Date()
      if maxAbs >= voicePeakThresholdDuringBot {
        if macBargeRunStart == nil ||
           (macBargeLastLoud.map { now.timeIntervalSince($0) > voiceGapToleranceSecs } ?? true) {
          macBargeRunStart = now
        }
        macBargeLastLoud = now
        if now.timeIntervalSince(macBargeRunStart!) >= voiceSustainSecs {
          if now >= macMicOpenUntil {
            NSLog("[RealtimeAudioIO] sustained speech during bot audio (peak=%d) — barge mic open", maxAbs)
          }
          macMicOpenUntil = now.addingTimeInterval(0.5)   // open tail after last loud tap
        }
      } else if let last = macBargeLastLoud,
                now.timeIntervalSince(last) > voiceGapToleranceSecs {
        macBargeRunStart = nil   // run lapsed into silence
      }
      if now >= macMicOpenUntil, maxAbs > 600 {
        // Not (yet) a sustained barge → compress to ambient so server VAD stays quiet.
        let scale = Float(600) / Float(maxAbs)
        for i in 0..<frames { int16Ptr[i] = Int16(Float(int16Ptr[i]) * scale) }
      }
    } else {
      macBargeRunStart = nil
      macBargeLastLoud = nil
    }
    #endif

    let n = Int(out.frameLength) * 2

    // The LOCAL-mode energy barge on the post-AEC mic signal (enabled whenever
    // voicePeakThreshold > 0 — cloud paths pass 0). The user counts as "talking"
    // — muting the bot AND firing the one-shot barge — ONLY after the peak has
    // stayed above the EFFECTIVE threshold for voiceSustainSecs within a single
    // run (sub-threshold dips up to voiceGapToleranceSecs don't break the run).
    // Until that sustain is met NOTHING happens, so a brief transient can't
    // interrupt. The effective threshold carries the echo margin while the bot
    // is audible so the bot can't barge itself on AEC residual. macOS + iOS.
    // (`maxAbs` is the post-AEC peak hoisted above, measured pre-squelch.)
    let effThreshold = botAudible ? voicePeakThresholdDuringBot : voicePeakThreshold
    if kDebugBarge && voicePeakThreshold > 0 && micChunkCount % 10 == 0 {
      NSLog("[barge-dbg] peak=%d eff=%d botAudible=%@ thr=%d",
            maxAbs, effThreshold, botAudible ? "Y" : "n", voicePeakThreshold)
    }
    if voicePeakThreshold > 0 && maxAbs > effThreshold {
      let now = Date()
      // Start a fresh run on the first loud tap, or when the gap since the last
      // loud tap exceeded the tolerance (the previous run lapsed into silence).
      // Brief inter-syllable dips stay within tolerance → one continuous run.
      if firstLoudAt == nil ||
         (lastLoudAt.map { now.timeIntervalSince($0) > voiceGapToleranceSecs } ?? true) {
        firstLoudAt = now
        bargedForCurrentRun = false
      }
      lastLoudAt = now
      if now.timeIntervalSince(firstLoudAt!) >= voiceSustainSecs {
        // Sustained → NOW mute the agent (lastVoiceActivityAt → the
        // playSpeakerPCM24k drop gate) and fire the one-shot barge. In LOCAL
        // mode onBarge cancels the brain turn + barge() flushes speaker+lipsync.
        lastVoiceActivityAt = now
        if !bargedForCurrentRun {
          bargedForCurrentRun = true
          NSLog("[RealtimeAudioIO] energy VAD: sustained speech (peak=%d eff=%d) → barge",
                maxAbs, effThreshold)
          // CRITICAL: NEVER touch AVAudioEngine/PlayerNode state from inside an
          // installed tap callback — the tap runs on the realtime audio thread
          // and AVAudioPlayerNode.stop() dispatch_syncs on that queue → "BUG IN
          // CLIENT OF LIBDISPATCH" SIGTRAP. Hop to the main queue.
          DispatchQueue.main.async { [weak self] in self?.barge() }
        }
      }
    }
    // No quiet-tap reset: the gap-tolerance restart above ends a run, and a
    // brief dip between syllables keeps it alive. The bot-mute (lastVoiceActivityAt)
    // decays on its own via voiceQuietTimeoutSecs.
    // LOCAL mode: debounced voice-activity edges (isUserVoiceActive carries the
    // ~0.5 s quiet timeout) drive lossless PAUSE on rising / RESUME on falling.
    if lipsyncPauseControl {
      let active = isUserVoiceActive
      if active != wasUserVoiceActive {
        wasUserVoiceActive = active
        let cb = active ? onUserSpeechStart : onUserSpeechEnd
        DispatchQueue.main.async { cb?() }
      }
    }

    let data = Data(bytes: int16Ptr, count: n)
    micChunkCount += 1
    let logThisChunk = micChunkCount == 1 || micChunkCount % 50 == 0
    if logThisChunk {
      // Quick RMS so we can tell silence from speech without leaving the
      // device. If this is always ~0 the mic isn't actually capturing —
      // either the OS is sending silence, or VP-IO is suppressing everything
      // as "echo".
      let frames = Int(out.frameLength)
      var sumSq: Double = 0
      var peak: Int16 = 0
      for i in stride(from: 0, to: frames, by: 8) {
        let s = int16Ptr[i]
        let absS = s < 0 ? -Int32(s) : Int32(s)
        if Int32(peak) < absS { peak = Int16(min(Int32(Int16.max), absS)) }
        let f = Double(s)
        sumSq += f * f
      }
      let rmsAvg = (sumSq / Double(max(1, frames/8))).squareRoot()
      vlog("[RealtimeAudioIO] mic chunk #\(micChunkCount) → Dart (\(n) bytes, peak=\(peak) rms=\(Int(rmsAvg)))")
    }
    if let sink = micEventSink {
      DispatchQueue.main.async { sink(FlutterStandardTypedData(bytes: data)) }
    } else if logThisChunk {
      NSLog("[RealtimeAudioIO] mic chunk #%d DROPPED: no Dart subscriber",
            micChunkCount)
    }
  }

  // MARK: - Speaker playback (24 kHz PCM16 → engine format) + lipsync push

  /// Schedule a chunk of OpenAI Realtime TTS audio for playback AND push the
  /// same chunk (resampled to 16 kHz) into the avatar's audio queue so the
  /// lipsync animates against the same bytes the speaker renders. Both calls
  /// happen synchronously here so the avatar's compose queue and the player's
  /// render queue drain from the same source at the same instant.
  func playSpeakerPCM24k(_ pcm: Data) {
    spkChunkCount += 1
    if spkChunkCount == 1 || spkChunkCount % 50 == 0 {
      vlog("[RealtimeAudioIO] bot chunk #\(spkChunkCount) (\(pcm.count) bytes from OpenAI)")
    }
    // Hard gate: if the local VAD heard the user within the last
    // voiceQuietTimeoutSecs, drop this bot chunk entirely (speaker silent +
    // lipsync gets no input) so the cancelled response can't keep playing
    // before OpenAI's server-VAD notifies us. CLOUD mode only: LOCAL mode keeps
    // buffering (lipsyncPauseControl) so a paused turn resumes losslessly.
    if isUserVoiceActive && !lipsyncPauseControl {
      return
    }
    // Track how long the bot stays audible so the VAD applies the echo margin
    // only while we're actually playing. Each chunk is pcm.count/2 samples at
    // 24 kHz; +50 ms covers the player's render latency.
    botAudibleUntil = max(botAudibleUntil, Date())
      .addingTimeInterval(Double(pcm.count / 2) / 24_000.0 + 0.05)
    let frameCount = AVAudioFrameCount(pcm.count / 2)
    guard frameCount > 0,
          let inBuf = AVAudioPCMBuffer(pcmFormat: serverTtsFormat, frameCapacity: frameCount)
    else { return }
    inBuf.frameLength = frameCount
    // Convert PCM16 → Float32 [-1, 1] inline. Stateless per-sample scale
    // (1/32768) — no chunk-boundary artifacts; the mixer downstream only does
    // the sample-rate change, which it handles with continuous state.
    if let dst = inBuf.floatChannelData?[0] {
      pcm.withUnsafeBytes { src in
        guard let base = src.baseAddress else { return }
        let i16 = base.assumingMemoryBound(to: Int16.self)
        let n = Int(frameCount)
        let scale: Float = 1.0 / 32768.0
        for i in 0..<n {
          dst[i] = Float(i16[i]) * scale
        }
      }
    }

    // 1. Speaker (macOS + iOS — one path).
    // Essence: schedule immediately (frame-locked → A/V aligned). Elevate:
    // gate the START of each utterance on the texture's first composited
    // frame (see the ElevateGate state block above); mid-utterance chunks
    // schedule immediately.
    // Hold the speaker at each utterance start until the avatar's first
    // composited frame lands, then release synced — for any engine with video
    // pipeline latency (elevate ~sub-s, embody ~1.6 s chunk). Essence is
    // frame-locked and stays ungated. This is THE fix for "audio leads video".
    // macOS device swap in progress: do NOT schedule into a half-wired graph.
    // For the immediate-schedule (Elevate / no-texture) engines, hold off on
    // this chunk — a single dropped chunk is recovered by the next one and is
    // far better than an uncatchable NSException. The embody branch below only
    // appends to the embodyPaced array (no player touch) and is gated separately
    // at release time, so it is allowed to fall through.
    #if os(macOS)
    if graphIsMutating(), (avatarTextureForLipsync?.usesStartGate ?? false) || avatarTextureForLipsync == nil {
      return
    }
    #endif
    let useGate = (avatarTextureForLipsync?.usesStartGate ?? false)
    if useGate {
      let now = CACurrentMediaTime()
      speakerGenLock.lock()
      let gen = speakerGen
      if elevateGate == .open, (now - lastBotChunkAt) >= Self.elevateUtteranceGapSec {
        elevateGate = .idle   // arrival gap = utterance boundary → re-gate
      }
      lastBotChunkAt = now
      switch elevateGate {
      case .open:
        speakerGenLock.unlock()
        notePlayoutScheduled(Double(frameCount) / serverTtsFormat.sampleRate)
        #if os(macOS)
        // Atomic vs a device swap: the entry gate at the top of this function is
        // NOT atomic with this play (a swap can begin between them and abort on a
        // disconnected node). scheduleAndPlayGuarded holds the same lock the swap
        // takes → refuse (drop one chunk, recovered by the next) instead of crash.
        _ = scheduleAndPlayGuarded(inBuf)
        #else
        player.scheduleBuffer(inBuf, completionHandler: nil)
        if !player.isPlaying && !playbackPaused { player.play() }  // don't undo a pause
        #endif
      case .holding:
        gateHeldBuffers.append(inBuf)
        speakerGenLock.unlock()
      case .idle:
        // Engine still warming → no frames will come; play immediately over
        // the idle loop instead of pointlessly holding to the bound.
        if avatarTextureForLipsync?.startGateEngineReady != true {
          elevateGate = .open
          speakerGenLock.unlock()
          NSLog("[av-gate] utterance start: engine warming — speaker plays ungated")
          notePlayoutScheduled(Double(frameCount) / serverTtsFormat.sampleRate)
          #if os(macOS)
          _ = scheduleAndPlayGuarded(inBuf)   // atomic vs device swap (see .open case)
          #else
          player.scheduleBuffer(inBuf, completionHandler: nil)
          if !player.isPlaying && !playbackPaused { player.play() }
          #endif
          break
        }
        elevateGate = .holding
        gateHeldBuffers = [inBuf]
        gateUtteranceStart = now
        gateBaseFrames = avatarTextureForLipsync?.speechFramesPublished ?? 0
        speakerGenLock.unlock()
        NSLog("[elevate-av] utterance start: holding speaker for first frame")
        pollElevateGate(gen: gen)
      }
    } else if avatarTextureForLipsync != nil {
      // embody: do NOT schedule now. Buffer the bot audio; it's released 50 ms
      // per published lip-frame by releaseEmbodyAudioFrame() so audio is paired
      // 1:1 with the mouth (principled A/V lock that absorbs the ~1.6 s pipeline
      // delay — replaces the hold-then-flush gate that caused the 1-2 s lag).
      // ALWAYS (re)point the hook at THIS session's release fn. On reconnect a
      // NEW RealtimeAudioIO is created; a stale closure capturing the old
      // (deallocated) one would silently stop releasing audio — the "no sound
      // after reconnect" bug.
      avatarTextureForLipsync?.onSpeechFramePublished = { [weak self] in self?.releaseEmbodyAudioFrame() }
      if let s = inBuf.floatChannelData?[0] {
        embodyPacedLock.lock()
        embodyPaced.append(contentsOf: UnsafeBufferPointer(start: s, count: Int(frameCount)))
        embodyPacedLock.unlock()
      }
    } else {
      notePlayoutScheduled(Double(frameCount) / serverTtsFormat.sampleRate)
      #if os(macOS)
      _ = scheduleAndPlayGuarded(inBuf)   // atomic vs device swap (cloud/no-avatar path)
      #else
      player.scheduleBuffer(inBuf, completionHandler: nil)
      if !player.isPlaying && !playbackPaused { player.play() }  // don't undo a pause
      #endif
    }

    // 2. Lipsync — resample 24 → 16 kHz and push to the avatar runtime.
    pushLipsync(from: inBuf, frameCount: frameCount)
  }

  /// Release ONE lip-frame's worth (50 ms @ 24 kHz) of buffered bot audio to the
  /// speaker. Called once per embody SPEECH frame published (onSpeechFramePublished)
  /// so audio and video advance together — A/V locked by construction. While the
  /// front of the buffer hasn't arrived yet (idle/padding frames) it no-ops, so
  /// the speaker stays silent for non-speech frames.
  func releaseEmbodyAudioFrame() {
    // If a macOS device swap is rebuilding the graph, DO NOT touch the player and
    // DO NOT drain the FIFO. The Nth-frame↔Nth-slice pairing is preserved: this
    // frame's 50 ms slice stays at the FIFO head and is released on the next call
    // once the graph is whole. (No-op, NOT a drop — the count-based A/V lock is
    // untouched.)
    #if os(macOS)
    if graphIsMutating() { return }
    #endif
    // Per-fps release quantum = 1/displayFps: embody 0.05 (20 fps), essence2 0.04
    // (25 fps). A constant 0.05 over-demands at 25 fps. Defaults to 0.05 if no texture.
    let secs = avatarTextureForLipsync?.audioReleaseSeconds ?? 0.05
    let need = Int(serverTtsFormat.sampleRate * secs)   // 1200 @ 24 kHz embody; 960 essence2
    embodyPacedLock.lock()
    guard embodyPaced.count >= need else { embodyPacedLock.unlock(); return }
    let chunk = Array(embodyPaced.prefix(need))
    embodyPaced.removeFirst(need)
    embodyPacedLock.unlock()
    guard let buf = AVAudioPCMBuffer(pcmFormat: serverTtsFormat, frameCapacity: AVAudioFrameCount(need)) else { return }
    buf.frameLength = AVAudioFrameCount(need)
    if let dst = buf.floatChannelData?[0] {
      chunk.withUnsafeBufferPointer { dst.update(from: $0.baseAddress!, count: need) }
    }
    notePlayoutScheduled(secs)   // match the actual released quantum (0.04 essence2 / 0.05 embody)
    #if os(macOS)
    // Atomic w.r.t. the swap (see scheduleAndPlayGuarded). If a swap began in the
    // tiny window since the top-of-function gate check, the schedule is refused —
    // PUT THE SLICE BACK at the FIFO head so the Nth-frame↔Nth-slice count lock is
    // preserved (no dropped slice), and it releases on the next call post-swap.
    if !scheduleAndPlayGuarded(buf) {
      embodyPacedLock.lock()
      embodyPaced.insert(contentsOf: chunk, at: 0)
      embodyPacedLock.unlock()
      return
    }
    #else
    player.scheduleBuffer(buf, completionHandler: nil)
    if !player.isPlaying && !playbackPaused { player.play() }
    #endif
    embodyRelN += 1
    if embodyRelN % 20 == 0 {
      embodyPacedLock.lock(); let bufN = embodyPaced.count; embodyPacedLock.unlock()
      NSLog("[embody-av] released %d audio frames (50ms each), buffer=%d samples", embodyRelN, bufN)
      // A/V probe: cumulative bot audio scheduled to the speaker + buffer depth on
      // a monotonic clock → correlate with /embody_gen.txt to localize the start-lag.
      appendAvProbe("t=\(String(format: "%.2f", ProcessInfo.processInfo.systemUptime)) rel_frames=\(embodyRelN) audio_s=\(String(format: "%.2f", Double(embodyRelN) * 0.05)) buf_samples=\(bufN)")
    }
  }
  private var embodyRelN = 0
  /// Append a diagnostic line to /embody_av.txt (survives an `open`-launched app).
  private func appendAvProbe(_ s: String) {
    let p = (ProcessInfo.processInfo.environment["EMBODY_DUMP_DIR"] ?? "/tmp") + "/embody_av.txt"
    guard let d = (s + "\n").data(using: .utf8) else { return }
    if let fh = FileHandle(forWritingAtPath: p) { fh.seekToEndOfFile(); fh.write(d); try? fh.close() }
    else { try? d.write(to: URL(fileURLWithPath: p)) }
  }

  /// Elevate start-of-utterance gate: poll the texture's speech-frame counter
  /// every 20 ms; once the utterance's FIRST frame is on the texture (or the
  /// bounded wait expires) flush the held chunks to the player in arrival
  /// order. Gate state is guarded by speakerGenLock; a barge() bumps the gen
  /// and clears the held buffers, which terminates this poll chain.
  private func pollElevateGate(gen: Int) {
    speakerDelayQueue.asyncAfter(deadline: .now() + Self.elevateGatePollSec) { [weak self] in
      guard let self else { return }
      self.speakerGenLock.lock()
      guard self.speakerGen == gen, self.elevateGate == .holding else {
        self.speakerGenLock.unlock()
        return
      }
      // macOS device swap rebuilding the graph: don't flush into a half-wired
      // graph. Keep holding (state + gen unchanged) and re-poll; the held
      // buffers flush once the graph is whole.
      #if os(macOS)
      if self.graphIsMutating() {
        self.speakerGenLock.unlock()
        self.pollElevateGate(gen: gen)
        return
      }
      #endif
      let frames = self.avatarTextureForLipsync?.speechFramesPublished ?? 0
      let waited = CACurrentMediaTime() - self.gateUtteranceStart
      let frameLanded = frames > self.gateBaseFrames
      if frameLanded || waited >= Self.elevateGateMaxWaitSec {
        let held = self.gateHeldBuffers
        let heldSecs = held.reduce(0.0) {
          $0 + Double($1.frameLength) / self.serverTtsFormat.sampleRate
        }
        #if os(macOS)
        // Atomic flush vs a device swap: the graphIsMutating() pre-check above is
        // NOT atomic with the schedule below. scheduleManyAndPlayGuarded takes the
        // SAME lock the swap takes — if a swap began in that window it refuses, and
        // we KEEP holding (state + gen unchanged) and re-poll instead of flushing
        // into a half-wired graph (which would abort). notePlayoutScheduled /
        // noteUtteranceAudioStarted run ONLY on a successful flush so the playout
        // clock isn't double-counted across a refused-then-retried attempt.
        if self.scheduleManyAndPlayGuarded(held) {
          self.gateHeldBuffers = []
          self.elevateGate = .open
          self.speakerGenLock.unlock()
          self.avatarTextureForLipsync?.noteUtteranceAudioStarted()
          self.notePlayoutScheduled(heldSecs)
          NSLog("[elevate-av] speaker START after %.0f ms (firstFrame=%@, held %d chunks)",
                waited * 1000, frameLanded ? "yes" : "TIMEOUT", held.count)
        } else {
          self.speakerGenLock.unlock()
          self.pollElevateGate(gen: gen)
        }
        #else
        self.gateHeldBuffers = []
        self.elevateGate = .open
        self.speakerGenLock.unlock()
        // Stamp the texture's speaker clock FIRST so frame pacing references
        // the true playback start, then flush the held chunks in order.
        self.avatarTextureForLipsync?.noteUtteranceAudioStarted()
        self.notePlayoutScheduled(heldSecs)
        for b in held { self.player.scheduleBuffer(b, completionHandler: nil) }
        if !self.player.isPlaying && !self.playbackPaused { self.player.play() }
        NSLog("[elevate-av] speaker START after %.0f ms (firstFrame=%@, held %d chunks)",
              waited * 1000, frameLanded ? "yes" : "TIMEOUT", held.count)
        #endif
      } else {
        self.speakerGenLock.unlock()
        self.pollElevateGate(gen: gen)
      }
    }
  }

  /// Lipsync push shared by both speaker paths: resample 24 → 16 kHz and
  /// hand the bytes to the avatar runtime.
  private func pushLipsync(from inBuf: AVAudioPCMBuffer, frameCount: AVAudioFrameCount) {
    let outCap = AVAudioFrameCount(Double(frameCount) * 16_000.0 / 24_000.0 + 16)
    if let outBuf = AVAudioPCMBuffer(pcmFormat: lipsyncTarget, frameCapacity: outCap) {
      var delivered = false
      var err: NSError?
      let status = lipsyncConverter.convert(to: outBuf, error: &err) { _, statusOut in
        if delivered { statusOut.pointee = .noDataNow; return nil }
        delivered = true
        statusOut.pointee = .haveData
        return inBuf
      }
      if status != .error,
         let i16Ptr = outBuf.int16ChannelData?[0] {
        let bytes = Int(outBuf.frameLength) * 2
        let pushData = Data(bytes: i16Ptr, count: bytes)
        avatarTextureForLipsync?.enqueuePCM(pushData)
      }
    }
  }
}
