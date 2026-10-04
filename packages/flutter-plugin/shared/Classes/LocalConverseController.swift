// Compiles ONLY when libconverse.xcframework is staged. The on-device
// conversation brain is OPTIONAL: `scripts/bootstrap.sh` vendors it when it can
// reach it, and the podspec sets CONVERSE_AVAILABLE from the staged bytes — the
// same shape essence-2 already uses (ESSENCE2_AVAILABLE). This file needs ConverseSession, hence libconverse.xcframework.
// Without it the plugin still builds and every CLOUD path works; only
// localAudioStart / localAudioStop / localPushText are unavailable.
#if CONVERSE_AVAILABLE
@preconcurrency import AVFoundation
import Foundation
#if os(iOS)
import Flutter
#else
import FlutterMacOS
#endif

/// LOCAL-mode orchestrator for one avatar session. Reuses the plugin's existing
/// RealtimeAudioIO (VP-IO mic + AEC + speaker + the avatar-lipsync path) and its
/// `LipsyncSink` (idle driver-video + 25fps compose); only the BRAIN is new:
///   mic (AEC'd) → Apple SpeechAnalyzer → converse push_text
///   converse TTS (24k) → RealtimeAudioIO.playSpeakerPCM24k (speaker + avatar)
///   barge-in: HOLD → CONFIRM (RealtimeAudioIO.duplexTick). The bot goes quiet
///             the moment the post-AEC mic energy crosses an echo-aware floor —
///             a LOSSLESS pause of speaker + lipsync, not a cut, so the reply is
///             still there if it turns out to have been the agent's own echo.
///             With the speaker paused the far end is silent and the residual
///             with it, so the microphone is re-read against the plain quiet-mode
///             threshold; a person still speaking CONFIRMS and io.barge() fires
///             onBarge here to cancel the brain turn, and an echo RELEASES and the
///             reply resumes from the sample it stopped on. The ASR only transcribes
///             the user's turn for the brain (pushText on .final) + captions; it
///             does not gate barge. Shared by macOS + iOS.
///
/// macOS 26+ only — it holds a SpeechPipeline (SpeechAnalyzer). The plugin
/// guards the entry path with `#available(macOS 26.0, *)`.
/// The hybrid brain's switches (`localAudioStart(replyMode: 'host', sttDir:, ...)`).
struct HybridOptions {
    /// The app supplies the reply text (a HostReplyLlm): speech in and the voice out stay on
    /// the device, the words come from a cheap cloud text model behind the app's server.
    var hostReply: AnyObject? = nil
    /// A sherpa-onnx speech-to-text model directory (+ silero_vad.onnx): SherpaAsr. nil = Apple's
    /// SpeechAnalyzer (nothing to download).
    var sttDir: String? = nil
    /// SherpaAsr: the pause that ends the user's turn.
    var minSilence: Float = 0.5
    /// Barge when the speech-to-text hears the user start talking while the character is audible
    /// (the on-device VAD barge). Off = the energy barge of RealtimeAudioIO only (the mic path).
    var bargeOnSpeech = false
    /// DEV / harness: the microphone is replaced by prerecorded audio (`localInjectWav`), paced in
    /// real time under a noise floor; the session's audio unit then runs without a mic.
    var injected = false
    /// The injected stream's noise floor between and under the files (dBFS RMS; nil = digital silence).
    var noiseDb: Double? = -65
}

