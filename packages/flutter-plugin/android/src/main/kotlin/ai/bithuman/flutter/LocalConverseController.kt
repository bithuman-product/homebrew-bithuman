package ai.bithuman.flutter

import ai.bithuman.flutter.brain.ConverseEngine
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
 * mic_level, bot_level — exactly what `LocalConverseTransport._onEvent` reads.
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

    /** Load (off the calling thread) and start. Emits loading -> ready | error. */
    fun start(ggufPath: String, supertonicAssets: String?, voice: String?, systemPrompt: String?, enableMic: Boolean) {
        emit(mapOf("kind" to "loading"))
        Thread({
            try {
                val a = BrainAssets.resolve(ggufPath, supertonicAssets)
                val cfg = ConverseEngine.Config(llmPath = a.llm, supertonicDir = a.supertonic, sttDir = a.stt,
                    voice = voice ?: "M1", systemPrompt = systemPrompt)
                val e = ConverseEngine.create(cfg) { kind, state, text -> onEngineEvent(kind, state, text) }
                if (!running) { e.destroy(); return@Thread }
                engine = e
                pullThread = Thread({ pullLoop(e) }, "bh-brain-pull").also { it.start() }
                if (enableMic) mic = openMic { buf, n -> onMic(buf, n) }
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

    /** Test/driver path: 16 kHz mono float straight into the engine (the mic is bypassed). */
    fun injectAudio16k(pcm: FloatArray) { engine?.pushAudio(pcm) }

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
        fun resolve(ggufPath: String, supertonicAssets: String?): BrainAssets {
            val dir = File(ggufPath).parentFile ?: File(".")
            val st = supertonicAssets?.takeIf { it.isNotBlank() } ?: File(dir, "supertonic").path
            return BrainAssets(ggufPath, st, File(dir, "stt").path)
        }
    }
}
