package ai.bithuman.flutter

import ai.bithuman.flutter.brain.ConverseEngine
import ai.bithuman.flutter.brain.HostReplyModel
import ai.bithuman.flutter.brain.Resampler
import android.content.Context
import android.os.Process
import android.os.SystemClock
import android.util.Log
import java.io.File
import kotlin.math.abs

/**
 * LOCAL mode on Android: the on-device brain ([ConverseEngine]) wired to the avatar
 * player and the microphone the cloud path already uses. The Dart side is the same
 * `LocalConverseTransport` that drives Apple's libconverse, over the same channel names
 * and the same events:
 *
 *   mic (MicCapture: VOICE_COMMUNICATION + the platform AEC, 24 kHz) -> 16 kHz -> engine.pushAudio
 *   engine.pullAudio (24 kHz) -> AvatarPlayer.offer — AS FAST AS IT IS PRODUCED, then
 *     AvatarPlayer.endOfReply() the moment the reply's last sample is handed over.
 *     (Measured on Apple, 2026-09-28: pacing the feed to real time kept the avatar waiting on
 *     audio it could already have rendered — ~1 s of the end-of-speech -> mouth budget.
 *     The player presents against the device's own sample clock, so a burst is safe.)
 *   barge-in (the engine's VAD during the bot's audible reply, or a typed turn) ->
 *     AvatarPlayer.bargeIn on the SAME thread that offers audio, after which any chunk
 *     from the cancelled reply is dropped by generation — nothing stale can follow the cut.
 *
 * Events to Dart ({"kind": ...}): loading, ready, error, state(0..3), user, bot,
 * mic_level, bot_level — exactly what `LocalConverseTransport._onEvent` reads — and, with
 * replyMode "host", reply_request {id, messages, maxTokens} / reply_cancel {id}: the app streams
 * the reply text back with `localReplyText` (see [HostReplyModel]).
 */
