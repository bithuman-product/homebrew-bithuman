package ai.bithuman.flutter.brain

import kotlin.math.abs

/**
 * Leading-silence trim for synthesized speech — the same rule as libconverse's
 * `audio_trim.hpp` on Apple.
 *
 * Supertonic opens EVERY synthesis with 350-560 ms of near-digital silence (floor ~1e-5), and
 * no model or runtime parameter controls it. A listener hears it before the first word of a
 * reply and again at every chunk boundary, and a talking-head avatar renders it as a closed
 * mouth — so the avatar's first reply frame arrives ~0.4 s before anything can be heard.
 * Cut it to a short pre-roll.
 */
internal object AudioTrim {
    /** -54 dBFS: ~200x the synthesis floor, below the softest measured onsets ("h", "f"). */
    const val THRESHOLD = 0.002f

    /**
     * Removes the head of [pcm] up to [keepMs] before the first sample whose magnitude exceeds
     * [threshold], then fades the first [fadeMs] of what is left in from zero (the pre-roll is
     * near-silence; the fade only guards against a click). A fully silent buffer, or one whose
     * sound starts within [keepMs], is returned as is. Returns the buffer and the samples cut.
     */
    fun trimLeadingSilence(pcm: FloatArray, sampleRate: Int, threshold: Float = THRESHOLD,
                           keepMs: Int = 30, fadeMs: Int = 5): Pair<FloatArray, Int> {
        val onset = leadSamples(pcm, threshold)
        if (onset >= pcm.size) return pcm to 0
        val keep = sampleRate * keepMs / 1000
        val cut = if (onset > keep) onset - keep else 0
        if (cut == 0) return pcm to 0
        val out = pcm.copyOfRange(cut, pcm.size)
        val fade = minOf(out.size, sampleRate * fadeMs / 1000)
        for (i in 0 until fade) out[i] *= i.toFloat() / fade
        return out to cut
    }

    /** Samples before the first one above [threshold] (= size when none is). */
    fun leadSamples(pcm: FloatArray, threshold: Float = THRESHOLD): Int {
        var i = 0
        while (i < pcm.size && abs(pcm[i]) <= threshold) i++
        return i
    }
}
