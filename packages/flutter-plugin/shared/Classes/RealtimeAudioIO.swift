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
//   - The LOCAL duplex gate HOLDS the agent losslessly on an echo-aware floor,
//     then re-reads the mic with the far end silent and either CONFIRMS a cut or
//     RELEASES back into the same reply (`duplexTick`). LOCAL only — cloud paths
//     use OpenAI server_vad, which is faster and better informed there.
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
private let kVerboseAudioLog: Bool = DevLevers.debugAudio

/// Barge-calibration logging gate (`BITHUMAN_DEBUG_BARGE=1`): logs the post-AEC
/// mic peak, the quiet-mode threshold, the far end the canceller is removing and
/// the duplex phase, every 10th chunk — the per-packet view the 1 s `[bhmic]` line
/// cannot give. Debug builds only (DevLevers).
private let kDebugBarge: Bool = DevLevers.debugBarge

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

  // Forward each resampled chunk to the render side so it lands in the
  // avatar's compose buffer at the same moment we hand it to the player.
  // The sink owns the runtime + audio queue; we just push bytes.
  //
  // ★A PROTOCOL, NOT THE RENDER CLASS. This is the ONLY edge this audio unit
  // has on render. It is nil-legal: nil = a voice session with no avatar, and
  // playSpeakerPCM24k then schedules the bot audio straight to the speaker
  // (the `else` branch at the bottom of the speaker block). Every reference to
  // it below was already `?.`-guarded — what made "voice with no render"
  // untypeable was the concrete class in THIS declaration, nothing else.
  // Protocol/LipsyncSink.swift states the twelve members actually used.
  weak var lipsyncSink: LipsyncSink?

  // A/V sync for the Elevate engine (macOS + iOS). Essence is frame-locked
  // (video produced in the same tick the audio is pushed → already aligned)
  // and schedules the speaker immediately. The Elevate director engine has a
  // real head latency (actor dispatch + first render, ~150-400 ms warm), so
  // the lipsync push runs IMMEDIATELY (it DRIVES video production) but the
  // SPEAKER is gated at the START of each utterance: chunks buffer until the
  // texture publishes the utterance's first composited frame (polled via
  // LipsyncSink.speechFramesPublished), then everything schedules and audio
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
  // duplex gate CONFIRMS a person — after the agent has already been held and
  // the microphone re-read with the far end silent — so the local brain cancels
  // its turn. A hold on its own never reaches here: it is not a decision.
  var onMicTap: ((AVAudioPCMBuffer) -> Void)?
  var onBarge: (() -> Void)?
  // LOCAL-mode mic mute. When true the mic→brain (STT) forward (`onMicTap`) is
  // skipped so the user can mute themselves; the speaker + avatar paths are
  // untouched. Default false. Cloud mode doesn't set this (onMicTap is nil).
  var micMuted = false
  /// THE DUPLEX GATE IS ON — which is the same question as "is this LOCAL mode",
  /// and used to be a second flag a caller had to remember to set alongside the
  /// threshold. It says two things at once, and they are the same thing: this
  /// session has no server VAD so the energy gate is its barge, AND the agent can
  /// be HELD and resumed, so `playSpeakerPCM24k` must buffer a chunk that arrives
  /// during a hold instead of dropping it. Cloud passes 0 and gets neither: there
  /// the server has already cancelled the response and the chunks in flight are dead.
  private var duplexGateOn: Bool { voicePeakThreshold > 0 }
  // True between pausePlayback() and resumePlayback(): incoming chunks still
  // SCHEDULE (buffer for lossless resume) but must NOT re-start the player.
  private var playbackPaused = false

  /// Pause the bot LOSSLESSLY: hold the speaker + the avatar lipsync queue.
  /// Audio keeps buffering, so resumePlayback() continues where it left off.
  func pausePlayback() {
    playbackPaused = true
    if started { _ = bh_tryRun { self.player.pause() } }   // pause can raise if a swap is rebuilding the graph
    lipsyncSink?.setLipsyncPaused(true)
    NSLog("[Barge] PAUSE (user speaking — bot held)")
  }

  /// Resume after a pausePlayback() (false-alarm interruption).
  func resumePlayback() {
    playbackPaused = false
    lipsyncSink?.setLipsyncPaused(false)
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

  // ---- the conversation instrument (read by tools/conformance conversation_apple) ----
  // `bhmic`, once a second: the post-AEC capture (dbfs) and what actually left for the
  // transport after anything in this file touched it (sentDbfs) — their difference is
  // the plugin's own attenuation, which the contract says must be 0. `bhfar`, once a
  // second: the level of the agent's audio as scheduled to the speaker — the far end
  // the canceller has to remove. Both carry the host clock the transport's lines use.
  private var micSumSq = 0.0, micSentSumSq = 0.0, micN = 0, micPeak: Int32 = 0, micChunks1s = 0
  private var micLineAt = Date.distantPast
  private var farSumSq = 0.0, farN = 0, farPeak: Float = 0
  private var farLineAt = Date.distantPast
  // ---- the far end, at the resolution the barge decision needs ----
  // `[bhfar]` above is a 1 s line for a reader. The duplex gate needs the SAME
  // quantity per chunk, because "how loud is the thing the canceller has to
  // remove, right now" is what turns an absolute floor into an echo-aware one.
  // A tiny ring of (hostTime, peak) per scheduled chunk; `farRecentPeak()` takes
  // the max over a window wide enough to cover the player queue + the speaker's
  // output latency + the acoustic flight, so the gate never has to know the
  // alignment exactly — only an upper bound on what could be echoing right now.
  private let farRingCap = 64
  private var farRing: [(t: Date, peak: Float)] = []
  private let farRingLock = NSLock()
  /// Max far-end chunk peak scheduled within the last `secs` (Int16 units, 0…32767).
  /// 0 ⇒ nothing was scheduled in that window, so nothing can be echoing.
  private func farRecentPeak(_ secs: TimeInterval = 0.6) -> Int32 {
    let cutoff = Date().addingTimeInterval(-secs)
    farRingLock.lock(); defer { farRingLock.unlock() }
    var pk: Float = 0
    for e in farRing where e.t >= cutoff { if e.peak > pk { pk = e.peak } }
    return Int32(pk * 32768)
  }
  @inline(__always) private func noteFarEnd(_ p: UnsafePointer<Float>, _ n: Int) {
    var sq = 0.0; var pk = farPeak
    var chunkPk: Float = 0
    for i in 0..<n { let v = p[i]; let a = v < 0 ? -v : v; if a > pk { pk = a }; if a > chunkPk { chunkPk = a }; sq += Double(v * v) }
    farSumSq += sq; farN += n; farPeak = pk
    let now = Date()
    farRingLock.lock()
    farRing.append((now, chunkPk))
    if farRing.count > farRingCap { farRing.removeFirst(farRing.count - farRingCap) }
    farRingLock.unlock()
    if now.timeIntervalSince(farLineAt) >= 1.0 {
      let rms = (farSumSq / Double(max(1, farN))).squareRoot()
      NSLog("[bhfar] speechSamples=%d peak1s=%d rms1s=%d dbfs=%.1f hostMs=%lld",
            farN, Int(farPeak * 32768), Int(rms * 32768),
            20 * log10(max(rms, 1.0 / 32768.0)), Int64(now.timeIntervalSince1970 * 1000))
      farSumSq = 0; farN = 0; farPeak = 0; farLineAt = now
    }
  }
  // The AEC warm-up squelch that read this clock is gone (VP-IO carries echo now);
  // the schedule sites still call it, harmlessly. Kept as a no-op rather than edited
  // out of six call sites — one line, and the sites read clearly as "audio scheduled".
  @inline(__always) private func notePlayoutScheduled(_ seconds: TimeInterval) {}
  /// A cut: the reason travels with the line (server speech_started, the app's text
  /// turn, the LOCAL energy VAD, a stop) so a reader can tell a phantom from a person.
  private var bargeN = 0
  /// Moved by barge() when the FIFO is dropped; a slice released under an older epoch
  /// than the current one belonged to the cancelled reply (counted, see release).
  private var pacedEpoch = 0
  private var oldSlicesAfterCut = 0

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
  // ★ THE AGENT'S OWN VOICE IS THE CONFOUNDER. STOP GUESSING AT IT — REMOVE IT
  //   AND MEASURE AGAIN. (2026-09-16, homebrew-bithuman #61.)
  //
  // What stood here until now was a single absolute floor, 4000, applied to the
  // post-AEC mic peak while the bot was audible. LOCAL mode has no server VAD
  // behind it, so that floor was the ONLY thing that could interrupt the agent,
  // and the table below says it cannot do the job: the two distributions it has
  // to separate OVERLAP, and no value of the constant separates them.
  //
  // ★ THOSE TWO NUMBERS ARE MEDIANS, AND THE DISTRIBUTIONS OVERLAP (measured
  // 2026-09-16 on the iMac, from the two graded macOS conversation runs' own
  // `[bhmic] peak1s` seconds — 1 s buckets, the finest resolution the log carries.
  // A real barge-in is a `speech_started` with audible=true AND injecting=false, so
  // the harness's own injected cut-ins are not counted as human ones):
  //
  //   run    the agent's own residual, agent audible    real barge-ins, peak reached
  //          median   p90    p95    WORST second        within +2 s of the onset
  //   aecA      124    456   1002        4049           2059 … 8383          (n=5)
  //   aecB      202   3420   4440        6530           2795 … 8568         (n=11)
  //
  // Two ways this floor fails, in opposite directions:
  //
  //   SLOW/DEAF — within 2 s of the onset, the only window in which a cut is worth
  //   anything, 6 of those 16 real interruptions never reached 4000. Widen to 3 s and
  //   it is 2 of 16; to 5 s, 1 of 16. The voice does get there — it just takes
  //   seconds, which for a detector whose entire job is to be fast is the same as
  //   missing it. The server's VAD caught all 16.
  //
  //   DEAF TO ITSELF — the floor still sits BELOW the residual's own worst second in
  //   both runs (4049 and 6530), so it does not buy freedom from self-barge either.
  //
  // There is no value of this constant that separates the two: an absolute peak on
  // the post-AEC mic is not a statistic that tells the user's voice from the agent's
  // on this hardware. (aecB's room was not certified empty, so part of its tail may
  // be room sound; aecA's 4049 already crosses aecA's weakest barge-in at 2059.)
  //
  // ── WHAT REPLACED IT ──────────────────────────────────────────────────────────
  //
  // HOLD → (far end silent) → CONFIRM or RELEASE. Two stages, and the second one
  // does not need to tell the two voices apart at all, because by the time it runs
  // only one of them can still be there.
  //
  //   HOLD     cheap, fast, deliberately over-sensitive. `pausePlayback()` — the
  //            LOSSLESS hold that has been written and switched off in this file
  //            since the word-count days. Speaker and lipsync stop; the bot's
  //            audio keeps buffering, so nothing is lost and nothing is decided.
  //            This is the instant the person hears the agent stop, so THIS is
  //            what the interrupt latency measures.
  //   CONFIRM  the player is paused, so after the device buffer drains the far end
  //            is PHYSICALLY SILENT and the echo residual with it. Mic energy that
  //            is still there is a person, and it is graded against the SAME floor
  //            the gate uses when the agent was never talking — no echo margin, no
  //            device constant, nothing to tune. Sustained ⇒ `barge()`: the turn dies.
  //   RELEASE  otherwise `resumePlayback()`, and the turn continues from the sample
  //            it stopped on. A false alarm costs a ~0.2 s hiccup, not a turn.
  //
  // That is why a self-interruption is not a matter of picking a lucky constant
  // here: it takes speech-level mic energy WHILE NOTHING IS PLAYING, which is not
  // something the agent's own echo can produce.
  //
  // ── MEASURED, 2026-09-16, iMac M4 (echelon), macOS 26.6.2, essence-2, speaker 40 %,
  //    VP-IO on + AGC off (`[bhaec] vpioIn=1 vpioOut=1 agc=0`), gate attested on by
  //    `[bhduplex] GATE on thr=2500` ──
  //
  //   SELF-INTERRUPTION: 0 turn-killing cuts over 195 s of agent speech with the room
  //   quiet. "Quiet" is marked by the SERVER's VAD, a detector not under test, not by
  //   this gate: every one of the run's 6 holds and 4 cuts fell inside the single 30 s
  //   window in which the server independently reported speech 5 times, and one of
  //   those holds fired with the far end at ZERO — which echo cannot do. The control
  //   (main, same vehicle, different run) read 0 over 93 s, in a room that stayed
  //   quiet throughout, so the two runs are NOT a fair comparison of rooms and are not
  //   offered as one.
  //
  //   THE COMPARISON THAT IS FAIR runs both rules over the SAME measured seconds. Over
  //   the 195 quiet agent-audible seconds, exactly ONE second's residual crossed the
  //   shipped floor — peak 5546 against a far end of 20897, a ratio of 0.265. The
  //   shipped rule's only move there is to destroy the turn. This one's is a hold that
  //   costs ~0.3 s and resumes unless the energy survives the far end going away. The
  //   whole change is in that sentence.
  //
  //   WHAT IS NOT MEASURED YET: the interrupt latency from a CONTROLLED acoustic onset.
  //   The 6 holds above were real room sound, so the gate's threshold-crossing-to-
  //   silence reads 104-198 ms (1-2 mic chunks at this device's ~93 ms capture
  //   cadence), but the run carries no independent mark of when that sound began, and
  //   the room's own floor (p95 peak 767) sits close to the onset floor this file uses
  //   for `preMs`, so `preMs` there (302-1301 ms) is an over-estimate of the distance
  //   back to onset and must not be quoted as the interrupt time. That number needs a
  //   stimulus with a known emission instant. It is NOT 643 ms either way: that figure
  //   is the cloud path's and carries ~156 ms of back-dated `audio_start_ms`.
  //
  // WHAT THAT MEANS PER MODE. CLOUD ignores all of it — `voicePeakThreshold` is 0
  // there and `server_vad` + far_field noise reduction is the barge (see the ruling
  // at bithuman_realtime.dart's audioStart call), and #58/#60 measured that the
  // energy path is 153 ms SLOWER than server_vad, so cloud must not adopt this.
  // LOCAL mode has no server VAD; this is its whole duplex story.
  //
  /// HOLD floor while the bot is audible, as a FRACTION of the far end the canceller
  /// has to remove (`farRecentPeak()`), floored at the quiet-mode `voicePeakThreshold`.
  /// A ratio and not a level because the residual scales with what is playing, which
  /// an absolute number cannot know: over the two runs above the residual second's
  /// mic/far ratio reads p90 0.031 / p95 0.038 on the clean run (worst 0.30), while
  /// the real barge-in seconds read a 0.34 median. 0.25 sits ~7× over the clean run's
  /// p95 and under the barge-in median — and it only gates the LOSSLESS hold, so
  /// being wrong here costs a hiccup. The cut is decided later, with the far end off.
  private let holdEchoGuard: Float = 0.25
  /// Sustain for the HOLD. Shorter than `voiceSustainSecs` (0.30) because a false
  /// hold is now recoverable: the cost of being early is a pause that resumes.
  private let holdSustainSecs: TimeInterval = 0.10
  /// After `pausePlayback()`, how long before the mic is believed to be echo-free:
  /// the player stops rendering immediately, but samples already handed to the
  /// device still play out. Nothing is decided during this window.
  ///
  /// ★ THIS WINDOW IS NOT WHAT CARRIES THE GUARANTEE, and it is worth being exact
  /// about why, because on this hardware a mic chunk arrives only about every
  /// 93 ms — LONGER than the window, so most holds see no chunk inside it at all.
  /// What carries the guarantee is `confirmSustainSecs`: a CONFIRM needs a RUN of
  /// above-threshold chunks spanning that long, which at any chunk cadence means
  /// at least one chunk that BEGAN after the pause. A chunk that straddles the
  /// pause instant can still carry echo; the one after it cannot.
  private let confirmGuardSecs: TimeInterval = 0.08
  /// How long the confirm stage listens with the far end silent before giving up
  /// and releasing. Long enough for a syllable, short enough that a false hold is
  /// a hiccup: guard + window is the whole cost of being wrong.
  private let confirmWindowSecs: TimeInterval = 0.22
  /// Of that window, how much must be above the quiet floor to call it a person.
  private let confirmSustainSecs: TimeInterval = 0.08
  // Wall-clock until which the bot's TTS is still playing out; extended by each
  // chunk in playSpeakerPCM24k. The during-bot floor applies only while `botAudible`.
  private var botAudibleUntil = Date.distantPast
  private var botAudible: Bool { Date() < botAudibleUntil }

  // ★ THE MICROPHONE IS NEVER GATED WHILE THE AGENT TALKS (2026-09-16). This file
  // used to soft-limit the uplink to room level while the speaker was live: iOS a
  // 3 s mic-start grace + an AEC warm-up squelch (5-30 s of every session) + a
  // 0.3 s sustained-speech gate; macOS the same 0.3 s gate. Their own comment
  // stated the cost — "no barge-in during the first ~10 s of agent speech ...
  // barge-ins land ~0.3 s later and must be at conversational volume" — which is
  // half-duplex. Echo is VP-IO's job (voice processing on both nodes) plus the
  // server's far_field noise reduction. MEASURED on iPhone 15, 2026-09-16: VP-IO
  // cancels a -18 dBFS far end to a -70..-90 dBFS steady residual; only the onset
  // transient before it converges reaches ~-35 dBFS. The `bhmic` line carries the
  // captured and the sent level so the residual and the (now zero) attenuation are
  // on the record, and the echo arm counts every speech_started the residual causes.
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
  // macOS-only: the macOS cloud sustained-energy barge gate; iOS barges on the server VAD alone
  // Start of the current loud run + the most recent loud tap. A loud tap more
  // than voiceGapToleranceSecs after the last one begins a fresh run.
  private var firstLoudAt: Date?
  private var lastLoudAt: Date?
  // True once we've fired a barge for the current run — prevents refiring on
  // every subsequent loud tap. Reset when a fresh run starts.
  private var bargedForCurrentRun: Bool = false

  // ── the duplex hold/confirm state (LOCAL mode; off whenever voicePeakThreshold is 0) ──
  private enum DuplexPhase { case idle, holding }
  private var duplexPhase: DuplexPhase = .idle
  /// When `pausePlayback()` was called for the current hold.
  private var holdAt = Date.distantPast
  /// Start of the above-floor run INSIDE the confirm window, and the last tap in it.
  private var confirmFirstLoudAt: Date?
  private var confirmLastLoudAt: Date?
  /// Loudest mic peak seen since the hold began, and the loudest seen after the
  /// guard expired — the two numbers the `[bhduplex]` verdict line carries, so a
  /// reader can grade a RELEASE without re-running anything.
  private var holdPeakAll: Int32 = 0
  private var holdPeakAfterGuard: Int32 = 0
  private var holdFarAtTrigger: Int32 = 0
  private var duplexHoldN = 0
  /// Whether the far end really goes quiet when we pause — logged once per hold as
  /// `COLLAPSE`, which is the measurement `confirmGuardSecs` is set from.
  private var holdPeakInGuard: Int32 = 0
  /// How many mic chunks actually landed inside the drain window. Without it
  /// `inGuard=0` is ambiguous — on this hardware a chunk arrives about every
  /// 93 ms, which is LONGER than the window, so "0" usually means "no chunk
  /// was looked at", not "the microphone was silent". An instrument that cannot
  /// tell those apart reports its own blind spot as a measurement.
  private var holdChunksInGuard = 0

  // ★ THE CLOCK HAS TO START AT THE SOUND, NOT AT THE TRIGGER. A gate that times
  // itself from its own threshold crossing reports its sustain window back as its
  // latency and hides everything the ramp cost. This ring keeps the last ~2 s of
  // post-AEC mic peaks so a HOLD can say how long the sound had ALREADY been
  // arriving when it fired: `preMs` is measured back to the last chunk quiet enough
  // that nothing was going on (a quarter of the floor that ended up firing), which
  // is the acoustic onset as this microphone saw it. onset→silence is preMs+0 by
  // construction — the hold IS the silence — and onset→cut is preMs + heldMs.
  private let micRingCap = 128
  private var micRing: [(t: Date, peak: Int32)] = []
  /// Time from the last sub-`floor` mic chunk to `from`. nil ⇒ the ring never went
  /// that quiet, so the burst is older than the ring and the number would be a lie.
  private func micQuietRunBefore(_ from: Date, floor: Int32) -> TimeInterval? {
    var last: Date?
    for e in micRing where e.t <= from {
      if e.peak <= floor { last = e.t }
    }
    guard let l = last else { return nil }
    return from.timeIntervalSince(l)
  }

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
      let noVPIO = DevLevers.noVPIO
      if noVPIO {
        NSLog("[RealtimeAudioIO] VP-IO DISABLED (BITHUMAN_NO_VPIO) — raw mic, no AEC")
      } else {
        try input.setVoiceProcessingEnabled(true)
        try output.setVoiceProcessingEnabled(true)
        applyUplinkGain(input)
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
    // ★THE PLATFORM ASYMMETRY, MEASURED RATHER THAN ASSUMED. iOS has an AVAudioSession
    // with a real output latency; macOS has no session at all. Audio handed to the player
    // reaches the ear that much later, and nothing in this file has ever read the number —
    // so on iOS the picture can lead the sound by exactly this much, constantly, while
    // macOS shows no such error. Route matters enormously: Bluetooth is typically
    // hundreds of milliseconds where the built-in speaker is tens.
    let route = session.currentRoute.outputs.map { "\($0.portType.rawValue)" }.joined(separator: ",")
    NSLog("[av-latency] outputLatency=%.1f ms  inputLatency=%.1f ms  ioBuffer=%.1f ms  sr=%.0f  route=%@",
          session.outputLatency * 1000, session.inputLatency * 1000,
          session.ioBufferDuration * 1000, session.sampleRate, route.isEmpty ? "none" : route)
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
  // macOS-only: CoreAudio HAL device-swap state; iOS hot-swaps through AVAudioSession instead
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
        applyUplinkGain(engine.inputNode)
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

    let noVPIO = DevLevers.noVPIO
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
    // A swap can legitimately land with VP-IO OFF (the bringUp(vpio:) fallback above).
    // Re-attest so the log says which canceller the REST of this session ran with,
    // rather than leaving the start-time line standing for a graph that no longer matches.
    logAecAttestation(at: "swap")
  }
  #endif

  /// Uplink gain policy from the Dart echo table (`EchoProfile.current.vpioAgc`):
  /// false ⇒ VP-IO's automatic gain is OFF and the plugin sends what the canceller
  /// produced, unamplified. Why it is a per-DEVICE row and not a platform `#if`:
  /// VP-IO's AGC drives the capture toward a target level whenever nobody near is
  /// talking — and while the agent talks, what it finds to amplify is the echo the
  /// canceller left behind. The iMac's canceller leaves -46..-56 dBFS of that
  /// (server_vad 0.7 still read it as the user twice in 333 s); the iPhone's leaves
  /// -70..-90 and never needed this. The table carries those numbers; this only
  /// applies them. Default true = the OS default, untouched.
  private var vpioAgc = true

  /// Apply the row's gain policy to the input node. Called at graph bring-up AND on
  /// the device hot-swap path (a re-enabled VP-IO would otherwise come back with AGC).
  private func applyUplinkGain(_ input: AVAudioInputNode) {
    if !vpioAgc { input.isVoiceProcessingAGCEnabled = false }
  }

  /// ★THE AEC ATTESTATION. One line, emitted after the engine is RUNNING, carrying what
  /// the OS says is engaged — `isVoiceProcessingEnabled` / `isVoiceProcessingAGCEnabled`
  /// READ BACK off the nodes, never the value we asked for.
  ///
  /// Why a readback and not the call site: `setVoiceProcessingEnabled(true)` is called in
  /// exactly two places and both have a path that legitimately ends with VP-IO OFF — the
  /// `BITHUMAN_NO_VPIO` lever, and the device-swap `bringUp(vpio:)` fallback that retries
  /// with the canceller off after a failed start. After either, the session runs with no
  /// echo cancellation at all and every other line in the log looks identical. macOS has
  /// no AVAudioSession, so on that platform this line is the ONLY evidence the platform
  /// canceller is on: before it existed, the published macOS session log (2026-09-16,
  /// mac_run_e2p170macpub.log) contained ZERO lines about VP-IO, and no one could say
  /// whether the canceller or the raised server_vad threshold was carrying the load.
  ///
  /// `agc` is read back for the same reason: `isVoiceProcessingAGCEnabled` is a no-op
  /// while voice processing is off, so "AGC off" as a call site proves nothing either.
  ///
  /// Clause 11 of the conformance contract grades `native_aec` from this line.
  private func logAecAttestation(at where_: String) {
    guard micActive else {
      NSLog("[bhaec] vpioIn=0 vpioOut=0 agc=0 mic=off at=%@ platform=%@",
            where_, Self.platformName)
      return
    }
    let input = engine.inputNode
    let output = engine.outputNode
    var extra = ""
    #if os(iOS)
    let session = AVAudioSession.sharedInstance()
    extra = String(format: " category=%@ mode=%@ route=%@",
                   session.category.rawValue, session.mode.rawValue,
                   session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: "+"))
    #endif
    NSLog("[bhaec] vpioIn=%d vpioOut=%d agc=%d mic=on at=%@ platform=%@ inSr=%.0f outSr=%.0f inCh=%d%@",
          input.isVoiceProcessingEnabled ? 1 : 0,
          output.isVoiceProcessingEnabled ? 1 : 0,
          input.isVoiceProcessingAGCEnabled ? 1 : 0,
          where_, Self.platformName,
          input.outputFormat(forBus: 0).sampleRate,
          output.inputFormat(forBus: 0).sampleRate,
          Int(input.outputFormat(forBus: 0).channelCount),
          extra)
  }

  /// ★THE DUPLEX ATTESTATION, the twin of `[bhaec]`. One line saying whether this
  /// session can be interrupted at all and on what terms — read off the state the
  /// gate will actually use, not off the call site that was supposed to set it.
  ///
  /// Why it exists: on 2026-09-16 a measurement of this gate read ZERO holds over
  /// 390 s and looked like a clean result. The gate had never run — the transport
  /// in front of it passes `vadThreshold: 0` by ruling, so `voicePeakThreshold` was
  /// 0 and every branch below was dead. Nothing in the log said so. An absent
  /// detector and a silent one are the same log, and that is the estate's signature
  /// defect: the fix is a line that says which one you have.
  private func logDuplexAttestation() {
    guard voicePeakThreshold > 0 else {
      NSLog("[bhduplex] GATE off (vad_threshold=0) — this session cannot be interrupted "
            + "by the microphone; its barge, if any, comes from the transport")
      return
    }
    NSLog("[bhduplex] GATE on thr=%d holdEchoGuard=%.2f holdSustainMs=%.0f guardMs=%.0f "
          + "windowMs=%.0f confirmSustainMs=%.0f quietSustainMs=%.0f gapMs=%.0f",
          voicePeakThreshold, holdEchoGuard, holdSustainSecs * 1000,
          confirmGuardSecs * 1000, confirmWindowSecs * 1000, confirmSustainSecs * 1000,
          voiceSustainSecs * 1000, voiceGapToleranceSecs * 1000)
  }

  private static var platformName: String {
    #if os(iOS)
    return "ios"
    #elseif os(macOS)
    return "macos"
    #else
    return "?"
    #endif
  }

  func start(vadThreshold: Int32? = nil, mic: Bool = true, vpioAgc: Bool = true) throws {
    if let th = vadThreshold, th > 0 { voicePeakThreshold = th }
    self.vpioAgc = vpioAgc
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
    logAecAttestation(at: "start")
    logDuplexAttestation()
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
  func barge(reason: String = "app") {
    let t0 = Date()
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
    // ★ THE PICTURE FIRST, THEN THE SOUND (2026-09-16). clearAudioQueue() moves the
    // texture's barge epoch and resets the engine (its in-flight chunk is gen-fenced),
    // so no frame of the cancelled reply can be published after this line — a frame
    // pulled a moment before is fenced by the epoch read at the top of the display
    // tick. Only THEN is the unreleased audio dropped and the player flushed. The
    // reverse order let a frame publish against an already-empty FIFO in the window
    // between the two — the Apple form of Android's old 199-unit leak.
    lipsyncSink?.setLipsyncPaused(false)  // clear any pause hold
    lipsyncSink?.clearAudioQueue()
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
    embodyPacedLock.lock(); let pacedDropped = embodyPaced.count; embodyPaced.removeAll(); pacedEpoch &+= 1; embodyPacedLock.unlock()
    if started {
      // macOS-only: the HAL device-swap graph rebuild does not exist on iOS
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
    // The speaker is silent HERE (player.reset() flushed its render state), and the
    // texture was reset at the top of this function. `flushedInMs` is cut -> silence.
    bargeN += 1
    NSLog("[bhbarge] CUT %d reason=%@ hostMs=%lld flushedInMs=%.1f unreleasedSamples=%d oldSlicesAfterCut=%d",
          bargeN, reason, Int64(t0.timeIntervalSince1970 * 1000),
          Date().timeIntervalSince(t0) * 1000, pacedDropped, oldSlicesAfterCut)
  }

  // MARK: - The LOCAL-mode duplex gate

  /// One mic chunk through HOLD → CONFIRM / RELEASE. See the constants block for
  /// why it is shaped this way; the short version is that the only statistic that
  /// reliably tells the user's voice from the agent's is one taken while the agent
  /// is not playing, so the gate stops the agent FIRST (losslessly) and grades the
  /// microphone afterwards.
  ///
  /// Runs on the realtime audio thread. NEVER touch AVAudioEngine / AVAudioPlayerNode
  /// from here — `player.stop()` dispatch_syncs onto this queue and traps with "BUG IN
  /// CLIENT OF LIBDISPATCH". Every one of the three actions below hops to main.
  private func duplexTick(micPeak: Int32) {
    let now = Date()
    micRing.append((now, micPeak))
    if micRing.count > micRingCap { micRing.removeFirst(micRing.count - micRingCap) }
    switch duplexPhase {
    case .idle:
      // The floor: the quiet-mode threshold when nothing is playing, raised in
      // proportion to what IS playing while the agent talks.
      let far = botAudible ? farRecentPeak() : 0
      let floor = max(voicePeakThreshold, Int32(Float(far) * holdEchoGuard))
      guard micPeak > floor else {
        if let l = lastLoudAt, now.timeIntervalSince(l) > voiceGapToleranceSecs {
          firstLoudAt = nil
          bargedForCurrentRun = false
        }
        return
      }
      if firstLoudAt == nil ||
         (lastLoudAt.map { now.timeIntervalSince($0) > voiceGapToleranceSecs } ?? true) {
        firstLoudAt = now
        bargedForCurrentRun = false
      }
      lastLoudAt = now

      // NOTHING IS PLAYING. There is no second voice to rule out, so there is
      // nothing for a hold to learn: sustain and cut, exactly as before.
      if !botAudible {
        guard now.timeIntervalSince(firstLoudAt!) >= voiceSustainSecs,
              !bargedForCurrentRun else { return }
        bargedForCurrentRun = true
        lastVoiceActivityAt = now
        NSLog("[bhduplex] CUT reason=quiet peak=%d floor=%d hostMs=%lld",
              micPeak, floor, Int64(now.timeIntervalSince1970 * 1000))
        DispatchQueue.main.async { [weak self] in self?.barge(reason: "energy_vad") }
        return
      }

      // THE AGENT IS TALKING → HOLD. Lossless: the turn is not cancelled, the
      // audio is not dropped, and this is the instant the person hears it stop.
      guard now.timeIntervalSince(firstLoudAt!) >= holdSustainSecs else { return }
      duplexPhase = .holding
      holdAt = now
      holdFarAtTrigger = far
      holdPeakAll = micPeak
      holdPeakAfterGuard = 0
      holdPeakInGuard = 0
      holdChunksInGuard = 0
      confirmFirstLoudAt = nil
      confirmLastLoudAt = nil
      duplexHoldN += 1
      lastVoiceActivityAt = now
      let pre = micQuietRunBefore(now, floor: max(1, floor / 4))
      NSLog("[bhduplex] HOLD %d peak=%d floor=%d far=%d sustainMs=%.0f preMs=%@ hostMs=%lld",
            duplexHoldN, micPeak, floor, far,
            now.timeIntervalSince(firstLoudAt!) * 1000,
            pre.map { String(format: "%.0f", $0 * 1000) } ?? "over",
            Int64(now.timeIntervalSince1970 * 1000))
      DispatchQueue.main.async { [weak self] in self?.pausePlayback() }

    case .holding:
      if micPeak > holdPeakAll { holdPeakAll = micPeak }
      let since = now.timeIntervalSince(holdAt)

      // DRAIN. player.pause() stops rendering at once, but samples already handed
      // to the device still reach the speaker. Decide nothing here; just record the
      // loudest tap, which is what `COLLAPSE` reports and what sizes this window.
      if since < confirmGuardSecs {
        holdChunksInGuard += 1
        if micPeak > holdPeakInGuard { holdPeakInGuard = micPeak }
        return
      }
      if micPeak > holdPeakAfterGuard { holdPeakAfterGuard = micPeak }

      // CONFIRM. The far end is silent, so the echo residual is too, and the floor
      // is the plain quiet-mode threshold — no echo margin, no per-device constant.
      if micPeak > voicePeakThreshold {
        if confirmFirstLoudAt == nil ||
           (confirmLastLoudAt.map { now.timeIntervalSince($0) > voiceGapToleranceSecs } ?? true) {
          confirmFirstLoudAt = now
        }
        confirmLastLoudAt = now
        lastVoiceActivityAt = now
        if now.timeIntervalSince(confirmFirstLoudAt!) >= confirmSustainSecs {
          NSLog("[bhduplex] COLLAPSE %d inGuard=%d guardChunks=%d afterGuard=%d far=%d",
                duplexHoldN, holdPeakInGuard, holdChunksInGuard, holdPeakAfterGuard, holdFarAtTrigger)
          NSLog("[bhduplex] CONFIRM %d peak=%d thr=%d heldMs=%.0f hostMs=%lld",
                duplexHoldN, holdPeakAfterGuard, voicePeakThreshold,
                since * 1000, Int64(now.timeIntervalSince1970 * 1000))
          duplexPhase = .idle
          firstLoudAt = nil; lastLoudAt = nil; bargedForCurrentRun = true
          DispatchQueue.main.async { [weak self] in self?.barge(reason: "duplex_confirmed") }
          return
        }
      }

      // RELEASE. Whatever tripped the hold could not survive the far end going
      // away, so it was the far end. Resume from the sample we stopped on.
      if since >= confirmGuardSecs + confirmWindowSecs {
        NSLog("[bhduplex] COLLAPSE %d inGuard=%d guardChunks=%d afterGuard=%d far=%d",
              duplexHoldN, holdPeakInGuard, holdChunksInGuard, holdPeakAfterGuard, holdFarAtTrigger)
        NSLog("[bhduplex] RELEASE %d peak=%d thr=%d heldMs=%.0f hostMs=%lld",
              duplexHoldN, holdPeakAfterGuard, voicePeakThreshold,
              since * 1000, Int64(now.timeIntervalSince1970 * 1000))
        duplexPhase = .idle
        firstLoudAt = nil; lastLoudAt = nil; bargedForCurrentRun = false
        DispatchQueue.main.async { [weak self] in self?.resumePlayback() }
      }
    }
  }

  // MARK: - Mic tap → resample → event channel

  /// Architectural invariant: this method is the ONLY path mic audio takes
  /// through the plugin, and it forwards bytes to two destinations:
  ///   1. `micEventSink` (Flutter EventChannel) — Dart forwards to the OpenAI
  ///      Realtime WebSocket as `input_audio_buffer.append`.
  ///   2. The local VAD trigger that calls `barge()` on sustained speech.
  ///
  /// Mic bytes MUST NEVER reach `lipsyncSink.enqueuePCM` — the bithuman
  /// runtime is fed ONLY by `playSpeakerPCM24k` (the bot's PCM). The
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

    // Post-AEC peak of this chunk: the `bhmic` line and the LOCAL-mode energy barge.
    var maxAbs: Int32 = 0
    let frames = Int(out.frameLength)
    for i in stride(from: 0, to: frames, by: 8) {
      let a = int16Ptr[i] < 0 ? -Int32(int16Ptr[i]) : Int32(int16Ptr[i])
      if a > maxAbs { maxAbs = a }
    }
    var capturedSq = 0.0
    for i in 0..<frames { let v = Double(int16Ptr[i]); capturedSq += v * v }

    var sentSq = 0.0
    for i in 0..<frames { let v = Double(int16Ptr[i]); sentSq += v * v }
    micSumSq += capturedSq; micSentSumSq += sentSq; micN += frames; micChunks1s += 1
    if maxAbs > micPeak { micPeak = maxAbs }
    if Date().timeIntervalSince(micLineAt) >= 1.0 {
      let rms = (micSumSq / Double(max(1, micN))).squareRoot()
      let sent = (micSentSumSq / Double(max(1, micN))).squareRoot()
      NSLog("[bhmic] chunks=%d peak1s=%d rms1s=%d dbfs=%.1f sentDbfs=%.1f agentAudible=%@ hostMs=%lld",
            micChunks1s, micPeak, Int(rms), 20 * log10(max(rms, 1.0) / 32768.0),
            20 * log10(max(sent, 1.0) / 32768.0), botAudible ? "1" : "0",
            Int64(Date().timeIntervalSince1970 * 1000))
      micSumSq = 0; micSentSumSq = 0; micN = 0; micPeak = 0; micChunks1s = 0; micLineAt = Date()
    }

    let n = Int(out.frameLength) * 2

    // The LOCAL-mode duplex gate on the post-AEC mic signal (enabled whenever
    // voicePeakThreshold > 0 — cloud paths pass 0 and take none of it; their barge
    // is server_vad). `maxAbs` is the post-AEC peak hoisted above. macOS + iOS.
    if kDebugBarge && voicePeakThreshold > 0 && micChunkCount % 10 == 0 {
      NSLog("[barge-dbg] peak=%d thr=%d far=%d botAudible=%@ phase=%@",
            maxAbs, voicePeakThreshold, botAudible ? farRecentPeak() : 0,
            botAudible ? "Y" : "n", duplexPhase == .holding ? "hold" : "idle")
    }
    if voicePeakThreshold > 0 { duplexTick(micPeak: maxAbs) }

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
    // before OpenAI's server-VAD notifies us. CLOUD ONLY — when the duplex gate is
    // on, a chunk arriving during a HOLD is part of a reply that may still be
    // resumed, so it must BUFFER into the paused player, never be thrown away.
    if isUserVoiceActive && !duplexGateOn {
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
    // macOS-only: guards the HAL device-swap graph rebuild, which cannot happen on iOS
    #if os(macOS)
    if graphIsMutating(), (lipsyncSink?.usesStartGate ?? false) || lipsyncSink == nil {
      return
    }
    #endif
    let useGate = (lipsyncSink?.usesStartGate ?? false)
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
        if let f = inBuf.floatChannelData?[0] { noteFarEnd(f, Int(frameCount)) }
        // macOS-only: device-swap-safe scheduling; iOS has no HAL swap so it schedules directly
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
        if lipsyncSink?.startGateEngineReady != true {
          elevateGate = .open
          speakerGenLock.unlock()
          NSLog("[av-gate] utterance start: engine warming — speaker plays ungated")
          notePlayoutScheduled(Double(frameCount) / serverTtsFormat.sampleRate)
          // macOS-only: device-swap-safe scheduling; iOS has no HAL swap so it schedules directly
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
        gateBaseFrames = lipsyncSink?.speechFramesPublished ?? 0
        speakerGenLock.unlock()
        NSLog("[elevate-av] utterance start: holding speaker for first frame")
        pollElevateGate(gen: gen)
      }
    } else if lipsyncSink != nil {
      // embody: do NOT schedule now. Buffer the bot audio; it's released 50 ms
      // per published lip-frame by releaseEmbodyAudioFrame() so audio is paired
      // 1:1 with the mouth (principled A/V lock that absorbs the ~1.6 s pipeline
      // delay — replaces the hold-then-flush gate that caused the 1-2 s lag).
      // ALWAYS (re)point the hook at THIS session's release fn. On reconnect a
      // NEW RealtimeAudioIO is created; a stale closure capturing the old
      // (deallocated) one would silently stop releasing audio — the "no sound
      // after reconnect" bug.
      lipsyncSink?.onSpeechFramePublished = { [weak self] in self?.releaseEmbodyAudioFrame() }
      lipsyncSink?.canReleaseSpeechAudio = { [weak self] in self?.canReleaseEmbodyAudioFrame() ?? true }
      if let s = inBuf.floatChannelData?[0] {
        embodyPacedLock.lock()
        embodyPaced.append(contentsOf: UnsafeBufferPointer(start: s, count: Int(frameCount)))
        embodyPacedLock.unlock()
      }
    } else {
      notePlayoutScheduled(Double(frameCount) / serverTtsFormat.sampleRate)
      if let f = inBuf.floatChannelData?[0] { noteFarEnd(f, Int(frameCount)) }
      // macOS-only: device-swap-safe scheduling; iOS has no HAL swap so it schedules directly
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
  /// Can this frame's audio slice be released RIGHT NOW? Asked by the presenter BEFORE
  /// it publishes a speech frame, because the two must advance together or not at all.
  ///
  /// ★Why this exists. releaseEmbodyAudioFrame() returns early when the FIFO is short —
  /// the picture has already been published by then, the slice is not released, and
  /// nothing repays it: the next call takes the NEXT slice, not the skipped one. So each
  /// short-FIFO moment advanced the picture by one frame while the sound stood still, and
  /// the gap never closed. The comment above claimed the pairing was "locked by
  /// construction"; it held only while the FIFO was never short, and said nothing about
  /// the case where it is.
  func canReleaseEmbodyAudioFrame() -> Bool {
    let secs = lipsyncSink?.audioReleaseSeconds ?? 0.05
    let need = Int(serverTtsFormat.sampleRate * secs)
    embodyPacedLock.lock(); let have = embodyPaced.count; embodyPacedLock.unlock()
    return have >= need
  }

  func releaseEmbodyAudioFrame() {
    // If a macOS device swap is rebuilding the graph, DO NOT touch the player and
    // DO NOT drain the FIFO. The Nth-frame↔Nth-slice pairing is preserved: this
    // frame's 50 ms slice stays at the FIFO head and is released on the next call
    // once the graph is whole. (No-op, NOT a drop — the count-based A/V lock is
    // untouched.)
    // macOS-only: guards the HAL device-swap graph rebuild, which cannot happen on iOS
    #if os(macOS)
    if graphIsMutating() { return }
    #endif
    // Per-fps release quantum = 1/displayFps: embody 0.05 (20 fps), essence2 0.04
    // (25 fps). A constant 0.05 over-demands at 25 fps. Defaults to 0.05 if no sink.
    let secs = lipsyncSink?.audioReleaseSeconds ?? 0.05
    let need = Int(serverTtsFormat.sampleRate * secs)   // 1200 @ 24 kHz embody; 960 essence2
    embodyPacedLock.lock()
    guard embodyPaced.count >= need else {
      let have = embodyPaced.count
      embodyPacedLock.unlock()
      // ★THE DEBT. The picture for this frame is already on the texture; its 50 ms of
      // sound is not, and nothing here repays it — the next call takes the NEXT slice.
      // Counted and named so it can never again be inferred from a customer's
      // description of the symptom.
      embodySkippedSlices += 1
      NSLog("[embody-av] SKIPPED this frame's audio slice (have %d of %d samples) — total skipped=%d = %.2f s the picture is ahead",
            have, need, embodySkippedSlices, Double(embodySkippedSlices) * secs)
      return
    }
    let chunk = Array(embodyPaced.prefix(need))
    embodyPaced.removeFirst(need)
    let epochAtTake = pacedEpoch
    embodyPacedLock.unlock()
    guard let buf = AVAudioPCMBuffer(pcmFormat: serverTtsFormat, frameCapacity: AVAudioFrameCount(need)) else { return }
    buf.frameLength = AVAudioFrameCount(need)
    if let dst = buf.floatChannelData?[0] {
      chunk.withUnsafeBufferPointer { dst.update(from: $0.baseAddress!, count: need) }
      if let sink = lipsyncSink, sink.markerOnNextRelease {
        // ★SYNC MARKER: 12 ms of 2 kHz at -6 dBFS, Hann-shaped, MIXED INTO this frame's own slice
        // so it takes the same scheduling path as every other sample (visual-proof lane's design).
        sink.markerOnNextRelease = false
        let sr = serverTtsFormat.sampleRate
        let n = min(need, Int(sr * 0.012))
        for i in 0..<n {
          let env = 0.5 * (1 - cos(2 * Double.pi * Double(i) / Double(n)))
          dst[i] += Float(0.5 * env * sin(2 * Double.pi * 2000.0 * Double(i) / sr))
        }
        NSLog("[embody-marker] click mixed into the released slice at host %.3f s", CACurrentMediaTime())
      }
    }
    notePlayoutScheduled(secs)   // match the actual released quantum (0.04 essence2 / 0.05 embody)
    // macOS-only: device-swap-safe scheduling; iOS has no HAL swap so it schedules directly
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
    if let f = buf.floatChannelData?[0] { noteFarEnd(f, need) }
    embodyPacedLock.lock(); let epochNow = pacedEpoch; embodyPacedLock.unlock()
    if epochNow != epochAtTake {
      // A cut landed between taking this slice and scheduling it: 50 ms of the
      // cancelled reply reached the player AFTER the flush. Counted on the CUT line.
      oldSlicesAfterCut += 1
      NSLog("[bhbarge] OLD-SLICE scheduled after the cut (epoch %d -> %d) total=%d", epochAtTake, epochNow, oldSlicesAfterCut)
    }
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
  /// How many times a published speech frame went out WITHOUT its audio slice.
  /// Every one of these is 50 ms the picture has gained on the sound, permanently.
  private var embodySkippedSlices = 0
  /// Append a diagnostic line to $EMBODY_DUMP_DIR/embody_av.txt (survives an
  /// `open`-launched app). No directory (every release build) ⇒ nothing is written.
  private func appendAvProbe(_ s: String) {
    guard let dir = DevLevers.dumpDir else { return }
    let p = dir + "/embody_av.txt"
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
      // macOS-only: guards the HAL device-swap graph rebuild, which cannot happen on iOS
      #if os(macOS)
      if self.graphIsMutating() {
        self.speakerGenLock.unlock()
        self.pollElevateGate(gen: gen)
        return
      }
      #endif
      let frames = self.lipsyncSink?.speechFramesPublished ?? 0
      let waited = CACurrentMediaTime() - self.gateUtteranceStart
      let frameLanded = frames > self.gateBaseFrames
      if frameLanded || waited >= Self.elevateGateMaxWaitSec {
        let held = self.gateHeldBuffers
        let heldSecs = held.reduce(0.0) {
          $0 + Double($1.frameLength) / self.serverTtsFormat.sampleRate
        }
        // macOS-only: device-swap-safe flush; iOS has no HAL swap
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
          self.lipsyncSink?.noteUtteranceAudioStarted()
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
        // Stamp the sink's speaker clock FIRST so frame pacing references
        // the true playback start, then flush the held chunks in order.
        self.lipsyncSink?.noteUtteranceAudioStarted()
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
    // No sink = a voice session with no avatar. Don't resample 24 -> 16 kHz for
    // nobody: the only consumer of this work is `sink.enqueuePCM` below.
    guard lipsyncSink != nil else { return }
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
        lipsyncSink?.enqueuePCM(pushData)
      }
    }
  }
}