internal class LocalConverseController(
    private val context: Context,
    /** The session's live player; the plugin swaps it on idle hold/release. */
    private val player: () -> AvatarPlayer?,
    /** Forward one event to Dart (the plugin hops it to the main thread). */
    private val emit: (Map<String, Any?>) -> Unit,
    /** Start the microphone with the plugin's permission flow; null = no mic. */
    private val openMic: ((ByteArray, Int) -> Unit) -> MicCapture?,
) {
    @Volatile private var engine: ConverseEngine? = null
    @Volatile private var running = true
    @Volatile var muted = false
    /** Test driver hook: while true the microphone is ignored (audio is injected via [injectAudio16k]). */
    @Volatile var micBypass = false
    @Volatile private var bargePending: String? = null
    private var mic: MicCapture? = null
    private var pullThread: Thread? = null
    private val mic24to16 = Resampler(24_000, 16_000)
    private var lastMicLevelAt = 0L
    private var lastBotLevelAt = 0L

    /** What `localAudioStart` carries. [replyMode] "host": the app streams the reply text in. */
    data class Options(
        val ggufPath: String = "",
        val supertonicAssets: String? = null,
        /** Speech-to-text model directory; default `stt/` beside the GGUF (or beside the Supertonic dir in host mode). */
        val sttDir: String? = null,
        val voice: String? = null,
        val systemPrompt: String? = null,
        val replyMode: String = "local",
        /** Sentences spoken per reply before the rest is dropped; 0 = the engine's default. */
        val maxSentences: Int = 0,
        val enableMic: Boolean = true,
    )

    @Volatile private var hostReply: HostReplyModel? = null

    /** Load (off the calling thread) and start. Emits loading -> ready | error. */
    fun start(o: Options) {
        emit(mapOf("kind" to "loading"))
        Thread({
            try {
                val host = o.replyMode == "host"
                val a = BrainAssets.resolve(o.ggufPath, o.supertonicAssets, o.sttDir)
                // `debug.bh.brain.keeplead=1` keeps Supertonic's leading silence — a debuggable host only (A/B).
                val debuggable = (context.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0
                val keepLead = debuggable && AvatarPlayer.devInt("debug.bh.brain.keeplead") == 1
                val hr = if (host) HostReplyModel(
                    request = { id, messages, maxTokens -> emit(mapOf("kind" to "reply_request", "id" to id, "maxTokens" to maxTokens,
                        "messages" to messages.map { (r, c) -> mapOf("role" to r, "content" to c) })) },
                    cancelRequest = { id -> emit(mapOf("kind" to "reply_cancel", "id" to id)) }) else null
                hostReply = hr
                var cfg = ConverseEngine.Config(llmPath = a.llm, supertonicDir = a.supertonic, sttDir = a.stt,
                    voice = o.voice ?: "M1", systemPrompt = o.systemPrompt, trimLeadingSilence = !keepLead,
                    // The server owns a house character's persona: send it the conversation only,
                    // unless the app passed a prompt of its own.
                    sendSystemPrompt = !host || !o.systemPrompt.isNullOrBlank(),
                    replyModel = hr?.let { m -> { _: ConverseEngine.Config -> m } })
                if (o.maxSentences > 0) cfg = cfg.copy(maxSentences = o.maxSentences)
                val e = ConverseEngine.create(cfg) { kind, state, text -> onEngineEvent(kind, state, text) }
                if (!running) { e.destroy(); return@Thread }
                engine = e
                pullThread = Thread({ pullLoop(e) }, "bh-brain-pull").also { it.start() }
                if (o.enableMic) mic = openMic { buf, n -> onMic(buf, n) }
                emit(mapOf("kind" to "ready"))
                emit(mapOf("kind" to "state", "state" to e.state()))
            } catch (t: Throwable) {
                Log.e(TAG, "[bhbrain] start failed: $t", t)
                emit(mapOf("kind" to "error", "message" to (t.message ?: t.toString())))
            }
        }, "bh-brain-load").start()
    }

    fun pushText(text: String) {
        val e = engine ?: return
        val s = e.state()
        if (s == ConverseEngine.STATE_THINKING || s == ConverseEngine.STATE_SPEAKING) bargePending = "text"
        e.pushText(text)
    }

    /** replyMode "host": a piece of the reply to `reply_request` [id] (any thread). */
    fun replyText(id: Int, text: String, done: Boolean, result: Int) { hostReply?.push(id, text, done, result) }

    /** Test/driver path: 16 kHz mono float straight into the engine (the mic is bypassed). */
    fun injectAudio16k(pcm: FloatArray) { engine?.pushAudio(pcm) }

    private var injector: Thread? = null
    private val injectQueue = java.util.concurrent.LinkedBlockingQueue<Pair<String, String>>()

    /**
     * Measurement (debuggable hosts only — the plugin checks): play a 16 kHz mono PCM16 WAV into
     * the brain as if it were spoken into the microphone, in real time (32 ms blocks on the wall
     * clock), with digital silence between files as a muted room would give. The microphone is
     * ignored from the first call on. Logs `[bhbrain] inject` lines with the wall-clock time of the
     * file's speech onset and speech end (first / last 10 ms block above -45 dBFS), so the
     * measurement can start its clock at the true end of the user's words.
     */
    fun injectWav(path: String, tag: String) {
        micBypass = true
        injectQueue.offer(path to tag)
        if (injector != null) return
        injector = Thread({
            runCatching { Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO) }
            val block = 512                                          // 32 ms @ 16 kHz
            val silence = FloatArray(block)
            var next = SystemClock.elapsedRealtime()
            while (running) {
                val job = injectQueue.poll()
                if (job == null) {
                    engine?.pushAudio(silence)
                    next += 32; SystemClock.sleep(maxOf(0L, next - SystemClock.elapsedRealtime()))
                    continue
                }
                val pcm = runCatching { readWav16k(job.first) }.getOrElse {
                    Log.e(TAG, "[bhbrain] inject failed ${job.first}: $it"); continue
                }
                val (onset, end) = speechSpan(pcm)
                val startWall = System.currentTimeMillis()
                Log.i(TAG, "[bhbrain] inject start tag=${job.second} file=${File(job.first).name} audioMs=${pcm.size / 16} " +
                    "onsetHostMs=${startWall + onset / 16} speechEndHostMs=${startWall + end / 16} hostMs=$startWall")
                var off = 0
                next = SystemClock.elapsedRealtime()
                while (off < pcm.size && running) {
                    val n = minOf(block, pcm.size - off)
                    engine?.pushAudio(pcm.copyOfRange(off, off + n))
                    off += n
                    next += n / 16
                    SystemClock.sleep(maxOf(0L, next - SystemClock.elapsedRealtime()))
                }
                Log.i(TAG, "[bhbrain] inject end tag=${job.second} hostMs=${System.currentTimeMillis()}")
            }
        }, "bh-brain-inject").also { it.start() }
    }

    fun stop() {
        running = false
        runCatching { mic?.stop() }; mic = null
        runCatching { pullThread?.join(500) }
        engine?.destroy(); engine = null
    }

    // ------------------------------------------------------------------

    private fun onMic(buf: ByteArray, n: Int) {
        val now = SystemClock.elapsedRealtime()
        if (now - lastMicLevelAt >= LEVEL_MS) {
            lastMicLevelAt = now
            emit(mapOf("kind" to "mic_level", "level" to if (muted || micBypass) 0.0 else pcm16Peak(buf, n)))
        }
        if (muted || micBypass) return
        val e = engine ?: return
        e.pushAudio(mic24to16.process(Resampler.pcm16ToFloat(buf, n)))
    }

    private fun onEngineEvent(kind: Int, state: Int, text: String) {
        when (kind) {
            ConverseEngine.EVENT_STATE_CHANGE -> emit(mapOf("kind" to "state", "state" to state))
            ConverseEngine.EVENT_USER_FINAL -> emit(mapOf("kind" to "user", "text" to text))
            ConverseEngine.EVENT_BOT_CHUNK -> emit(mapOf("kind" to "bot", "text" to text))
            ConverseEngine.EVENT_BARGE_IN -> bargePending = "speech_started"
        }
    }

    private fun pullLoop(e: ConverseEngine) {
        runCatching { Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO) }
        val buf = FloatArray(2400)                      // 100 ms @ 24 kHz
        var firstOfReply = true
        while (running) {
            val n = e.pullAudio(buf)
            val gen = e.pulledGen
            bargePending?.let { reason ->
                bargePending = null
                player()?.bargeIn(reason)
                firstOfReply = true
            }
            if (gen != e.currentGen()) continue          // pulled from a reply that was just cut: drop it
            when {
                n > 0 -> {
                    val p = player()
                    if (firstOfReply) {
                        firstOfReply = false
                        p?.noteFirstByte()
                        Log.i(TAG, "[bhbrain] first_offer gen=$gen hostMs=${System.currentTimeMillis()}")
                    }
                    p?.offer(Resampler.floatToPcm16(buf, n))
                    val now = SystemClock.elapsedRealtime()
                    if (now - lastBotLevelAt >= LEVEL_MS) {
                        lastBotLevelAt = now
                        var peak = 0f
                        for (i in 0 until n step 8) { val v = abs(buf[i]); if (v > peak) peak = v }
                        emit(mapOf("kind" to "bot_level", "level" to minOf(1.0, peak.toDouble())))
                    }
                }
                n == ConverseEngine.END_OF_REPLY -> {
                    player()?.endOfReply()
                    firstOfReply = true
                    Log.i(TAG, "[bhbrain] end_of_reply gen=$gen hostMs=${System.currentTimeMillis()}")
                }
                else -> SystemClock.sleep(5)
            }
        }
    }

    private fun pcm16Peak(b: ByteArray, n: Int): Double {
        var peak = 0
        var i = 0
        while (i + 1 < n) {
            val v = abs(((b[i + 1].toInt() shl 8) or (b[i].toInt() and 0xFF)).toShort().toInt())
            if (v > peak) peak = v
            i += 16
        }
        return minOf(1.0, peak / 32768.0)
    }

    companion object {
        private const val TAG = "bhbrain"
        private const val LEVEL_MS = 50L

        /** A PCM16 WAV as 16 kHz mono float (first channel; 24/48 kHz are resampled). */
        fun readWav16k(path: String): FloatArray {
            val b = File(path).readBytes()
            val bb = java.nio.ByteBuffer.wrap(b).order(java.nio.ByteOrder.LITTLE_ENDIAN)
            var pos = 12; var rate = 16000; var ch = 1; var dataOff = -1; var dataLen = 0
            while (pos + 8 <= b.size) {
                val id = String(b, pos, 4, Charsets.US_ASCII); val len = bb.getInt(pos + 4)
                if (id == "fmt ") { ch = bb.getShort(pos + 10).toInt(); rate = bb.getInt(pos + 12) }
                if (id == "data") { dataOff = pos + 8; dataLen = minOf(len, b.size - dataOff); break }
                pos += 8 + len + (len and 1)
            }
            require(dataOff > 0) { "no data chunk" }
            val frames = dataLen / (2 * ch)
            val mono = FloatArray(frames) { i -> bb.getShort(dataOff + i * 2 * ch) / 32768f }
            return if (rate == 16000) mono else Resampler(rate, 16000).process(mono)
        }

        /** First and last sample of the 10 ms blocks above -45 dBFS (the speech span), 16 kHz. */
        fun speechSpan(pcm: FloatArray): Pair<Int, Int> {
            val w = 160; var first = -1; var last = -1
            var i = 0
            while (i + w <= pcm.size) {
                var e = 0.0; for (k in i until i + w) e += pcm[k] * pcm[k]
                if (20 * Math.log10(maxOf(Math.sqrt(e / w), 1e-9)) > -45.0) { if (first < 0) first = i; last = i + w }
                i += w
            }
            return (if (first < 0) 0 else first) to (if (last < 0) pcm.size else last)
        }
    }
}

