package ai.bithuman.flutter.brain

import android.os.Process
import android.os.SystemClock
import android.util.Log
import com.k2fsa.sherpa.onnx.GenerationConfig
import com.k2fsa.sherpa.onnx.OfflineRecognizer
import com.k2fsa.sherpa.onnx.OfflineTts
import com.k2fsa.sherpa.onnx.OfflineTtsConfig
import com.k2fsa.sherpa.onnx.OfflineTtsModelConfig
import com.k2fsa.sherpa.onnx.OfflineTtsSupertonicModelConfig
import com.k2fsa.sherpa.onnx.SileroVadModelConfig
import com.k2fsa.sherpa.onnx.Vad
import com.k2fsa.sherpa.onnx.VadModelConfig
import java.io.File
import java.util.concurrent.LinkedBlockingDeque
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlin.math.sqrt

/**
 * The on-device conversation brain for Android — the same contract as Apple's
 * libconverse C ABI (`bithuman/libconverse.h`, BC_ABI_VERSION 2), mirrored member for
 * member so the plugin drives both the same way:
 *
 *   bc_session_create        -> [ConverseEngine.create]
 *   bc_session_push_audio    -> [pushAudio]   16 kHz mono float mic (VAD + STT inside)
 *   bc_session_push_text     -> [pushText]    a finished user turn (typed, or a platform ASR)
 *   bc_session_pull_audio    -> [pullAudio]   24 kHz mono float reply speech
 *   bc_session_interrupt     -> [interrupt]   barge-in: cancel the reply, drop its audio
 *   bc_session_reset         -> [reset]       forget the conversation
 *   bc_session_state         -> [state]
 *   bc_event_cb              -> [Listener]    the same event kinds and states, same numbers
 *
 * Backends: silero VAD + a sherpa-onnx speech-to-text model ([SpeechIn]: Moonshine, Whisper,
 * Parakeet, ...) for speech in, the reply stage ([ReplyModel]: llama.cpp on the device, or
 * [HostReplyModel] — text the app streams in, e.g. from a cloud model), Supertonic (sherpa-onnx,
 * the voice the Apple path speaks with) for speech out. Speech never leaves the device.
 *
 * One deliberate difference from the Apple wrapper: [pullAudio] returns [END_OF_REPLY]
 * (-1) exactly once, in order, after the last sample of a reply — the end marker rides
 * the same queue as the audio, so a consumer that feeds the avatar AS FAST AS PRODUCED
 * (measured on Apple: pacing to real time cost ~1 s of mouth onset) can flush the
 * avatar's tail at exactly the right moment with no clock and no race.
 */
