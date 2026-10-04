package ai.bithuman.flutter

/**
 * The speech presenter's starvation episodes (`bhstarve`, and `starve=` on the per-second `PROD` line).
 *
 * A starve is the ready-frame queue standing EMPTY while the engine still has an utterance to finish: the
 * picture holds its last frame until frames come back. Until now every empty pull after a good one counted,
 * however short. expression2-android 0.6.0 publishes a block's frames one at a time, so the queue reads
 * empty for 2-8 ms between two publishes of the same block. Nothing is held long enough to see, but each
 * gap counted as a starve. 10x Efficiency's A/B (2026-10-04) showed equal frame coverage against 0.5.2;
 * the extra starves were these sub-frame publish gaps, while the real holds last ~200-550 ms.
 *
 * So an episode counts only when the queue stays empty for at least [MIN_HOLD_MS] before frames come back
 * ([refill]). A shorter gap is not a starve: the caller logs it at debug level only. A hold that never
 * refills (the queue still empty when the presenter stops or closes: a real freeze) is closed by [close]
 * and counts the same way.
 * Plain JVM: no Android imports (StarveCounterTest).
 */
internal class StarveCounter(private val minHoldMs: Long = MIN_HOLD_MS) {
    /** Starves so far: empty-queue holds of at least [minHoldMs]. */
    @Volatile var count = 0
        private set

    /** When the open hold began (ms), or -1 when the queue is not standing empty. */
    var emptySince = -1L
        private set

    /** The ready queue went empty while the engine still has an utterance to finish (the first empty pull). */
    fun empty(nowMs: Long) {
        if (emptySince < 0) emptySince = nowMs
    }

    /** Frames came back. Returns the hold just closed (null when none was open), counted when it was long enough. */
    fun refill(nowMs: Long): Hold? {
        if (emptySince < 0) return null
        val ms = (nowMs - emptySince).coerceAtLeast(0)
        emptySince = -1L
        val counted = ms >= minHoldMs
        if (counted) count++
        return Hold(ms, counted)
    }

    /**
     * The presenter stops or closes: an open hold ends here without frames coming back (a freeze until the
     * end). Returns it (null when none was open), counted when it lasted at least [minHoldMs].
     */
    fun close(nowMs: Long): Hold? = refill(nowMs)

    /** One closed hold: how long the queue stood empty, and whether that was a starve. */
    data class Hold(val ms: Long, val counted: Boolean)

    companion object {
        /**
         * The shortest empty-queue hold that counts as a starve. 0.6.0's publish gaps are 2-8 ms (invisible);
         * the holds a viewer sees are ~200-550 ms. 50 ms is three frames at 60 fps and longer than any
         * publish gap measured.
         */
        const val MIN_HOLD_MS = 50L
    }
}