/**
 * Where the brain's models live on disk. The Dart API carries two paths (the same two
 * Apple's `localAudioStart` takes); the speech-in models sit beside the LLM:
 *
 *   <dir of ggufPath>/<the .gguf>                 the LLM (any llama.cpp chat GGUF)
 *   <supertonicAssets | dir/supertonic>/          Supertonic, sherpa-onnx int8 layout:
 *       duration_predictor.int8.onnx  text_encoder.int8.onnx  vector_estimator.int8.onnx
 *       vocoder.int8.onnx  tts.json  unicode_indexer.bin  voice.bin
 *   <dir of ggufPath>/stt/                        speech in:
 *       silero_vad.onnx  preprocess.onnx  encode.int8.onnx
 *       uncached_decode.int8.onnx  cached_decode.int8.onnx  tokens.txt   (Moonshine)
 */
internal data class BrainAssets(val llm: String, val supertonic: String, val stt: String) {
    companion object {
        fun resolve(ggufPath: String, supertonicAssets: String?, sttDir: String? = null): BrainAssets {
            val st0 = supertonicAssets?.takeIf { it.isNotBlank() }
            // Host mode has no GGUF: the speech-in models then sit beside the Supertonic dir.
            val dir = (if (ggufPath.isNotBlank()) File(ggufPath).parentFile else st0?.let { File(it).parentFile }) ?: File(".")
            val st = st0 ?: File(dir, "supertonic").path
            return BrainAssets(ggufPath, st, sttDir?.takeIf { it.isNotBlank() } ?: File(dir, "stt").path)
        }
    }
}
