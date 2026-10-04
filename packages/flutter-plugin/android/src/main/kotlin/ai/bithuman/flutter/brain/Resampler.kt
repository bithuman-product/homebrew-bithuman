package ai.bithuman.flutter.brain

import kotlin.math.cos
import kotlin.math.sin

/**
 * Band-limited rational sample-rate conversion for mono float audio: a polyphase
 * windowed-sinc (Blackman, 2*[half] taps per output sample, cutoff just under the lower
 * Nyquist), with every phase's taps precomputed so the hot loop is multiply-adds only.
 * Used twice by the brain: Supertonic's 44.1 kHz voice -> the 24 kHz the avatar player
 * takes (80 phases), and the 24 kHz microphone -> the 16 kHz the VAD and recognizer
 * take (2 phases). Each call converts one whole buffer (a sentence, a mic chunk); the
 * edges are zero-padded, which is inaudible at those sizes.
 */
internal class Resampler(inRate: Int, outRate: Int, private val half: Int = 16) {
    private val up: Int
    private val down: Int
    private val table: Array<FloatArray>   // [phase][2*half]

    init {
        val g = gcd(inRate, outRate)
        up = outRate / g; down = inRate / g
        val cutoff = 0.92 * minOf(1.0, outRate.toDouble() / inRate)
        table = Array(up) { p ->
            val frac = p.toDouble() / up
            val w = FloatArray(2 * half)
            var sum = 0.0
            val tmp = DoubleArray(2 * half)
            for (j in -half until half) {
                val d = frac + j                                 // distance from the tap to x
                val t = d * cutoff
                val sinc = if (t == 0.0) 1.0 else sin(Math.PI * t) / (Math.PI * t)
                val u = (d + half) / (2.0 * half)
                val win = if (u <= 0.0 || u >= 1.0) 0.0 else 0.42 - 0.5 * cos(2 * Math.PI * u) + 0.08 * cos(4 * Math.PI * u)
                tmp[j + half] = sinc * win; sum += sinc * win
            }
            for (k in w.indices) w[k] = (tmp[k] / sum).toFloat()
            w
        }
    }

    fun process(input: FloatArray, n: Int = input.size): FloatArray {
        if (up == down) return input.copyOf(n)
        val outN = ((n.toLong() * up) / down).toInt()
        val out = FloatArray(outN)
        for (i in 0 until outN) {
            val num = i.toLong() * down
            val c = (num / up).toInt()
            val w = table[(num % up).toInt()]
            var acc = 0f
            // tap j (-half..half-1) sits at input index c - j
            var idx = c + half
            for (k in 0 until 2 * half) {
                if (idx in 0 until n) acc += input[idx] * w[k]
                idx--
            }
            out[i] = acc
        }
        return out
    }

    companion object {
        private tailrec fun gcd(a: Int, b: Int): Int = if (b == 0) a else gcd(b, a % b)

        fun pcm16ToFloat(b: ByteArray, n: Int = b.size): FloatArray {
            val out = FloatArray(n / 2)
            for (i in out.indices) {
                val v = ((b[2 * i + 1].toInt() shl 8) or (b[2 * i].toInt() and 0xFF)).toShort()
                out[i] = v / 32768f
            }
            return out
        }

        fun floatToPcm16(f: FloatArray, n: Int = f.size): ByteArray {
            val out = ByteArray(n * 2)
            for (i in 0 until n) {
                val v = (f[i] * 32767f).toInt().coerceIn(-32768, 32767)
                out[2 * i] = (v and 0xFF).toByte()
                out[2 * i + 1] = ((v shr 8) and 0xFF).toByte()
            }
            return out
        }
    }
}
