package ai.bithuman.flutter

import android.content.Context
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.util.Log

/**
 * Microphone -> 24 kHz PCM16 chunks, echo-cancelled and HALF-DUPLEX against the
 * avatar's own voice. Adopted from the Android chat example's `micLoop` (mobile-SDK
 * lane, 2026-09-15) with the capture moved behind a callback so the Flutter side can
 * forward the chunks over its mic EventChannel exactly as iOS does.
 *
 * The rules it carries, each measured on a Galaxy S25+ before it was written down:
 *
 *  - VOICE_COMMUNICATION is the source the platform runs its echo canceller on —
 *    without it the agent hears itself through the speaker and interrupts its own reply.
 *
 *  - ★ THE MICROPHONE IS MUTED WHILE THE AGENT IS AUDIBLE, plus a tail. Without this
 *    the demo talks to itself: the agent's own voice reached the microphone at
 *    speakerphone volume, the platform canceller did not hold, the uplink transcribed
 *    it as the USER and the server answered it. Forever, and on the meter. An energy
 *    gate was tried first and did not hold — the speaker's leakage is louder than any
 *    threshold that still passes a voice.
 *
 *  - SILENCE IS SENT, NOT NOTHING. Dropping chunks leaves a hole in the uplink and the
 *    resumption reads to the server's turn detector as an onset (measured: a second
 *    unprompted turn 10 s after the first). A continuous stream of zeros gives the
 *    detector a floor and no edge.
 *
 *  The stated cost: interrupting the agent BY VOICE mid-sentence does not work on
 *  this path. Typing does.
 */
class MicCapture(
    private val context: Context,
    /** True while the avatar's speaker is (about to be) audible; see AvatarPlayer.speakingRecently. */
    private val speaking: () -> Boolean,
    /** One chunk of 24 kHz PCM16 mono, valid for `n` bytes. Called on the capture thread. */
    private val onChunk: (ByteArray, Int) -> Unit,
) {
    @Volatile private var live = false
    private var record: AudioRecord? = null
    private var aec: AcousticEchoCanceler? = null
    private var thread: Thread? = null

    /** Blocks nothing; the capture runs on its own thread until [stop]. Returns false if the mic did not open. */
    fun start(): Boolean {
        val minBuf = AudioRecord.getMinBufferSize(RATE_IN, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val r = try {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_COMMUNICATION, RATE_IN,
                AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, maxOf(minBuf, RATE_IN)
            )
        } catch (t: Throwable) {
            Log.w(TAG, "the microphone did not open: ${t.message}"); return false
        }
        if (r.state != AudioRecord.STATE_INITIALIZED) { Log.w(TAG, "the microphone did not open"); return false }
        record = r
        val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        @Suppress("DEPRECATION") am.isSpeakerphoneOn = true
        if (AcousticEchoCanceler.isAvailable()) {
            aec = AcousticEchoCanceler.create(r.audioSessionId)?.apply { enabled = true }
        }
        r.startRecording()
        live = true
        thread = Thread({ loop(r) }, "bh-mic").also { it.start() }
        return true
    }

    fun stop() {
        live = false
        runCatching { record?.stop(); record?.release() }; record = null
        runCatching { aec?.release() }; aec = null
        thread = null
    }

    private fun loop(r: AudioRecord) {
        var muted = 0
        val inBuf = ShortArray(RATE_IN / 10)      // 100 ms
        val outBuf = ByteArray(inBuf.size)        // half as many samples, two bytes each
        while (live) {
            val n = r.read(inBuf, 0, inBuf.size)
            if (n <= 0) continue
            // 48 kHz -> 24 kHz: average each pair, which decimates and low-passes at once.
            var o = 0
            var i = 0
            while (i + 1 < n) {
                val v = (inBuf[i] + inBuf[i + 1]) / 2
                outBuf[o++] = (v and 0xFF).toByte()
                outBuf[o++] = ((v shr 8) and 0xFF).toByte()
                i += 2
            }
            if (speaking()) {
                java.util.Arrays.fill(outBuf, 0, o, 0)
                muted++
                if (muted % 50 == 1) Log.i("bhecho", "mic muted while the agent is audible ($muted chunks so far)")
            }
            onChunk(outBuf, o)
        }
    }

    companion object {
        private const val TAG = "BithumanAvatar"
        /** The device rate captured; decimated by two on the way out. */
        const val RATE_IN = 48_000
        /** How long after the last speech write the microphone stays muted. */
        const val MIC_MUTE_TAIL_MS = 1000L
    }
}
