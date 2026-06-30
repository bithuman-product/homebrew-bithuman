import CConverse
import Foundation

/// Swift wrapper over the converse C ABI (bc_*) for the Flutter plugin's LOCAL
/// mode. Owns the bc_session, forwards events as closures, and runs a TTS
/// pull-loop that emits 24 kHz mono PCM16 chunks (→ RealtimeAudioIO.playSpeakerPCM24k,
/// which drives both the speaker and the avatar lipsync). Apple SpeechAnalyzer
/// drives turns via pushText, so the C++ STT/VAD is left as a no-op mock.
final class ConverseSession: @unchecked Sendable {
    private var handle: OpaquePointer?
    private var pulling = false
    private let pullQ = DispatchQueue(label: "ai.bithuman.converse.pull", qos: .userInitiated)
    // Set by interrupt(): bc_session_interrupt cancels FUTURE generation but does
    // NOT flush the reply already synthesized into the engine's PCM ring, so the
    // pull-loop would keep feeding the cancelled reply to the speaker. While this
    // is true the pull-loop DRAINS that leftover audio without playing it; it
    // auto-clears once the ring empties (got==0), ready for the next turn.
    private var discardOutput = false
    // Set by pushText() while discarding: arms the pull-loop to RESUME (clear
    // discardOutput) on the next empty ring. Without this gate the discard would
    // clear on a mid-synthesis gap and play the REST of the cancelled reply.
    private var armResume = false
    // Turn generation. Bumped on EVERY barge (interrupt) so the chunk a consumer
    // is about to play can be tagged with the turn it was pulled in. A chunk
    // whose tag != the live turnGen belongs to a cancelled reply and is dropped
    // by the consumer (LocalConverseController.onTTSChunk) — this is the local
    // analogue of cloud's `_audioGen` stamp, and it closes the race where a chunk
    // pulled the instant BEFORE discardOutput flips would still reach the speaker.
    // Read by interrupt()'s caller (onBarge) via currentTurnGen.
    private var turnGen: UInt64 = 0
    private let outputLock = NSLock()
    // Pacing clock: wall-clock time when the audio forwarded so far finishes
    // playing. We only forward when < paceAheadSecs ahead of real time, so the
    // PLAYER never buffers more than that — a barge then flushes a tiny buffer
    // (the engine's ring holds the rest, which the discard drops). Without this
    // the loop bursts the whole reply into the player and a barge can't stop it.
    private var bufferedUntil = Date.distantPast
    private static let paceAheadSecs: TimeInterval = 0.1   // keep the player buffer tiny so a barge cuts fast
    // Deferred turn-end. BC_EVENT_BOT_TURN_END fires at GENERATION-end, but the
    // pull-loop keeps draining the engine's already-synthesized PCM ring and
    // pacing it to the speaker for up to ~bufferedUntil AFTER that. Firing
    // onTurnEnd (→ embody flushTail) at generation-end would advance the runtime's
    // ci MID-DELIVERY while more lipsync audio is still being forwarded → A/V
    // desync → freeze. So we LATCH the end here (stamped with the turn it ended in)
    // and let the pull-loop emit the actual onTurnEnd only once delivery has fully
    // drained (ring empty AND bufferedUntil reached). turnEndPendingGen != turnGen
    // means a barge cancelled it → drop. This is the local analogue of cloud's
    // `response.done → defer until _audioBufferedUntil drains, gated by _audioGen`.
    private var turnEndPending = false
    private var turnEndPendingGen: UInt64 = 0

    var onState: ((bc_state) -> Void)?
    var onUserFinal: ((String) -> Void)?
    var onBotChunk: ((String) -> Void)?
    var onTurnEnd: (() -> Void)?
    var onBargeIn: (() -> Void)?
    /// 24 kHz mono PCM16 LE chunk of synthesized speech, ready for playback+lipsync.
    /// `turn` is the generation the chunk was pulled in; the consumer MUST drop it
    /// if `turn != session.currentTurnGen` (a barge cancelled that reply).
    var onTTSChunk: ((_ data: Data, _ turn: UInt64) -> Void)?