@available(macOS 26.0, iOS 26.0, *)
final class LocalConverseController: @unchecked Sendable {
    private let converse: ConverseSession
    private weak var io: RealtimeAudioIO?
    private var speech: AsrPipeline?
    private let options: HybridOptions
    private var injector: AudioInjector?
    /// How long the brain took to load (Supertonic + the reply stage), ms: reported with `ready`.
    let brainLoadMs: Int
    private var statsTimer: DispatchSourceTimer?
    private let micCont: AsyncStream<AVAudioPCMBuffer>.Continuation
    private let micStream: AsyncStream<AVAudioPCMBuffer>
    private var botAudibleUntil = Date.distantPast
    // Audio-level emission for the UI pulse (parity with cloud's mic/bot level
    // streams). Computed at the mic tap + each TTS chunk and forwarded (throttled
    // to ~20 Hz) over the converse event channel; the Dart LocalConverseTransport
    // feeds them into its micLevel/botLevel streams so the primary button animates
    // exactly like the cloud session.
    private var lastMicLevelAt = Date.distantPast
    private var lastBotLevelAt = Date.distantPast
    private static let levelEmitInterval = 0.05  // ~20 Hz
    private let lock = NSLock()
    // ── Turn assembly ──────────────────────────────────────────────────────
    // One spoken utterance can reach us as several ASR finals ("Hi Wise Pup!" …
    // "How are you?"): the recognizer commits at every short pause, more so with
    // .fastResults. The second part used to be DROPPED (it arrived while the bot
    // was already replying, so it looked like a backchannel). A final whose
    // segment STARTED before the reply to the previous spoken turn became audible
    // is the rest of that turn, not a reaction to the bot — it cannot be echo
    // either, since the bot had not made a sound yet. Such a final barges the
    // in-flight reply and is committed as a CONTINUATION: the brain retracts the
    // reply to the first part and answers the whole utterance once.
    // All guarded by `lock`.
    private var engineState: Int32 = 1          // last bc_state from the brain
    private var lastAsrCommitAt: Date?          // last SPOKEN turn committed (nil after a typed turn)
    private var replyAudibleAt: Date?           // first TTS audio of the reply to that turn
    private var segmentStartAt: Date?           // first partial of the segment now being recognized
    private static let continuationMaxSecs: TimeInterval = 10
    // ── What the person heard of the current reply (the hybrid brain's barge report) ──
    // The relay keeps only what was heard in its memory (response.cancel heard_chars). The voice
    // plays the reply's text in order at a steady rate, so heard ≈ chars × played / total audio:
    // the reply's text so far (BOT_CHUNK, Unicode scalars), the audio handed to the speaker for it,
    // and when it became audible (the first-heard probe, which includes the output latency).
    // All guarded by `lock`; reset at each commit / spoken line.
    private var replyChars = 0
    private var replyAudioSecs: Double = 0
    private var replyHeardAt: Date?
    /// Supertonic's speaking rate (characters per second), used only for the part of a reply not
    /// synthesized yet when the person cuts in (English, the default speed).
    private static let voiceCharsPerSec = 15.0
    /// Barge-latency instrumentation. Set BITHUMAN_DEBUG_BARGE=1 to log the
    /// timeline (bot-speaking edge, each ASR partial/final with word count, and
    /// the stop) so we can pinpoint the stop-the-moment-I-talk delay.
    private let dbgBarge = DevLevers.debugBarge
    private static func ts() -> String { String(format: "%.3f", Date().timeIntervalSince1970) }

    /// Forwarded converse events for the Dart UI (captions + status).
    /// {"kind":"state","state":Int} | {"kind":"bot"|"user","text":String}
    var onEvent: (([String: Any]) -> Void)?

