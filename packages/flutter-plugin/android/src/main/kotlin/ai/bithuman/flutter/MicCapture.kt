package ai.bithuman.flutter

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.os.Build
import android.util.Log

/**
 * Microphone -> 24 kHz PCM16 chunks, continuous for the life of the session, on the
 * platform's COMMUNICATION path so its echo canceller runs against the avatar's own
 * voice. The Flutter side forwards the chunks over its mic EventChannel exactly as
 * iOS does; the server's turn detector (server_vad) hears the user start and the
 * session cancels the reply — that is the whole interruption path, and it only
 * exists if the microphone is open while the agent talks.
 *
 * What the platform needs from us for the canceller to hold, each measured on a
 * Galaxy S25+ (2026-09-15):
 *
 *  - Source VOICE_COMMUNICATION, and the speaker on USAGE_VOICE_COMMUNICATION
 *    (AvatarPlayer): both ends on the comm stream, or there is no reference signal.
 *
 *  - ★ AudioManager.MODE_IN_COMMUNICATION while the microphone is open. This is what
 *    engages the HAL's tuned canceller on Samsung (WebRTC and every VoIP app set it);
 *    in MODE_NORMAL the residual of the agent's own voice at speakerphone volume
 *    reached the uplink, the server transcribed it as the USER and answered it, and
 *    the earlier fix for that was to ZERO THE MICROPHONE WHILE THE AGENT WAS AUDIBLE
 *    (+1 s tail). That mute was the interruption defect: the user could never be
 *    heard over the agent, so `speech_started` never fired (0 in a 5-minute owner
 *    session). The mode is restored on [stop].
 *
 *  - SILENCE IS SENT, NOT NOTHING. Dropping chunks leaves a hole in the uplink and the
 *    resumption reads to the server's turn detector as an onset. The stream is
 *    continuous at 10 chunks/s; the `bhmic` line every second carries the running
 *    count, so a gap is visible as a count that did not advance by 10.
 */
class MicCapture(
    private val context: Context,
    /** One chunk of 24 kHz PCM16 mono, valid for `n` bytes. Called on the capture thread. */
    private val onChunk: (ByteArray, Int) -> Unit,
) {
    @Volatile private var live = false
    private var record: AudioRecord? = null
    private var aec: AcousticEchoCanceler? = null
    private var thread: Thread? = null
    private var modeBefore = AudioManager.MODE_NORMAL

    /** Blocks nothing; the capture runs on its own thread until [stop]. Returns false if the mic did not open. */
    fun start(): Boolean {
        val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        modeBefore = am.mode
        am.mode = AudioManager.MODE_IN_COMMUNICATION
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val speaker = am.availableCommunicationDevices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
            if (speaker == null || !am.setCommunicationDevice(speaker)) Log.w(TAG, "speakerphone not selected")
        } else {
            @Suppress("DEPRECATION") am.isSpeakerphoneOn = true
        }
        val minBuf = AudioRecord.getMinBufferSize(RATE_IN, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val r = try {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_COMMUNICATION, RATE_IN,
                AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, maxOf(minBuf, RATE_IN)
            )
        } catch (t: Throwable) {
            Log.w(TAG, "the microphone did not open: ${t.message}"); restoreMode(am); return false
        }
        if (r.state != AudioRecord.STATE_INITIALIZED) { Log.w(TAG, "the microphone did not open"); restoreMode(am); return false }
        record = r
        if (AcousticEchoCanceler.isAvailable()) {
            aec = AcousticEchoCanceler.create(r.audioSessionId)?.apply { enabled = true }
        }
        r.startRecording()
        live = true
        Log.i("bhmic", "OPEN source=VOICE_COMMUNICATION mode=${am.mode} device=${r.routedDevice?.type} " +
            "aec=${aec?.enabled} rateIn=$RATE_IN chunkMs=100 hostMs=${System.currentTimeMillis()}")
        thread = Thread({ loop(r) }, "bh-mic").also { it.start() }
        return true
    }

    fun stop() {
        live = false
        runCatching { record?.stop(); record?.release() }; record = null
        runCatching { aec?.release() }; aec = null
        thread = null
        restoreMode(context.getSystemService(Context.AUDIO_SERVICE) as AudioManager)
    }

    private fun restoreMode(am: AudioManager) {
        runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                am.clearCommunicationDevice()
            } else {
                @Suppress("DEPRECATION")
                am.isSpeakerphoneOn = false
            }
            am.mode = modeBefore
        }
    }

    private fun loop(r: AudioRecord) {
        val inBuf = ShortArray(RATE_IN / 10)      // 100 ms
        val outBuf = ByteArray(inBuf.size)        // half as many samples, two bytes each
        var chunks = 0L
        var peak = 0
        var sumSq = 0.0
        var nSq = 0L
        while (live) {
            val n = r.read(inBuf, 0, inBuf.size)
            if (n <= 0) continue
            // 48 kHz -> 24 kHz: average each pair, which decimates and low-passes at once.
            var o = 0
            var i = 0
            while (i + 1 < n) {
                val v = (inBuf[i] + inBuf[i + 1]) / 2
                val a = if (v < 0) -v else v
                if (a > peak) peak = a
                sumSq += v.toDouble() * v; nSq++
                outBuf[o++] = (v and 0xFF).toByte()
                outBuf[o++] = ((v shr 8) and 0xFF).toByte()
                i += 2
            }
            onChunk(outBuf, o)
            // One line per second: the count proves the stream is continuous (10/s), the
            // peak is the loudest sample of the last second (the agent's residual, the room).
            if (++chunks % 10 == 0L) {
                val rms = Math.sqrt(sumSq / maxOf(1L, nSq))
                Log.i("bhmic", "chunks=$chunks peak1s=$peak rms1s=${rms.toInt()} dbfs=%.1f hostMs=${System.currentTimeMillis()}"
                    .format(20 * Math.log10(maxOf(rms, 1.0) / 32768.0)))
                peak = 0; sumSq = 0.0; nSq = 0L
            }
        }
    }

    companion object {
        private const val TAG = "BithumanAvatar"
        /** The device rate captured; decimated by two on the way out. */
        const val RATE_IN = 48_000
    }
}
