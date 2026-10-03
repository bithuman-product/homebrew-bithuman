// pushAudio's 16 kHz -> 24 kHz conversion (Pcm16kTo24k.kt). Plain JVM, no device.
//
// Run from any Flutter app that depends on this plugin:
//   packages/flutter-plugin/scripts/test_android_unit.sh <app dir>

package ai.bithuman.flutter

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class Pcm16kTo24kTest {

    private fun le(vararg s: Int): ByteArray {
        val b = ByteArray(s.size * 2)
        s.forEachIndexed { k, v -> b[2 * k] = (v and 0xFF).toByte(); b[2 * k + 1] = ((v shr 8) and 0xFF).toByte() }
        return b
    }

    private fun samples(b: ByteArray): IntArray =
        IntArray(b.size / 2) { k -> ((b[2 * k + 1].toInt() shl 8) or (b[2 * k].toInt() and 0xFF)).toShort().toInt() }

    @Test fun twentyMilliseconds_becomeTwentyMillisecondsAt24k() {
        val c = Pcm16kTo24k()
        val out = c.process(ByteArray(320 * 2)) + c.flush()   // 320 samples = 20 ms at 16 kHz
        assertEquals(480, out.size / 2)                          // 480 samples = 20 ms at 24 kHz
    }

    @Test fun aRamp_isInterpolatedLinearly() {
        val c = Pcm16kTo24k()
        // Input 0, 300, 600, 900 at positions 0..3; outputs sit at 0, 2/3, 4/3, 2, 8/3, 10/3.
        val out = samples(c.process(le(0, 300, 600, 900)) + c.flush())
        assertArrayEquals(intArrayOf(0, 200, 400, 600, 800, 900), out)
    }

    @Test fun negativeSamples_keepTheirSign() {
        val c = Pcm16kTo24k()
        val out = samples(c.process(le(-30000, -29700, -29400)) + c.flush())
        assertArrayEquals(intArrayOf(-30000, -29800, -29600, -29400, -29400), out)
    }

    /** A stream cut at any byte gives the same samples as the stream converted whole. */
    @Test fun chunking_doesNotChangeTheOutput() {
        val input = le(*IntArray(997) { k -> ((k * 7919) % 65536) - 32768 })
        val whole = Pcm16kTo24k().let { it.process(input) + it.flush() }
        for (cut in intArrayOf(1, 2, 3, 5, 7, 64, 641)) {
            val c = Pcm16kTo24k()
            var out = ByteArray(0)
            var i = 0
            while (i < input.size) {
                val end = minOf(input.size, i + cut)
                out += c.process(input.copyOfRange(i, end))
                i = end
            }
            out += c.flush()
            assertArrayEquals("chunks of $cut bytes", whole, out)
        }
    }

    @Test fun reset_dropsTheCarriedTail() {
        val c = Pcm16kTo24k()
        c.process(le(1000, 2000))          // fewer than three samples: all carried
        c.reset()
        assertEquals(0, c.flush().size)
        assertArrayEquals(intArrayOf(5, 5), samples(c.process(le(5)) + c.flush()))
    }

    @Test fun anEmptyChunk_isHarmless() {
        val c = Pcm16kTo24k()
        assertEquals(0, c.process(ByteArray(0)).size)
        assertEquals(0, c.flush().size)
    }
}