    init?(io: RealtimeAudioIO, gguf: String, supertonicAssets: String?, voice: String = "M1",
          systemPrompt: String = "", appleLlm: Bool = false, refusalReply: String = "",
          options: HybridOptions = HybridOptions()) {
        let tLoad = Date()
        guard let c = ConverseSession(gguf: gguf, supertonicAssets: supertonicAssets, voice: voice,
                                      systemPrompt: systemPrompt, appleLlm: appleLlm,
                                      refusalReply: refusalReply, hostReply: options.hostReply) else { return nil }
        converse = c
        self.io = io
        self.options = options
        brainLoadMs = Int(Date().timeIntervalSince(tLoad) * 1000)
        // BOUNDED queue (bufferingNewest): under backpressure — the ASR
        // consumer (SpeechPipeline actor) draining slower than the real-time mic
        // tap — DROP the oldest mic frames instead of retaining them forever.
        // The default .unbounded init let raw multi-channel VP-IO buffers pile
        // up at ~MB/s over a long call → monotonic RSS growth → iOS jetsam OOM,
        // and the consumer chasing an ever-deeper queue is the "barely keeping
        // up" decay. 8 buffers ≈ ~170 ms of headroom for normal jitter; drops
        // only under sustained backlog (degraded ASR beats a crash).
        (micStream, micCont) = { var cont: AsyncStream<AVAudioPCMBuffer>.Continuation!
                                 let s = AsyncStream<AVAudioPCMBuffer>(bufferingPolicy: .bufferingNewest(8)) { cont = $0 }
                                 return (s, cont) }()

        // converse TTS → speaker + avatar lipsync; track the audible window.
        converse.onTTSChunk = { [weak self, weak io] data, turn in
            guard let self else { return }
            // Generation gate (cloud `_audioGen` analogue). A barge bumps
            // ConverseSession.turnGen; a chunk pulled in an older turn belongs to
            // the cancelled reply, so DROP it — never let it re-feed the speaker
            // FIFO / avatar lipsync queue that barge() already flushed. This makes
            // the drop authoritative regardless of how long the cancelled reply was
            // (closes the time-window leak where the bot resumed after the 0.5 s
            // voiceQuietTimeoutSecs lapsed while the converse ring was still draining).
            if turn != self.converse.currentTurnGen { return }
            io?.playSpeakerPCM24k(data)
            let secs = Double(data.count / 2) / 24000.0
            self.lock.lock()
            self.replyAudioSecs += secs
            let wasSilent = self.botAudibleUntil < Date()
            let base = max(self.botAudibleUntil, Date())
            self.botAudibleUntil = base.addingTimeInterval(secs)
            let until = self.botAudibleUntil
            self.lock.unlock()
            // Measurement: `audible_end` once the voice has gone quiet (nothing more was queued
            // behind this chunk) — a harness starts its next "after the reply" step from it.
            if self.options.injected {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + until.timeIntervalSinceNow + 0.02) { [weak self] in
                    guard let self else { return }
                    self.lock.lock(); let same = self.botAudibleUntil == until; self.lock.unlock()
                    if same { self.metric(["ev": "audible_end"]) }
                }
            }
            if wasSilent, self.dbgBarge { NSLog("[barge-dbg] %@ BOT speaking ▶", Self.ts()) }
            self.lock.lock()
            if self.replyAudibleAt == nil { self.replyAudibleAt = Date() }
            self.lock.unlock()
            // NB: we deliberately do NOT flip to a "speaking/responding" state here.
            // The neon "thinking" rim stays ON through the bot's reply (engine
            // SPEAKING(3) maps to thinking in Dart) and turns off only when the
            // engine returns to LISTENING(1) at turn end — matching cloud, which
            // stays thinking from userStopped until responseDone. The speaking pulse
            // is driven separately by the bot_level events below.
            // Drive the UI's speaking pulse from the real TTS amplitude (throttled).
            let now = Date()
            if now.timeIntervalSince(self.lastBotLevelAt) >= Self.levelEmitInterval {
                self.lastBotLevelAt = now
                self.onEvent?(["kind": "bot_level", "level": self.pcm16Peak(data)])
            }
        }
        converse.onMetric = { [weak self] m in self?.metric(m) }
        io.onFirstHeard = { [weak self] at, lat in
            guard let self else { return }
            self.lock.lock(); self.replyHeardAt = Date(timeIntervalSince1970: Double(at) / 1000); self.lock.unlock()
            self.metric(["ev": "heard", "heardAtMs": at, "outputLatencyMs": lat])
        }
        converse.onBotChunk  = { [weak self] t in
            guard let self else { return }
            self.lock.lock(); self.replyChars += t.unicodeScalars.count; self.lock.unlock()
            self.onEvent?(["kind": "bot", "text": t])
        }
        converse.onUserFinal = { [weak self] t in self?.onEvent?(["kind": "user", "text": t]) }
        converse.onState     = { [weak self] s in
            guard let self else { return }
            self.lock.lock(); self.engineState = Int32(s.rawValue); self.lock.unlock()
            self.onEvent?(["kind": "state", "state": Int(s.rawValue)])
        }
        // Brain turn-end: flush the final partial lipsync chunk so the last word
        // renders. This is the DEFERRED end — ConverseSession latches the raw
        // BC_EVENT_BOT_TURN_END (which fires at generation-end) and re-emits it
        // here only after its paced TTS delivery has fully drained to the speaker
        // (ring empty + bufferedUntil reached), gen-gated so a barge drops it. So
        // flushTail() runs strictly AFTER the last lipsync audio of the turn has
        // been forwarded → it can never advance the runtime's ci mid-delivery (the
        // A/V-desync / freeze fix). This is the local analogue of cloud's
        // `response.done → defer until _audioBufferedUntil drains, gated by
        // _audioGen`. macOS-gated inside onTurnEnd() (embody runtime is macOS-only);
        // iOS compiles to a no-op.
        converse.onTurnEnd   = { [weak self] in self?.io?.lipsyncSink?.onTurnEnd() }