    init?(gguf: String, supertonicAssets: String?, voice: String = "M1",
          systemPrompt: String = "") {
        if let a = supertonicAssets, !a.isEmpty { setenv("BITHUMAN_SUPERTONIC_ASSETS", a, 1) }

        var cfg = bc_config_t()
        cfg.abi_version = UInt32(BC_ABI_VERSION)
        cfg.use_mock_backends = 0
        cfg.llm_gpu_layers = -1
        cfg.tts_steps = 4
        cfg.max_tokens = 120
        cfg.mic_always_on = 1   // VP-IO AEC'd mic → keep open for barge-in

        // Personality prompt → the converse engine's LLM persona seed. The
        // `system_prompt` cfg field is a C string that must stay valid only for
        // the bc_session_create call below, so it's bound inside the nested
        // withCString (matching llm_file/stt_model/tts_voice). Empty → leave
        // nil (the engine's built-in default), mirroring the Android JNI.
        var h: OpaquePointer?
        let st: bc_status = gguf.withCString { g in voice.withCString { v in
            "".withCString { w in   // stt_model="" → MockStt, never used (Apple ASR drives via push_text)
                systemPrompt.withCString { sp in
                    cfg.llm_file = g; cfg.stt_model = w; cfg.tts_voice = v
                    cfg.system_prompt = systemPrompt.isEmpty ? nil : sp
                    var hh: OpaquePointer?
                    let s = bc_session_create(&cfg, &hh)
                    h = hh
                    return s
                }
            }
        }}
        guard st == BC_OK, let h else {
            NSLog("[Converse] create failed (%d): %@", st.rawValue, String(cString: bc_last_error_message()))
            return nil
        }
        handle = h
        installCallback()
        startPullLoop()
    }

    private func installCallback() {
        let ud = Unmanaged.passUnretained(self).toOpaque()
        bc_session_set_event_cb(handle, { ud, ev in
            guard let ud, let ev else { return }
            let me = Unmanaged<ConverseSession>.fromOpaque(ud).takeUnretainedValue()
            let e = ev.pointee
            let text = e.text != nil ? String(cString: e.text) : ""
            switch e.kind {
            case BC_EVENT_STATE_CHANGE: me.onState?(e.state)
            case BC_EVENT_USER_FINAL:   me.onUserFinal?(text)
            case BC_EVENT_BOT_CHUNK:    me.onBotChunk?(text)
            case BC_EVENT_BOT_TURN_END:
                // LATCH, don't fire. Generation just ended, but the pull-loop is
                // still draining+pacing the synthesized ring to the speaker. The
                // loop fires onTurnEnd once that delivery drains (see startPullLoop).
                me.outputLock.lock()
                me.turnEndPending = true
                me.turnEndPendingGen = me.turnGen
                me.outputLock.unlock()
            case BC_EVENT_BARGE_IN:     me.onBargeIn?()
            default: break
            }
        }, ud)
    }

    private func startPullLoop() {
        pulling = true
        pullQ.async { [weak self] in
            var buf = [Float](repeating: 0, count: 2400)  // 100 ms @ 24 kHz (small → snappier barge)
            while self?.pulling == true {
                guard let self, let h = self.handle else { break }
                self.outputLock.lock()
                let discard = self.discardOutput
                let ahead = self.bufferedUntil.timeIntervalSinceNow
                let turn = self.turnGen
                self.outputLock.unlock()
                // Pace ONLY when forwarding: don't run more than paceAheadSecs
                // ahead of real-time playback. While discarding we drain the ring
                // as fast as possible (no pacing).
                if !discard && ahead > Self.paceAheadSecs {
                    usleep(20_000)  // 20 ms — let playback catch up
                    continue
                }
                var got = 0
                buf.withUnsafeMutableBufferPointer { bc_session_pull_audio(h, $0.baseAddress, $0.count, &got) }
                if got > 0 {
                    if discard {
                        // Drain the cancelled reply's leftover audio without playing it.
                        continue
                    }
                    // Advance the pacing clock by this chunk's duration.
                    let secs = Double(got) / 24000.0
                    self.outputLock.lock()
                    self.bufferedUntil = Swift.max(self.bufferedUntil, Date()).addingTimeInterval(secs)
                    self.outputLock.unlock()
                    var i16 = [Int16](repeating: 0, count: got)
                    for i in 0..<got { i16[i] = Int16(max(-32768, min(32767, Int((buf[i] * 32767).rounded())))) }
                    let data = i16.withUnsafeBytes { Data($0) }  // little-endian on arm64
                    // Tag with the turn we pulled in. If a barge fired between the
                    // discard read above and here, `turn` is now stale vs turnGen and
                    // the consumer drops it — so a chunk in flight at barge time can
                    // never re-feed the (already flushed) speaker/lipsync FIFOs.
                    self.onTTSChunk?(data, turn)
                } else {
                    // Ring empty. The cancelled reply's leftover audio is now fully
                    // drained+discarded. Resume playing ONLY once a new turn has been
                    // pushed (armResume) — otherwise a mid-synthesis GAP inside the
                    // cancelled reply would un-mute it and play its tail. With the
                    // turnGen stamp this is now belt-and-suspenders: even if discard
                    // lingered, the next chunks carry the new turn's gen and the gate
                    // here clears cleanly on the empty boundary that follows pushText.
                    self.outputLock.lock()
                    if self.discardOutput && self.armResume { self.discardOutput = false; self.armResume = false }
                    // Deferred turn-end. The ring is empty (all synthesized audio
                    // pulled) AND the paced delivery has fully drained to the speaker
                    // (bufferedUntil reached). Now — and only now — is it safe to
                    // flush the avatar's tail: no more lipsync audio will arrive for
                    // this turn, so flushTail can't advance ci mid-delivery. Gen-gate:
                    // fire only if the latch still matches the LIVE turn (a barge
                    // bumped turnGen → drop the flush, exactly like cloud's _audioGen
                    // check around notifyTurnEnd). Fire OUTSIDE the lock so onTurnEnd
                    // (which hops to the embody runtime) never runs under outputLock.
                    let drained = self.bufferedUntil.timeIntervalSinceNow <= 0
                    let fireEnd = self.turnEndPending && !self.discardOutput
                        && self.turnEndPendingGen == self.turnGen && drained
                    if fireEnd { self.turnEndPending = false }
                    self.outputLock.unlock()
                    if fireEnd { self.onTurnEnd?() }
                    usleep(10_000)  // 10 ms
                }
            }
        }
    }

