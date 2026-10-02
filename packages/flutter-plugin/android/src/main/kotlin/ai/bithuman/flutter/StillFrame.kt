// A still for an engine with no idle clip (2.6.33). An Expression 2 character published without its
// idle clip (its manifest did not list idle.mp4) installs no idle member: `Expression2Avatar.idleLoop`
// is null and `idleLoopUnavailableReason` says why. The player shows idle frames until a reply's first
// frame, and with none to show it showed NOTHING — no first frame, so `ready` never came, the app never
// dialled, and the screen stayed blank (Chef Waddles on a Galaxy Z Flip5, 2026-10-02). Now the adapter
// renders one frame from a moment of silence, keeps it, and shows it as a one-frame idle clip: the
// character appears and can talk. Free of Android (the frame type is generic): StillFrameTest.
package ai.bithuman.flutter

/** What [StillFrame] needs of an engine: silence in, one frame out, then a clean stream again. */
interface StillSource<F> {
    /** A reply is being rendered (audio fed or frames queued): not the moment to feed silence. */
    val busy: Boolean
    fun feedSilence(samples16k: Int)
    /** Render what was fed, now (the engine's end-of-utterance). */
    fun flush()
    /** The next rendered frame, or null when none is ready yet. */
    fun pull(): F?
    /** Drop anything left and restart the sample count, so the first reply starts at 0. */
    fun reset()
}

class StillFrame<F>(
    private val source: StillSource<F>,
    private val log: (String) -> Unit,
    private val clock: () -> Long = System::currentTimeMillis,
    private val sleep: (Long) -> Unit = { Thread.sleep(it) },
    /** Silence fed for the still: 0.32 s, a few frames at 20 fps. */
    private val silenceSamples: Int = 5_120,
    /** How long one attempt waits for the frame. */
    private val timeoutMs: Long = 3_000,
    /** A failed attempt is not repeated sooner than this (the presenter asks every few ms). */
    private val retryMs: Long = 1_000,
) {
    @Volatile var frame: F? = null; private set
    var attempts = 0; private set
    private var lastTry = Long.MIN_VALUE

    /** The still, rendering it on the first call (and again, at most once per [retryMs], until one comes). */
    fun get(): F? {
        frame?.let { return it }
        val now = clock()
        if (lastTry != Long.MIN_VALUE && now - lastTry < retryMs) return null
        lastTry = now
        if (source.busy) return null
        attempts++
        val f = try { render() } catch (t: Throwable) { log("still frame: the render failed (${t.message}); retrying"); null }
        lastTry = clock()                    // the retry interval runs from the end of the attempt
        if (f != null) { frame = f; log("still frame shown in place of the idle clip (attempt $attempts)") }
        return f
    }

    private fun render(): F? {
        source.feedSilence(silenceSamples)
        source.flush()
        val until = clock() + timeoutMs
        var got: F? = null
        try {
            while (got == null && clock() < until) {
                got = source.pull()
                if (got == null) sleep(10)
            }
        } finally {
            source.reset()
        }
        if (got == null) log("still frame: no frame within ${timeoutMs} ms; retrying")
        return got
    }
}