        // ENERGY-driven barge: the native VP-IO VAD (RealtimeAudioIO, driven by
        // vad_threshold) fires io.barge() the moment the user's voice crosses the
        // threshold — far faster than waiting for the ASR to transcribe a word.
        // io.barge() flushes the speaker + lipsync; this hook additionally cancels
        // the brain's in-flight turn so no more TTS is generated for the dropped
        // reply. barge() now calls onBarge FIRST (before it flushes embodyPaced /
        // resets the player / clears the lipsync queue) so converse.interrupt()
        // bumps turnGen and gen-fences the producer BEFORE the FIFOs are cleared —
        // a chunk pulled after this returns is stale-gen and dropped in onTTSChunk,
        // so it can't refill the just-cleared FIFOs. This closure only calls
        // converse.interrupt() (never io.barge() again), and interrupt() takes only
        // ConverseSession.outputLock (released between pull-loop iterations, never
        // held across a callback into io), so there is no re-entrancy or deadlock.
        io.onBarge = { [weak self] in
            guard let self else { return }
            #if CONVERSE_HOST_LLM
            // The hybrid brain: tell the app what the person heard BEFORE the brain drops the reply
            // (reply_cancel heardChars), also when its text had already finished streaming.
            if let host = self.options.hostReply as? HostReplyLlm {
                let (heard, speaking) = self.heardSoFar()
                host.barge(heard: heard, stillSpeaking: speaking)
                self.metric(["ev": "barge_heard", "heardChars": heard, "speaking": speaking])
            }
            #endif
            self.converse.interrupt()
            self.lock.lock(); self.botAudibleUntil = .distantPast; self.lock.unlock()
        }
        // (Nothing to switch on here: the lossless hold follows the gate itself —
        // RealtimeAudioIO buffers instead of dropping whenever vad_threshold > 0,
        // which is exactly when a held reply can still be resumed. It used to be a
        // second flag a caller had to remember, and the caller did not.)

        // mic → ASR. Feed CONTINUOUSLY, including while the bot is speaking, so the
        // user's interruption is transcribed live for the brain. VP-IO AEC keeps
        // the bot's own voice out of ch0; the energy VAD (above) drives the barge.
        if options.injected {
            // DEV / harness: prerecorded speech replaces the microphone (localInjectWav).
            let inj = AudioInjector(noiseDb: options.noiseDb) { [weak self] buf in self?.micCont.yield(buf) }
            inj.onMark = { [weak self] m in self?.metric(m) }
            injector = inj
            startStats()
        } else {
        io.onMicTap = { [weak self] buf in
            guard let self else { return }
            self.micCont.yield(buf)
            // Drive the UI's listening pulse from the real (post-AEC) mic amplitude
            // (throttled). Cheap strided peak — safe on the audio-tap thread.
            let now = Date()
            if now.timeIntervalSince(self.lastMicLevelAt) >= Self.levelEmitInterval {
                self.lastMicLevelAt = now
                self.onEvent?(["kind": "mic_level", "level": self.micPeak(buf)])
            }
        }
        }

