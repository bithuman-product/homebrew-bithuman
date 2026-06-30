@preconcurrency import AVFoundation
import Foundation
#if os(iOS)
import Flutter
#else
import FlutterMacOS
#endif

/// LOCAL-mode orchestrator for one avatar session. Reuses the plugin's existing
/// RealtimeAudioIO (VP-IO mic + AEC + speaker + the avatar-lipsync path) and
/// AvatarTexture (idle driver-video + 25fps compose); only the BRAIN is new:
///   mic (AEC'd) → Apple SpeechAnalyzer → converse push_text
///   converse TTS (24k) → RealtimeAudioIO.playSpeakerPCM24k (speaker + avatar)
///   barge-in: ENERGY-VAD (unified). The bot STOPS (turn cancelled + speaker/
///             lipsync flushed) the moment the post-AEC mic energy crosses the
///             single `vad_threshold` — RealtimeAudioIO fires io.barge() and the
///             onBarge hook here cancels the brain turn. Energy onset is ~150 ms
///             vs the old ASR word-count's ~300-700 ms first-word latency, so it
///             cuts the instant the user speaks. An echo margin (applied while
///             the bot is audible) stops the bot's own AEC residual from self-
///             barging. The ASR now only transcribes the user's turn for the
///             brain (pushText on .final) + captions; it no longer gates barge.
///             Shared by macOS + iOS — the same path as cloud-WebSocket.
///
/// macOS 26+ only — it holds a SpeechPipeline (SpeechAnalyzer). The plugin
/// guards the entry path with `#available(macOS 26.0, *)`.
@available(macOS 26.0, iOS 26.0, *)
final class LocalConverseController: @unchecked Sendable {
    private let converse: ConverseSession
    private weak var io: RealtimeAudioIO?
    private var speech: SpeechPipeline?
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
    /// Barge-latency instrumentation. Set BITHUMAN_DEBUG_BARGE=1 to log the
    /// timeline (bot-speaking edge, each ASR partial/final with word count, and
    /// the stop) so we can pinpoint the stop-the-moment-I-talk delay.
    private let dbgBarge = ProcessInfo.processInfo.environment["BITHUMAN_DEBUG_BARGE"] == "1"
    private static func ts() -> String { String(format: "%.3f", Date().timeIntervalSince1970) }

    /// Forwarded converse events for the Dart UI (captions + status).
    /// {"kind":"state","state":Int} | {"kind":"bot"|"user","text":String}
    var onEvent: (([String: Any]) -> Void)?

    init?(io: RealtimeAudioIO, gguf: String, supertonicAssets: String?, voice: String = "M1",
          systemPrompt: String = "") {
        guard let c = ConverseSession(gguf: gguf, supertonicAssets: supertonicAssets, voice: voice,
                                      systemPrompt: systemPrompt) else { return nil }
        converse = c
        self.io = io
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
            let wasSilent = self.botAudibleUntil < Date()
            let base = max(self.botAudibleUntil, Date())
            self.botAudibleUntil = base.addingTimeInterval(secs)
            self.lock.unlock()
            if wasSilent, self.dbgBarge { NSLog("[barge-dbg] %@ BOT speaking ▶", Self.ts()) }
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
        converse.onBotChunk  = { [weak self] t in self?.onEvent?(["kind": "bot", "text": t]) }
        converse.onUserFinal = { [weak self] t in self?.onEvent?(["kind": "user", "text": t]) }
        converse.onState     = { [weak self] s in self?.onEvent?(["kind": "state", "state": Int(s.rawValue)]) }
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
        converse.onTurnEnd   = { [weak self] in self?.io?.lipsyncTexture?.onTurnEnd() }

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
            self.converse.interrupt()
            self.lock.lock(); self.botAudibleUntil = .distantPast; self.lock.unlock()
        }
        io.lipsyncPauseControl = false   // hard cut, lossy — "stop the moment the user talks"

        // mic → ASR. Feed CONTINUOUSLY, including while the bot is speaking, so the
        // user's interruption is transcribed live for the brain. VP-IO AEC keeps
        // the bot's own voice out of ch0; the energy VAD (above) drives the barge.
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

        // Apple ASR pipeline (async init) + the mic→ASR + ASR-events loops.
        Task { [weak self] in
            guard let self else { return }
            do { self.speech = try await SpeechPipeline() }
            catch { NSLog("[Converse] SpeechPipeline init failed: %@", "\(error)"); return }
            guard let sp = self.speech else { return }
            Task { for await buf in self.micStream { await sp.push(buf) } }   // single ordered consumer
            for await ev in sp.events {
                switch ev {
                case .partial(let t):
                    // The energy VAD already barged the bot at speech onset; the
                    // partials are now only for live debug visibility.
                    if self.dbgBarge {
                        NSLog("[barge-dbg] %@ partial wc=%d botSpeaking=%@ '%@'",
                              Self.ts(), Self.wordCount(t), self.botSpeaking() ? "Y" : "n", t)
                    }
                case .final(let t):
                    let wc = Self.wordCount(t)
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
                    if wc >= 1 && !self.botSpeaking() {
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
        converse.pushText(t)
    }

    func stop() {
        micCont.finish()
        io?.onMicTap = nil
        io?.onBarge = nil
        io?.onUserSpeechStart = nil
        io?.onUserSpeechEnd = nil
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