    /// The live turn generation. A TTS chunk whose stamp != this value belongs to
    /// a cancelled (barged) reply and MUST be dropped by the consumer. Cheap +
    /// lock-free read for the audio/forward path.
    var currentTurnGen: UInt64 { outputLock.lock(); defer { outputLock.unlock() }; return turnGen }

    func pushText(_ t: String) {
        // If the PREVIOUS turn's deferred end is still latched (its paced delivery
        // hadn't fully drained when this new turn was committed — rare, only on a
        // very fast back-to-back), fire it NOW, before the new turn's audio starts
        // filling the ring. This flushes the old turn's tail while the runtime is
        // still on the old utterance, so the new turn's first chunk (which triggers
        // an idle-reset → resetState at the compose tick) starts clean at ci=0 and
        // the old flush can never interleave with new delivery. Fire outside the
        // lock (onTurnEnd hops to the embody runtime).
        outputLock.lock()
        if discardOutput { armResume = true }
        let firePrev = turnEndPending && turnEndPendingGen == turnGen && !discardOutput
        if firePrev { turnEndPending = false }
        outputLock.unlock()
        if firePrev { onTurnEnd?() }
        _ = t.withCString { bc_session_push_text(handle, $0) }
    }

    /// Barge: cancel the in-flight reply immediately and flush everything it
    /// produced, mirroring cloud (response.cancel + drop queued audio).
    ///   1. Bump turnGen so any chunk already pulled-but-not-yet-FORWARDED is
    ///      stale at the consumer and gets dropped (closes the pull/flip race —
    ///      the cloud `_audioGen` analogue).
    ///   2. Set discardOutput so the pull-loop stops forwarding and instead
    ///      drains the engine's already-synthesized ring to empty WITHOUT pacing
    ///      (the loop's `if discard { continue }` path, run unpaced because the
    ///      pace check is skipped while discarding). This is the flush of the C++
    ///      ring — there is no bc_session_clear in the ABI, so the single-consumer
    ///      pull-loop draining it IS the flush, and it can't deadlock because the
    ///      drain happens on the loop's own thread, never blocked by the caller.
    ///   3. bc_session_interrupt → cancel FUTURE LLM/TTS generation.
    /// Non-blocking and lock-ordered: takes only outputLock (the same lock the
    /// pull-loop releases between iterations), so onBarge on the audio/main thread
    /// never blocks on the pull thread or the C engine.
    func interrupt() {
        outputLock.lock()
        turnGen &+= 1
        discardOutput = true
        armResume = false
        bufferedUntil = Date.distantPast
        // Drop any latched turn-end: the reply it belonged to is being cancelled,
        // so its flushTail must NOT run (it would advance ci into the next turn).
        // turnGen++ above already invalidates it via the gen check; clearing makes
        // it explicit and stops a stale latch from racing the next pushText.
        turnEndPending = false
        outputLock.unlock()
        bc_session_interrupt(handle)
    }

    func stop() {
        pulling = false
        // Drain the pull queue: wait for any in-flight pull-loop iteration to
        // observe pulling=false and exit BEFORE freeing the handle. Without this
        // the loop can be inside bc_session_pull_audio on a handle we then
        // destroy (use-after-free). The loop already breaks on `pulling==false`,
        // so this sync block runs only after it returns.
        pullQ.sync {}
        if let h = handle { bc_session_destroy(h); handle = nil }
    }
    deinit { stop() }
}