        // Apple ASR pipeline (async init) + the mic→ASR + ASR-events loops.
        Task { [weak self] in
            guard let self else { return }
            let tAsr = Date()
            var engine = "apple"
            do {
                #if SHERPA_ASR_AVAILABLE
                if let dir = options.sttDir, !dir.isEmpty {
                    let sh = try SherpaAsr(dir: dir, minSilence: options.minSilence)
                    sh.onMetric = { [weak self] m in self?.metric(m) }
                    engine = sh.kind
                    self.speech = sh
                } else {
                    self.speech = try await SpeechPipeline()
                }
                #else
                if let dir = options.sttDir, !dir.isEmpty {
                    NSLog("[Converse] sttDir %@ ignored: this build has no sherpa-onnx (SHERPA_ASR_AVAILABLE)", dir)
                }
                self.speech = try await SpeechPipeline()
                #endif
            } catch {
                NSLog("[Converse] speech-to-text init failed: %@", "\(error)")
                self.metric(["ev": "asr_error", "message": "\(error)"])
                return
            }
            guard let sp = self.speech else { return }
            self.metric(["ev": "asr_ready", "engine": engine, "loadMs": Int(Date().timeIntervalSince(tAsr) * 1000)])
            Task { for await buf in self.micStream { await sp.push(buf) } }   // single ordered consumer
            for await ev in sp.events {
                switch ev {
                case .partial(let t):
                    self.lock.lock()
                    let first = self.segmentStartAt == nil
                    if first { self.segmentStartAt = Date() }
                    self.lock.unlock()
                    if first { self.metric(["ev": "asr_speech", "engine": engine, "partial": t]) }
                    // The on-device VAD barge: the user started talking while the character is
                    // audible → stop the voice + the avatar and cancel the reply (and its stream).
                    if first, self.options.bargeOnSpeech, self.botSpeaking() {
                        let tb = Date()
                        self.io?.barge(reason: "speech")
                        self.metric(["ev": "barge", "reason": "speech", "bargeMs": Int(Date().timeIntervalSince(tb) * 1000)])
                    }
                    // The energy VAD already barged the bot at speech onset; the
                    // partials are now only for live debug visibility.
                    if self.dbgBarge {
                        NSLog("[barge-dbg] %@ partial wc=%d botSpeaking=%@ '%@'",
                              Self.ts(), Self.wordCount(t), self.botSpeaking() ? "Y" : "n", t)
                    }
                case .final(let t):
                    self.metric(["ev": "asr_final", "engine": engine, "text": t])
                    let wc = Self.wordCount(t)
                    self.lock.lock()
                    let segStart = self.segmentStartAt ?? Date()
                    self.segmentStartAt = nil
                    let lastCommit = self.lastAsrCommitAt
                    let audibleAt = self.replyAudibleAt ?? .distantFuture
                    let busy = self.engineState == 2 || self.engineState == 3   // THINKING / SPEAKING
                    self.lock.unlock()
                    if self.dbgBarge {
                        NSLog("[barge-dbg] %@ FINAL wc=%d botSpeaking=%@ '%@'",
                              Self.ts(), wc, self.botSpeaking() ? "Y" : "n", t)
                    }
                    // Commit the user's turn to the brain — but only if the bot is
                    // NOT still audibly speaking. A real interruption already fired
                    // the energy barge, which cancels the turn AND resets
                    // botAudibleUntil (onBarge), so botSpeaking() is false here and
                    // the turn commits. A short utterance WHILE the bot is still
                    // speaking never crossed the (echo-margined) barge threshold —
                    // i.e. a backchannel ("mhm"/"yeah") — so it is dropped rather
                    // than spawning a spurious extra reply.
                    // A final with no letters or digits ("." / "?") is recognizer
                    // noise, never a turn.
                    guard wc >= 1, t.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
                    let continuation = lastCommit.map { Date().timeIntervalSince($0) < Self.continuationMaxSecs } == true
                        && segStart < audibleAt
                    if continuation {
                        // Rest of the previous spoken turn: cancel the reply to the first
                        // part (flushes speaker + avatar; no-op if already cancelled) and
                        // let the brain answer the whole utterance.
                        if busy || self.botSpeaking() { self.io?.barge(reason: "asr-continuation") }
                        self.lock.lock(); self.lastAsrCommitAt = Date(); self.replyAudibleAt = nil; self.lock.unlock()
                        self.resetHeard()
                        self.metric(["ev": "commit", "text": t, "continuation": true])
                        self.io?.armFirstHeard()
                        #if CONVERSE_HOST_LLM
                        (self.options.hostReply as? HostReplyLlm)?.markContinuation()
                        #endif
                        self.converse.pushText(t, continuation: true)
                        self.onEvent?(["kind": "state", "state": 2])
                    } else if !self.botSpeaking() {
                        self.lock.lock(); self.lastAsrCommitAt = Date(); self.replyAudibleAt = nil; self.lock.unlock()
                        self.resetHeard()
                        self.metric(["ev": "commit", "text": t, "continuation": false])
                        self.io?.armFirstHeard()
                        self.converse.pushText(t)
                        // Drive the "thinking" neon rim the instant the user's spoken
                        // turn commits to the brain — the local analogue of cloud's
                        // userStopped→thinking. Don't depend on the C engine's
                        // state-change timing (it may lag the commit). The rim stays
                        // on through SPEAKING and turns off at LISTENING(1) at turn
                        // end (see onState mapping). state==2 ⇒ TransportStatus.thinking.
                        self.onEvent?(["kind": "state", "state": 2])
                    }
                }
            }
        }
    }

    /// True while the bot's TTS is still audible (a turn is in flight). Used only
    /// to tell a normal short turn (bot idle) from a backchannel (bot speaking).
    private func botSpeaking() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return Date() < botAudibleUntil
    }

    /// Whitespace-separated word-token count of an ASR transcript. `split`
    /// omits empty subsequences, so leading/trailing/multiple spaces are fine.
    static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
    }

    /// Peak amplitude in [0,1] of a mic buffer (post-AEC), for the UI level pulse.
    /// Strided to ≤256 samples so the real-time audio-tap thread stays cheap.
    private func micPeak(_ buf: AVAudioPCMBuffer) -> Double {
        let n = Int(buf.frameLength)
        guard n > 0 else { return 0 }
        let step = max(1, n / 256)
        if let ch = buf.floatChannelData {
            let p = ch[0]; var peak: Float = 0; var i = 0
            while i < n { let v = abs(p[i]); if v > peak { peak = v }; i += step }
            return min(1.0, Double(peak))
        }
        if let ch = buf.int16ChannelData {
            let p = ch[0]; var peak: Int32 = 0; var i = 0
            while i < n { let v = abs(Int32(p[i])); if v > peak { peak = v }; i += step }
            return min(1.0, Double(peak) / 32768.0)
        }
        return 0
    }

    /// Peak amplitude in [0,1] of a 24 kHz PCM16-LE TTS chunk.
    private func pcm16Peak(_ data: Data) -> Double {
        let n = data.count / 2
        guard n > 0 else { return 0 }
        let step = max(1, n / 256)
        return data.withUnsafeBytes { raw -> Double in
            let p = raw.bindMemory(to: Int16.self)
            var peak: Int32 = 0; var i = 0
            while i < n { let v = abs(Int32(p[i])); if v > peak { peak = v }; i += step }
            return min(1.0, Double(peak) / 32768.0)
        }
    }

    /// LOCAL-mode typed input: commit a user message to the brain as if it had
    /// been spoken (the agent replies with voice + avatar). Mirrors the ASR
    /// `.final` → `converse.pushText` path used for spoken turns.
    func pushText(_ t: String) {
        // BARGE like a spoken turn: if the bot is mid-reply, cancel it + flush the
        // speaker/lipsync BEFORE committing the new turn. io.barge() calls onBarge
        // first (converse.interrupt() → bumps turnGen, gen-fences the producer) then
        // clears the FIFOs — identical to the energy-VAD barge. Without this, typed
        // input stacks onto the reply the agent is still giving.
        io?.barge()
        // A typed turn (or the greeting directive) is never continued by speech.
        lock.lock(); lastAsrCommitAt = nil; replyAudibleAt = nil; lock.unlock()
        resetHeard()
        metric(["ev": "commit", "text": t, "typed": true])
        io?.armFirstHeard()
        converse.pushText(t)
    }

    /// The hybrid brain: speak [t] as the character's own line, verbatim (`localSpeakText`: the
    /// server's greeting). No reply_request, no user turn. False when the staged brain cannot.
    func speak(_ t: String) -> Bool {
        let line = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return false }
        if botSpeaking() { io?.barge(reason: "speak") }
        lock.lock(); lastAsrCommitAt = nil; replyAudibleAt = nil; lock.unlock()
        resetHeard()
        io?.armFirstHeard()
        let ok = converse.pushSpeak(line)
        metric(["ev": "speak", "chars": line.unicodeScalars.count, "ok": ok])
        return ok
    }

    private func resetHeard() {
        lock.lock(); replyChars = 0; replyAudioSecs = 0; replyHeardAt = nil; lock.unlock()
    }

    /// (characters of the current reply the person has heard, whether its voice is still playing).
    /// heard = chars × played / total, the total audio being the synthesized audio or, for text not
    /// synthesized yet, the text at the voice's rate. Nothing audible yet → 0.
    private func heardSoFar() -> (Int, Bool) {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        let speaking = now < botAudibleUntil
        guard replyChars > 0, let at = replyHeardAt, now > at else { return (0, speaking) }
        let played = min(now.timeIntervalSince(at), replyAudioSecs)
        let total = max(replyAudioSecs, Double(replyChars) / Self.voiceCharsPerSec)
        guard total > 0 else { return (0, speaking) }
        return (min(replyChars, Int((Double(replyChars) * played / total).rounded())), speaking)
    }

    // MARK: - the hybrid brain (host reply) + the harness

    /// A piece of the app's reply to request [id] (`localReplyText`).
    func replyText(id: Int, text: String, done: Bool, result: Int32) {
        #if CONVERSE_HOST_LLM
        (options.hostReply as? HostReplyLlm)?.push(id: id, text: text, done: done, result: result)
        #endif
    }

    /// DEV / harness: speak [samples] (16 kHz mono) into the speech-to-text as if from the mic.
    /// [speechStart] / [speechEnd]: where the words begin and end in the file (seconds), reported as
    /// `inject_speech_start` / `inject_speech_end` the moment the stream passes them.
    func inject(samples: [Float], tag: String, speechStart: Double, speechEnd: Double) -> Bool {
        guard let injector else { return false }
        injector.enqueue(samples, tag: tag, speechStart: speechStart, speechEnd: speechEnd)
        return true
    }

    /// Timing / health metric for the harness: forwarded to Dart as {"kind":"metric", ...} with the
    /// wall clock (ms since 1970) it happened at.
    private func metric(_ m: [String: Any]) {
        var e = m
        e["kind"] = "metric"
        if e["hostMs"] == nil { e["hostMs"] = Int64(Date().timeIntervalSince1970 * 1000) }
        onEvent?(e)
    }

    /// Once a second (harness only): avatar frames published (all / speech), memory, thermal state.
    private func startStats() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        var lastAll = -1, lastSpeech = -1
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let sink = self.io?.lipsyncSink
            let all = (sink as? AvatarTexture)?.publishedFramesTotal ?? 0
            let sp = sink?.speechFramesPublished ?? 0
            var m: [String: Any] = ["ev": "stats", "footprintMb": Self.footprintMb(),
                                    "thermal": ProcessInfo.processInfo.thermalState.rawValue]
            if lastAll >= 0 { m["frames"] = all - lastAll; m["speechFrames"] = sp - lastSpeech }
            lastAll = all; lastSpeech = sp
            m["botSpeaking"] = self.botSpeaking()
            self.metric(m)
        }
        t.resume()
        statsTimer = t
    }

    /// The process' physical footprint (what jetsam counts), MB.
    static func footprintMb() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    func stop() {
        statsTimer?.cancel(); statsTimer = nil
        injector?.stop(); injector = nil
        micCont.finish()
        io?.onMicTap = nil
        io?.onBarge = nil
        io?.resumePlayback()   // clear any lingering pause hold before teardown
        Task { await speech?.stop() }
        converse.stop()
    }
}

/// Flutter EventChannel handler forwarding converse events (state + captions)
/// to the Dart LocalConverseTransport for the UI.
final class ConverseEventStreamHandler: NSObject, FlutterStreamHandler {
    private var sink: FlutterEventSink?
    func onListen(withArguments _: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events; return nil
    }
    func onCancel(withArguments _: Any?) -> FlutterError? { sink = nil; return nil }
    func emit(_ ev: [String: Any]) {
        guard let sink else { return }
        DispatchQueue.main.async { sink(ev) }
    }
}
#endif  // CONVERSE_AVAILABLE