internal class ConverseEngine private constructor(
    private val cfg: Config,
    private val listener: Listener,
    private val llm: ReplyModel,
    private val tts: OfflineTts,
    private val vad: Vad,
    private val asr: OfflineRecognizer,
) {
    data class Config(
        /** The llama.cpp GGUF; unused when [replyModel] is set. */
        val llmPath: String = "",
        val supertonicDir: String,
        /** A speech-to-text model directory ([SpeechIn] picks the model by its files) holding silero_vad.onnx too. */
        val sttDir: String,
        val voice: String = "M1",
        val systemPrompt: String? = null,
        val maxTokens: Int = 96,
        val maxSentences: Int = 3,
        val ttsSteps: Int = 4,
        val ttsSpeed: Float = 1.0f,
        /** Supertonic's ONNX Runtime threads (see [create] for the measured choice). */
        val ttsThreads: Int = TTS_THREADS,
        val sttThreads: Int = 2,
        val llmThreads: Int = 4,
        val llmContext: Int = 2048,
        /** VAD endpoint: trailing silence that ends the user's turn. */
        val minSilenceMs: Int = 400,
        /** A second final within this window of the first, before any reply audio, is the SAME turn. */
        val mergeWindowMs: Int = 2500,
        /** Echo-cancelled mic: keep listening while the bot speaks so the user can cut in. */
        val micAlwaysOn: Boolean = true,
        /** Sustained speech needed to cut the bot off, and the level it must clear (dBFS). */
        val bargeMinSpeechMs: Int = 320,
        val bargeMinDbfs: Double = -38.0,
        /** Completed exchanges kept as context (the KV cache slides with it, see bh_llm_jni.cpp). */
        val historyExchanges: Int = 4,
        val temperature: Float = 0.7f,
        /**
         * The reply stage. Null = llama.cpp on [llmPath] ([LlamaBrain]). Any other
         * [ReplyModel] (LiteRT-LM, an OS model, ...) drops in here; [llmPath] is then only
         * what that factory makes of it.
         */
        val replyModel: ((Config) -> ReplyModel)? = null,
        /**
         * Cut the ~0.4 s of silence every Supertonic synthesis opens with to a 30 ms pre-roll
         * ([AudioTrim]), on every chunk. False keeps it (A/B and rollback only).
         */
        val trimLeadingSilence: Boolean = true,
        /**
         * Send the system prompt (persona + house rules) to the reply stage. False when the reply
         * comes from a server that owns the character's persona (the host then gets the bounded
         * history and the user's turn only).
         */
        val sendSystemPrompt: Boolean = true,
        /**
         * The first [clauseChunks] voice chunks of a reply may end at a clause (, ; : —) once they hold
         * [firstChunkMinWords] words; later ones wait for a sentence end (better prosody). The same rule
         * as libconverse on Apple (kFirstChunkMinWords = 3, BITHUMAN_CONVERSE_CLAUSE_CHUNKS = 2).
         */
        val firstChunkMinWords: Int = 3,
        val clauseChunks: Int = 2,
        /**
         * The first chunk holds at least this many words (0 = no floor). Galaxy Z Flip5 (2026-10-04, the
         * hybrid harness, both house avatars): neither engine starts a reply's mouth on less than ~1.3 s of
         * its audio. A 1-3 word first chunk is 1.0-1.3 s of Supertonic audio (it pads a short line, and
         * synthesizes it no faster under the avatar), and the first mouth frame was then often seconds
         * late (1-2 words: 7.4 s Essence 2 / 2.9 s Expression 2 p50, n=5 each; 3 words: 4 of 8 openings
         * were <= 1.31 s of audio, two of them started at 5.3 / 6.5 s), while every 4+ word opening was
         * >= 1.7 s of audio and started in 0.8-1.2 s.
         * A higher floor merges a short opening into a long first chunk where punctuation is sparse
         * ("Great question, friend! A latte is ... on top,": 6.6 s of audio, +1.0-1.3 s), so 4.
         */
        val firstChunkFloorWords: Int = FIRST_CHUNK_FLOOR_WORDS,
        /** Spoken when the reply stage fails before saying anything (no network, a timeout). */
        val errorReply: String = "Sorry, I lost my train of thought. Could you say that again?",
        /** Spoken when the host refuses a turn before saying anything (result 1); "" = [errorReply]. */
        val refusalReply: String = "",
        /**
         * Of reply generation [gen]'s audio, the 24 kHz samples the person has HEARD (the avatar's audio
         * clock), or null when unknown. Turns a cut into `heardChars` for the host (reply_cancel).
         */
        val heardSamples: ((gen: Int) -> Long?)? = null,
    )

    fun interface Listener { fun onEvent(kind: Int, state: Int, text: String) }

    private class Turn(val gen: Int, val userText: String, val spoken: Boolean,
                       /** The user went on after a pause: [userText] is the whole utterance (reply_request continuation). */
                       val continuation: Boolean = false,
                       /** A line to speak verbatim (localSpeakText) — no reply stage, no user turn. */
                       val say: String? = null) {
        @Volatile var audioStarted = false
        @Volatile var audioStartedAt = 0L
        val reply = StringBuilder()
        /** The reply stage's view of the turn; its hostId names the host request. */
        val rt = ReplyTurn(userText, continuation)
        /** The host stream is running (a cut cancels it rather than reporting after the fact). */
        @Volatile var streaming = false
        /** A cut of this reply after its stream ended has been reported (once). */
        @Volatile var cutReported = false
        /** Per synthesized chunk: (raw characters of the reply text up to its end, its 24 kHz samples). Under [lock]. */
        val spans = ArrayList<Pair<Int, Int>>()
        /** Raw characters of the reply text consumed by the chunks emitted so far. */
        @Volatile var rawEmitted = 0
    }

    private sealed class TtsJob(val gen: Int) {
        class Say(gen: Int, val text: String, val rawEnd: Int = 0) : TtsJob(gen)
        class End(gen: Int) : TtsJob(gen)
    }

    private val lock = Any()
    @Volatile private var running = true
    @Volatile private var st = STATE_IDLE
    @Volatile private var turnGen = 0
    private var inFlight: Turn? = null
    /** The last reply handed off whole, while its audio may still be playing (barge target). */
    private var lastTurn: Turn? = null
    private var lastFinalAt = 0L
    /** A spoken turn cut off by the user moments after the bot started: its words join the next final. */
    private var pendingMerge: String? = null
    private var pendingMergeAt = 0L
    private val history = ArrayList<Pair<String, String>>()   // (user, assistant)
    private val system = TextShaping.systemPrompt(cfg.systemPrompt)

    private val audioIn = LinkedBlockingQueue<FloatArray>(256)
    private val llmJobs = LinkedBlockingQueue<Turn>()
    private val ttsJobs = LinkedBlockingDeque<TtsJob>()
    private val outLock = Any()
    private val out = ArrayDeque<FloatArray>()            // gen-current reply audio; EMPTY_END marks the end
    private var outHead: FloatArray? = null
    private var outHeadPos = 0
    private var audibleUntil = 0L                          // wall clock the handed-off audio finishes playing
    private val tts44to24 = Resampler(tts.sampleRate(), OUTPUT_SAMPLE_RATE)
    private val sid = voiceToSid(cfg.voice, tts.numSpeakers())

    private val threads = listOf(
        Thread({ sttLoop() }, "bh-brain-stt"),
        Thread({ llmLoop() }, "bh-brain-llm"),
        Thread({ ttsLoop() }, "bh-brain-tts"),
    )

    init {
        threads.forEach { it.start() }
        setState(STATE_LISTENING)
    }

    // ------------------------------------------------------------------ the contract

    fun state(): Int = st

    /** The live reply generation; audio pulled under an older one belongs to a cancelled reply. */
    fun currentGen(): Int = turnGen

    /** The generation the last [pullAudio] read under (set atomically with the read). */
    @Volatile var pulledGen = 0
        private set

    /** 16 kHz mono float. Non-blocking; drops the oldest chunk rather than grow under backlog. */
    fun pushAudio(pcm: FloatArray) {
        if (!running) return
        while (!audioIn.offer(pcm)) audioIn.poll()
    }

    /** A finished user turn as text. Barges any reply in flight (a typed turn is a cut-in). */
    fun pushText(text: String) {
        val t = text.trim()
        if (t.isEmpty()) return
        synchronized(lock) {
            if (inFlight != null) interruptLocked(event = false)
            startTurnLocked(t, spoken = false)
        }
    }

    /**
     * Drain reply speech, 24 kHz mono float. Returns the samples written, 0 when there is
     * nothing yet, or [END_OF_REPLY] once when the current reply's last sample has been
     * handed over.
     */
    fun pullAudio(dst: FloatArray): Int {
        synchronized(outLock) {
            pulledGen = turnGen
            var n = 0
            while (n < dst.size) {
                val head = outHead ?: out.removeFirstOrNull()?.also { outHead = it; outHeadPos = 0 } ?: break
                if (head === EMPTY_END) {
                    if (n > 0) break                               // hand over the audio first
                    outHead = null
                    onReplyHandedOff()
                    return END_OF_REPLY
                }
                val k = minOf(dst.size - n, head.size - outHeadPos)
                System.arraycopy(head, outHeadPos, dst, n, k)
                n += k; outHeadPos += k
                if (outHeadPos >= head.size) outHead = null
            }
            if (n > 0) {
                val now = SystemClock.elapsedRealtime()
                audibleUntil = maxOf(audibleUntil, now) + n * 1000L / OUTPUT_SAMPLE_RATE
            }
            return n
        }
    }

    /**
     * The character's own line, verbatim (localSpeakText — the server's greeting): no reply stage and no
     * user turn; captioned, voiced and interruptible like a reply, and kept in the history as its line.
     */
    fun speak(text: String): Boolean {
        val t = text.trim()
        if (t.isEmpty() || !running) return false
        synchronized(lock) {
            if (inFlight != null || SystemClock.elapsedRealtime() < synchronized(outLock) { audibleUntil }) interruptLocked(event = false)
            startTurnLocked("", spoken = false, say = t)
        }
        return true
    }

    /** Barge-in: cancel the reply in flight, drop what it synthesized, back to LISTENING. */
    fun interrupt() = synchronized(lock) { interruptLocked(event = false) }

    fun reset() = synchronized(lock) {
        interruptLocked(event = false)
        history.clear()
        llmJobs.clear()
        llm.reset()
    }

    fun destroy() {
        running = false
        synchronized(lock) { interruptLocked(event = false) }
        llmJobs.offer(Turn(-1, "", false))
        ttsJobs.offer(TtsJob.End(-1))
        threads.forEach { runCatching { it.join(2000) } }
        runCatching { llm.close() }
        runCatching { tts.release() }
        runCatching { vad.release() }
        runCatching { asr.release() }
    }

    // ------------------------------------------------------------------ turns

    private fun startTurnLocked(text: String, spoken: Boolean, continuation: Boolean = false, say: String? = null) {
        val gen = synchronized(outLock) { ++turnGen }
        val t = Turn(gen, text, spoken, continuation, say)
        inFlight = t
        setState(STATE_THINKING)
        Log.i(TAG, "[bhbrain] turn gen=$gen start src=${if (spoken) "asr" else "text"} hostMs=${System.currentTimeMillis()} '${text.take(80)}'")
        llmJobs.offer(t)
    }

    private fun interruptLocked(event: Boolean) {
        val t = inFlight ?: lastTurn
        val now = SystemClock.elapsedRealtime()
        if (event && t != null && t.spoken && t.audioStarted && now - t.audioStartedAt < cfg.mergeWindowMs) {
            pendingMerge = t.userText; pendingMergeAt = now
        }
        // The host learns how much of the reply was heard BEFORE the ring is cleared and the player cut
        // (reply_cancel {id, heardChars}): while its stream runs, through the stream's cancel; after it
        // ended but while its voice still played, reported once.
        val host = llm as? HostReplyModel
        val audible = now < synchronized(outLock) { audibleUntil } || (t != null && t === inFlight)
        val heard = if (host != null && t != null && t.rt.hostId > 0) heardCharsLocked(t) else null
        // The generation moves with the ring cleared under ONE lock, so a pull sees either
        // the old reply's audio under the old gen or nothing under the new one.
        synchronized(outLock) { turnGen++; out.clear(); outHead = null; audibleUntil = 0L }
        if (host != null && t != null && t.streaming) host.cancel(heard)
        else {
            llm.cancel()
            if (host != null && t != null && t.rt.hostId > 0 && audible && !t.cutReported) {
                t.cutReported = true
                host.reportCancel(t.rt.hostId, heard)
            }
        }
        ttsJobs.clear()
        if (t != null && t === inFlight) {
            // What the user heard of it stays in the conversation, so "as I was saying" works.
            if (t.audioStarted && t.reply.isNotBlank() && pendingMerge == null) commitLocked(t.userText, t.reply.toString().trim() + " ...")
            inFlight = null
        }
        lastTurn = null
        if (event) listener.onEvent(EVENT_BARGE_IN, st, "")
        setState(STATE_LISTENING)
    }

    private fun commitLocked(user: String, assistant: String) {
        history.add(user to assistant)
        // Capped history. Trim two at a time so the KV slide happens every other turn,
        // not every turn (bh_llm_jni.cpp shifts the survivors down instead of re-prefilling).
        if (history.size > cfg.historyExchanges) {
            while (history.size > maxOf(1, cfg.historyExchanges - 2)) history.removeAt(0)
        }
    }

    private fun onUserFinal(text: String) {
        synchronized(lock) {
            val now = SystemClock.elapsedRealtime()
            val botAudible = now < synchronized(outLock) { audibleUntil }
            if (botAudible) {
                // Still talking and the VAD did not rate this as a cut-in: a backchannel.
                if (wordCount(text) < 3) { Log.i(TAG, "[bhbrain] backchannel dropped '$text'"); return }
                interruptLocked(event = true)
            }
            val cur = inFlight
            var merged = text
            var continuation = false
            val pm = pendingMerge
            if (pm != null && now - pendingMergeAt < cfg.mergeWindowMs + 5000) {
                merged = "$pm $text"; continuation = true
                Log.i(TAG, "[bhbrain] merge after early cut -> '${merged.take(80)}'")
            }
            pendingMerge = null
            if (cur != null && !cur.audioStarted && cur.spoken && now - lastFinalAt < cfg.mergeWindowMs) {
                // The user paused mid-thought and the VAD split one turn in two: cancel the
                // reply to the first half (nothing was said yet) and answer the whole.
                merged = cur.userText + " " + merged; continuation = true
                Log.i(TAG, "[bhbrain] merge split turn gen=${cur.gen} -> '${merged.take(80)}'")
                interruptLocked(event = false)
            }
            lastFinalAt = now
            listener.onEvent(EVENT_USER_FINAL, st, merged)
            startTurnLocked(merged, spoken = true, continuation = continuation)
        }
    }

    // ------------------------------------------------------------------ STT thread

    private fun sttLoop() {
        runCatching { Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO) }
        val window = 512
        val pend = FloatArray(window)
        var pendN = 0
        var speechMs = 0
        var wasSpeech = false
        while (running) {
            val chunk = audioIn.poll(50, TimeUnit.MILLISECONDS) ?: continue
            var off = 0
            while (off < chunk.size) {
                val k = minOf(window - pendN, chunk.size - off)
                System.arraycopy(chunk, off, pend, pendN, k)
                pendN += k; off += k
                if (pendN < window) break
                pendN = 0
                vad.acceptWaveform(pend)
                val speech = vad.isSpeechDetected()
                if (speech && !wasSpeech) Log.i(TAG, "[bhbrain] vad speech_start hostMs=${System.currentTimeMillis()}")
                wasSpeech = speech
                if (speech) {
                    speechMs += window * 1000 / INPUT_SAMPLE_RATE
                    maybeBarge(speechMs, dbfs(pend))
                } else speechMs = 0
                while (!vad.empty()) {
                    val seg = vad.front(); vad.pop()
                    transcribe(seg.samples)
                }
            }
        }
    }

    private fun maybeBarge(speechMs: Int, level: Double) {
        if (!cfg.micAlwaysOn || speechMs < cfg.bargeMinSpeechMs || level < cfg.bargeMinDbfs) return
        synchronized(lock) {
            val botAudible = SystemClock.elapsedRealtime() < synchronized(outLock) { audibleUntil }
            if (botAudible) {
                Log.i(TAG, "[bhbrain] BARGE gen=$turnGen speechMs=$speechMs dbfs=${"%.1f".format(level)} hostMs=${System.currentTimeMillis()}")
                interruptLocked(event = true)
            }
        }
    }

    private fun transcribe(samples: FloatArray) {
        Log.i(TAG, "[bhbrain] vad segment audioMs=${samples.size * 1000 / INPUT_SAMPLE_RATE} hostMs=${System.currentTimeMillis()}")
        val t0 = SystemClock.elapsedRealtime()
        val s = asr.createStream()
        val text = try {
            s.acceptWaveform(samples, INPUT_SAMPLE_RATE)
            asr.decode(s)
            asr.getResult(s).text.trim()
        } finally { s.release() }
        val ms = SystemClock.elapsedRealtime() - t0
        Log.i(TAG, "[bhbrain] stt_final decodeMs=$ms audioMs=${samples.size * 1000 / INPUT_SAMPLE_RATE} hostMs=${System.currentTimeMillis()} '$text'")
        if (text.none { it.isLetterOrDigit() }) return
        onUserFinal(text)
    }

    // ------------------------------------------------------------------ LLM thread

    private fun llmLoop() {
        while (running) {
            val turn = llmJobs.poll(100, TimeUnit.MILLISECONDS) ?: continue
            if (!running) break
            if (turn.gen != turnGen) continue
            runCatching { reply(turn) }.onFailure { Log.e(TAG, "[bhbrain] turn failed: $it", it) }
        }
    }

    private fun reply(turn: Turn) {
        val gen = turn.gen
        val t0 = System.currentTimeMillis()
        turn.say?.let { line ->
            Log.i(TAG, "[bhbrain] speak gen=$gen chars=${line.length} — the character's own line, no reply stage")
            val ch = TextShaping.Chunker(cfg.firstChunkMinWords, clauseChunks = cfg.clauseChunks, firstFloorWords = cfg.firstChunkFloorWords)
            (ch.pushWithEnds("$line ") + listOfNotNull(ch.flushWithEnd())).forEach { (c, end) -> emitChunk(turn, c, end) }
            ttsJobs.offer(TtsJob.End(gen))
            return
        }
        if (TextShaping.isCrisis(turn.userText)) {
            Log.i(TAG, "[bhbrain] crisis guard gen=$gen — fixed reply, no model")
            // Sentence by sentence, like any reply, so the first words are heard in ~0.3 s.
            val ch = TextShaping.Chunker(cfg.firstChunkMinWords, clauseChunks = cfg.clauseChunks, firstFloorWords = cfg.firstChunkFloorWords)
            (ch.push(TextShaping.CRISIS_REPLY + " ") + listOfNotNull(ch.flush())).forEach { emitChunk(turn, it) }
            ttsJobs.offer(TtsJob.End(gen))
            return
        }
        val messages = ArrayList<Pair<String, String>>()
        if (cfg.sendSystemPrompt) messages.add("system" to system)
        synchronized(lock) {
            for ((u, a) in history) { if (u.isNotEmpty()) messages.add("user" to u); messages.add("assistant" to a) }
        }
        messages.add("user" to turn.userText)

        val chunker = TextShaping.Chunker(cfg.firstChunkMinWords, clauseChunks = cfg.clauseChunks, firstFloorWords = cfg.firstChunkFloorWords)
        var first = true
        var sentences = 0
        turn.streaming = true
        val n = try {
            llm.generate(turn.rt, messages, cfg.maxTokens, cfg.temperature) { text ->
                if (gen != turnGen || !running) return@generate false
                if (first) { first = false; Log.i(TAG, "[bhbrain] llm first_token gen=$gen ms=${System.currentTimeMillis() - t0} hostMs=${System.currentTimeMillis()}") }
                for ((c, end) in chunker.pushWithEnds(text)) {
                    if (emitChunk(turn, c, end)) sentences++
                    if (sentences >= cfg.maxSentences) {
                        // The rest is never spoken: the host hears that the reply ends here.
                        (llm as? HostReplyModel)?.stopAt(turn.rawEmitted)
                        return@generate false
                    }
                }
                true
            }
        } finally { turn.streaming = false }
        if (gen == turnGen && sentences < cfg.maxSentences) chunker.flushWithEnd()?.let { (c, end) -> emitChunk(turn, c, end) }
        Log.i(TAG, "[bhbrain] llm done gen=$gen tokens=$n ${llm.lastStats()} hostMs=${System.currentTimeMillis()}")
        // The reply stage failed before a word was said: say so instead of going silent.
        if (n < 0 && gen == turnGen && turn.reply.isBlank()) {
            val refused = (llm as? HostReplyModel)?.lastResult == HostReplyModel.RESULT_REFUSED
            val line = if (refused && cfg.refusalReply.isNotBlank()) cfg.refusalReply else cfg.errorReply
            if (line.isNotBlank()) emitChunk(turn, line)
        }
        if (gen != turnGen) return
        ttsJobs.offer(TtsJob.End(gen))
    }

    /** Clean a chunk, caption it and queue it for the voice. False when nothing speakable was left. */
    private fun emitChunk(turn: Turn, raw: String, rawEnd: Int = -1): Boolean {
        val c = TextShaping.clean(raw).trim()
        if (c.none { it.isLetterOrDigit() } || turn.gen != turnGen) return false
        // Raw characters of the reply text (as streamed) this chunk ends at: what heardChars counts in.
        turn.rawEmitted = if (rawEnd >= 0) rawEnd else turn.rawEmitted
        turn.reply.append(c).append(' ')
        listener.onEvent(EVENT_BOT_CHUNK, st, "$c ")
        ttsJobs.offer(TtsJob.Say(turn.gen, c, turn.rawEmitted))
        return true
    }

    /**
     * Characters of [t]'s reply text the person has heard: its chunks' audio against the avatar's audio
     * clock ([Config.heardSamples]), the chunk in progress pro rata. 0 before any of it was audible;
     * null when the clock is unknown. Caller holds [lock].
     */
    private fun heardCharsLocked(t: Turn): Int? {
        if (!t.audioStarted) return 0
        val played = cfg.heardSamples?.invoke(t.gen) ?: return null
        var at = 0L
        var prevEnd = 0
        for ((end, samples) in t.spans) {
            if (played < at + samples) {
                val frac = (played - at).coerceAtLeast(0).toDouble() / maxOf(1, samples)
                return prevEnd + ((end - prevEnd) * frac).toInt()
            }
            at += samples; prevEnd = end
        }
        return prevEnd
    }

    // ------------------------------------------------------------------ TTS thread

    private fun ttsLoop() {
        val gc = GenerationConfig(sid = sid, numSteps = cfg.ttsSteps, speed = cfg.ttsSpeed)
        while (running) {
            val job = ttsJobs.poll(100, TimeUnit.MILLISECONDS) ?: continue
            if (job.gen != turnGen) continue
            when (job) {
                is TtsJob.Say -> {
                    val t0 = SystemClock.elapsedRealtime()
                    val audio = tts.generateWithConfig(job.text, gc)
                    val (native, cut) = if (cfg.trimLeadingSilence) AudioTrim.trimLeadingSilence(audio.samples, audio.sampleRate)
                        else audio.samples to 0
                    val pcm = tts44to24.process(native)
                    val leadMs = AudioTrim.leadSamples(pcm) * 1000L / OUTPUT_SAMPLE_RATE
                    val ms = SystemClock.elapsedRealtime() - t0
                    var firstOfTurn = false
                    synchronized(lock) {
                        if (job.gen != turnGen) return@synchronized
                        val t = inFlight
                        if (t != null && !t.audioStarted) { t.audioStarted = true; t.audioStartedAt = SystemClock.elapsedRealtime(); firstOfTurn = true }
                        synchronized(outLock) { if (job.gen == turnGen) out.addLast(pcm) }
                        t?.takeIf { it.gen == job.gen }?.spans?.add(job.rawEnd to pcm.size)
                        setState(STATE_SPEAKING)
                    }
                    Log.i(TAG, "[bhbrain] tts gen=${job.gen} synthMs=$ms audioMs=${pcm.size * 1000 / OUTPUT_SAMPLE_RATE} " +
                        "trimMs=${cut * 1000L / maxOf(1, audio.sampleRate)} leadMs=$leadMs first=$firstOfTurn hostMs=${System.currentTimeMillis()} '${job.text.take(60)}'")
                }
                is TtsJob.End -> synchronized(lock) {
                    if (job.gen != turnGen) return@synchronized
                    synchronized(outLock) { out.addLast(EMPTY_END) }
                    inFlight?.let { if (it.gen == job.gen) { commitLocked(it.userText, it.reply.toString().trim()); lastTurn = it; inFlight = null } }
                    listener.onEvent(EVENT_BOT_TURN_END, st, "")
                }
            }
        }
    }

    /** Called under outLock when the consumer takes the end marker: the whole reply is handed over. */
    private fun onReplyHandedOff() {
        val gen = turnGen
        val tail = maxOf(0L, audibleUntil - SystemClock.elapsedRealtime())
        // The engine is LISTENING when the voice actually stops, not when the last byte
        // left the ring (the consumer feeds the avatar faster than real time).
        Thread {
            if (tail > 0) Thread.sleep(tail)
            synchronized(lock) { if (gen == turnGen && inFlight == null) setState(STATE_LISTENING) }
        }.apply { name = "bh-brain-tail"; isDaemon = true }.start()
    }

    private fun setState(s: Int) {
        if (st == s) return
        st = s
        listener.onEvent(EVENT_STATE_CHANGE, s, STATE_NAMES[s])
    }

    companion object {
        private const val TAG = "bhbrain"
        const val INPUT_SAMPLE_RATE = 16000     // BC_INPUT_SAMPLE_RATE
        const val OUTPUT_SAMPLE_RATE = 24000    // BC_OUTPUT_SAMPLE_RATE
        const val END_OF_REPLY = -1

        // bc_state
        const val STATE_IDLE = 0
        const val STATE_LISTENING = 1
        const val STATE_THINKING = 2
        const val STATE_SPEAKING = 3
        private val STATE_NAMES = arrayOf("idle", "listening", "thinking", "speaking")

        // bc_event_kind
        const val EVENT_STATE_CHANGE = 0
        const val EVENT_USER_PARTIAL = 1
        const val EVENT_USER_FINAL = 2
        const val EVENT_BOT_CHUNK = 3
        const val EVENT_BOT_TURN_END = 4
        const val EVENT_BARGE_IN = 5

        private val EMPTY_END = FloatArray(0)

        /**
         * Load every model (seconds — call off the main thread). Throws with the missing
         * piece named. Layout: see [BrainAssets].
         */
        fun create(cfg: Config, listener: Listener): ConverseEngine {
            val t0 = SystemClock.elapsedRealtime()
            val st = cfg.supertonicDir
            fun need(p: String): String { require(File(p).isFile) { "missing brain asset: $p" }; return p }
            val tts = OfflineTts(config = OfflineTtsConfig(model = OfflineTtsModelConfig(
                supertonic = OfflineTtsSupertonicModelConfig(
                    durationPredictor = need(supertonicGraph(st, "duration_predictor")),
                    textEncoder = need(supertonicGraph(st, "text_encoder")),
                    vectorEstimator = need(supertonicGraph(st, "vector_estimator")),
                    vocoder = need(supertonicGraph(st, "vocoder")),
                    ttsJson = need("$st/tts.json"),
                    unicodeIndexer = need("$st/unicode_indexer.bin"),
                    voiceStyle = need("$st/voice.bin"),
                ), numThreads = cfg.ttsThreads)))
            val t1 = SystemClock.elapsedRealtime()
            val sd = cfg.sttDir
            val vadPath = File(sd, "silero_vad.onnx").takeIf { it.isFile } ?: File(File(sd).parentFile, "silero_vad.onnx")
            val vad = Vad(config = VadModelConfig(sileroVadModelConfig = SileroVadModelConfig(
                model = need(vadPath.path), threshold = 0.5f,
                minSilenceDuration = cfg.minSilenceMs / 1000f, minSpeechDuration = 0.2f,
                windowSize = 512, maxSpeechDuration = 20f), sampleRate = INPUT_SAMPLE_RATE, numThreads = 1))
            val speechIn = SpeechIn.detect(sd, cfg.sttThreads)
            val asr = OfflineRecognizer(config = speechIn.config)
            val t2 = SystemClock.elapsedRealtime()
            val llm = cfg.replyModel?.invoke(cfg)
                ?: LlamaBrain.load(need(cfg.llmPath), cfg.llmContext, cfg.llmThreads, cfg.llmThreads)
                ?: error("the LLM did not load: ${cfg.llmPath}")
            val t3 = SystemClock.elapsedRealtime()
            Log.i(TAG, "[bhbrain] loaded tts=${t1 - t0}ms stt=${t2 - t1}ms llm=${t3 - t2}ms total=${t3 - t0}ms " +
                "stt=${speechIn.kind}:${File(sd).name} reply=${llm.javaClass.simpleName} " +
                "voice=${cfg.voice} steps=${cfg.ttsSteps} ttsThreads=${cfg.ttsThreads} " +
                "ve=${File(supertonicGraph(st, "vector_estimator")).name} voc=${File(supertonicGraph(st, "vocoder")).name} " +
                "chunks=${cfg.firstChunkMinWords}w/${cfg.clauseChunks}/floor${cfg.firstChunkFloorWords} ttsRate=${tts.sampleRate()} speakers=${tts.numSpeakers()}")
            return ConverseEngine(cfg, listener, llm, tts, vad, asr)
        }

        /**
         * Supertonic's thread count. Galaxy Z Flip5, int8 graphs: headless 2 and 4 threads are equal (an
         * 8-line bench), and UNDER THE AVATAR 4 threads were slower for the voice and the mouth both
         * (2026-10-04, CPU contention with the engines) — so 2.
         */
        const val TTS_THREADS = 2

        /** [Config.firstChunkFloorWords]'s default (Android): no 1-3 word first chunk. */
        const val FIRST_CHUNK_FLOOR_WORDS = 4

        /**
         * One Supertonic graph in [dir]: `<name>.onnx` (full precision — the original fp32 graph, or the
         * half-precision STORAGE build libconverse downloads on Apple, which ONNX Runtime widens back to
         * fp32 at load) when the directory holds it, else sherpa-onnx's `<name>.int8.onnx`. sherpa-onnx's
         * int8 release quantizes only two of the four graphs (vector_estimator weight-only, vocoder QDQ);
         * its duration_predictor and text_encoder ARE the fp32 originals, byte for byte.
         */
        fun supertonicGraph(dir: String, name: String): String =
            File(dir, "$name.onnx").takeIf { it.isFile }?.path ?: "$dir/$name.int8.onnx"

        /** Supertonic ships its voices sorted F1..F5, M1..M5 in one voice.bin. */
        fun voiceToSid(voice: String, speakers: Int): Int {
            val names = listOf("F1", "F2", "F3", "F4", "F5", "M1", "M2", "M3", "M4", "M5")
            val i = names.indexOf(voice.uppercase())
            return if (i in 0 until speakers) i else if (speakers > 5) 5 else 0
        }

        fun wordCount(s: String) = s.split(Regex("\\s+")).count { it.any(Char::isLetterOrDigit) }

        private fun dbfs(x: FloatArray): Double {
            var s = 0.0
            for (v in x) s += v * v
            val rms = sqrt(s / maxOf(1, x.size))
            return 20 * Math.log10(maxOf(rms, 1e-9))
        }
    }
}
