// 16 kHz mono PCM16 to 24 kHz, for `pushAudio` on Android (2.6.36).
//
// `BithumanAvatar.pushAudio` takes 16 kHz speech. Until 2.6.36 Android had no `pushAudio` at all (the
// call threw MissingPluginException), and the player plays and lip-syncs 24 kHz PCM16 only
// (`playSpeakerPCM`). The shim converts each chunk here and hands it to the same path, so the speech
// plays AND moves the lips, exactly as it would through `playSpeakerPCM`.
//
// Linear interpolation, 2 samples in -> 3 out. The state carries across chunks (up to two input
// samples and one odd byte), so a stream cut into any chunk sizes gives the same samples as the
// whole stream converted at once. Plain JVM: Pcm16kTo24kTest runs it without a device.

package ai.bithuman.flutter

class Pcm16kTo24k {
    /** Input samples not yet converted (0..2): the next output triple starts at carry[0]. */
    private var carry = ShortArray(0)
    /** The low byte of a sample whose high byte has not arrived yet, or -1. */
    private var oddByte = -1

    /** Convert one chunk of little-endian PCM16 at 16 kHz; returns little-endian PCM16 at 24 kHz. */
    fun process(pcm: ByteArray): ByteArray {
        val x = samples(pcm)
        val n = x.size
        if (n < 3) { carry = x; return ByteArray(0) }
        val out = ShortArray(((n - 1) / 2) * 3)
        var i = 0; var o = 0
        // Output m sits at input position m * 2/3: x[i], x[i + 2/3], x[i + 4/3] for each pair.
        while (i + 2 < n) {
            val a = x[i].toInt(); val b = x[i + 1].toInt(); val c = x[i + 2].toInt()
            out[o++] = a.toShort()
            out[o++] = (a + (b - a) * 2 / 3).toShort()
            out[o++] = (b + (c - b) / 3).toShort()
            i += 2
        }
        carry = x.copyOfRange(i, n)
        return bytes(out, o)
    }

    /** The carried tail (the end of a reply), held at its last sample; then the state is clear. */
    fun flush(): ByteArray {
        val x = carry
        reset()
        return when (x.size) {
            0 -> ByteArray(0)
            1 -> bytes(shortArrayOf(x[0], x[0]), 2)
            else -> {
                val a = x[0].toInt(); val b = x[1].toInt()
                bytes(shortArrayOf(x[0], (a + (b - a) * 2 / 3).toShort(), x[1]), 3)
            }
        }
    }

    /** Drop the carried state (a barge-in, a new audio unit). */
    fun reset() { carry = ShortArray(0); oddByte = -1 }

    private fun samples(pcm: ByteArray): ShortArray {
        val lead = if (oddByte >= 0) 1 else 0
        val total = lead + pcm.size
        val n = total / 2
        val x = ShortArray(carry.size + n)
        carry.copyInto(x)
        fun byteAt(k: Int): Int = if (lead == 1 && k == 0) oddByte else pcm[k - lead].toInt() and 0xFF
        for (s in 0 until n) {
            val lo = byteAt(2 * s); val hi = byteAt(2 * s + 1)
            x[carry.size + s] = ((hi shl 8) or lo).toShort()
        }
        oddByte = if (total % 2 == 1) byteAt(total - 1) else -1
        return x
    }

    private fun bytes(s: ShortArray, count: Int): ByteArray {
        val b = ByteArray(count * 2)
        for (k in 0 until count) {
            val v = s[k].toInt()
            b[2 * k] = (v and 0xFF).toByte()
            b[2 * k + 1] = ((v shr 8) and 0xFF).toByte()
        }
        return b
    }
}
