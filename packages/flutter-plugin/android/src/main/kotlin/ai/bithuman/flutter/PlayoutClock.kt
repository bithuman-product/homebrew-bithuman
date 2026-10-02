// Skip-ahead (essence2-android 0.9.1): the player tells the engine where the voice is, so a phone
// that renders below real time shows fewer frames in step with the voice instead of a frozen face.
//
// The SDK's contract (`Essence2Avatar.setPlayoutPosition`): the 16 kHz samples of the CURRENT
// utterance — counted from the first sample fed after `resetAudio` — already committed to the
// audio output; any thread; refreshed on every committed unit and at least every ~100 ms while
// speaking; stale after 1 s; forgotten by `resetAudio`; negative = this utterance has not started.
// `lastFrameIndex`, read on the pulling thread right after a pull, names the frame's ordinal in
// the utterance (the frames the SDK skipped are missing from the sequence).
//
// The player counts in a different coordinate: its stream position runs across replies and
// restarts only at a barge-in ([AvatarEngine.reset]). This file is the mapping, kept free of
// Android so it is tested on the JVM (PlayoutClockTest).
package ai.bithuman.flutter

/**
 * The player's committed position, mapped onto the engine's open utterance.
 *
 * ★ITS OWN SMALL LOCK, NEVER THE ADAPTER'S MONITOR. The caller is the player's producer, the loop
 * that keeps the speaker fed; the adapter's monitor is held by a `feed` for as long as the SDK's
 * block compute takes (up to ~200 ms on a handset). A position that waited for that monitor would
 * stall the voice to tell the picture where the voice is. Lock order, everywhere: adapter monitor
 * → [lock] → the SDK's playout lock; nothing calls back the other way, so there is no cycle.
 *
 * [reset] publishes the next utterance's base under [lock] BEFORE the SDK's `resetAudio` runs and
 * holds the clock while it runs: a position computed against the old base can neither reach the
 * new utterance nor land between the SDK forgetting the clock and the new base being in place.
 */
class PlayoutClock(
    /** The SDK's `setPlayoutPosition(samples16k)`. Called under [lock] only. */
    private val target: (Long) -> Unit,
    /** An utterance is open (the adapter's own flag, read without its monitor). */
    private val isOpen: () -> Boolean,
) {
    private val lock = Any()
    /** Stream position (16 kHz, since the last barge-in) where the open utterance began. */
    private var base = 0L
    /** The SDK's `resetAudio` is running: positions are dropped (the reset forgets the clock anyway). */
    private var hold = false
    @Volatile var forwarded = 0L; private set
    @Volatile var dropped = 0L; private set

    /** The player's committed stream position, in 16 kHz samples since the last barge-in. Any thread. */
    fun set(streamSamples16k: Long) {
        synchronized(lock) {
            if (hold || !isOpen()) { dropped++; return }
            target(streamSamples16k - base)
            forwarded++
        }
    }

    /**
     * Runs [resetAudio] (the SDK's) with the clock held, the new utterance's [newBase] already in
     * place. Called by the adapter under its own monitor.
     */
    fun <T> reset(newBase: Long, resetAudio: () -> T): T {
        synchronized(lock) { hold = true; base = newBase }
        try {
            return resetAudio()
        } finally {
            synchronized(lock) { hold = false }
        }
    }

    companion object {
        /**
         * A speech frame's stream position: the utterance's base plus the frame's ordinal times
         * [hop]. The ordinal is the SDK's [sdkIndex] (`lastFrameIndex`) when it names one — with
         * skip-ahead the frames it skipped are missing, and counting would put every later frame
         * that many frames early — else the adapter's own count [delivered] (an engine before 0.9.1).
         */
        fun frameAt(uttBase: Long, sdkIndex: Long, delivered: Long, hop: Long): Long =
            uttBase + (if (sdkIndex >= 0) sdkIndex else delivered) * hop

        /**
         * Idle-cursor steps for a delivered frame: one per ordinal the walk advanced (the frame and
         * every frame skipped before it), whole laps of an [nt]-frame clip left out (they land on
         * the same frame). One where the SDK names no ordinal.
         */
        fun idleSteps(sdkIndex: Long, delivered: Long, nt: Int): Int {
            val n = if (sdkIndex >= 0) maxOf(1L, sdkIndex + 1 - delivered) else 1L
            return if (nt > 0 && n > nt) (n % nt).toInt() else n.toInt()
        }

        /** The ordinal the NEXT frame would have without skipping: one past the frame just delivered. */
        fun nextDelivered(sdkIndex: Long, delivered: Long): Long = if (sdkIndex >= 0) sdkIndex + 1 else delivered + 1
    }
}
