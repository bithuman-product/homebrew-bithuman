// Off screen means no polling (2.6.37). Nothing here imports Android or Flutter, so the rules run on
// a plain JVM (src/test/kotlin/ai/bithuman/flutter/OffScreenTest.kt); BithumanPlugin feeds
// [AppVisibility.process] from ProcessLifecycleOwner.
//
// ★WHY. From essence2-android 0.9.5 and expression2-android 0.6.1 a session whose app has been in the
// background for 60 s ends (billed to that 60 s), and until the app is visible again every frame call
// answers "no frame": `Expression2IdleLoop.next` returns -1, `pull` null; essence-2's `idle` / `pull`
// false and its hardware-buffer calls null. The player took that for a late frame and asked again:
//   - the producer every 2 ms on an idle -1 (up to ~500 wake-ups a second),
//   - the feed thread's 4 ms empty-inbox poll (~250 a second, in the background too),
//   - the writer's 1 ms empty-queue poll once the producer had nothing to hand it (up to ~1,000),
//   - essence-2's render thread every 2 ms with no utterance open, with its ready queue full, or on a
//     refused pull,
// for as long as the app stayed in the background. That is a phone in a pocket burning its battery
// on a character nobody can see.
//
// Two rules, each sufficient on its own:
//   1. OFF SCREEN, NOTHING TO SAY: the threads wait on a monitor ([ParkSpot]) — no timer, no
//      polling — until the app is visible again, the session hands over audio (a reply that
//      arrives in the background still plays), or the player stops.
//   2. A REFUSED FRAME IS ASKED FOR AGAIN LATER AND LATER ([RefusalBackoff]): on screen the 2 ms
//      cadence stands for the first second of refusals (a late frame on screen is normal and the
//      cadence is what keeps the picture with its voice); after that, or at once off screen, the
//      wait doubles up to 256 ms, until a frame arrives or the app comes back.

package ai.bithuman.flutter

import java.util.concurrent.CopyOnWriteArrayList

/**
 * Whether the app is on screen. The plugin sets [process] from the process lifecycle (ON_START /
 * ON_STOP); until it says otherwise the app counts as visible, so a host without that signal
 * behaves as before 2.6.37. Listeners run on the thread that calls [set] (the main thread) and must
 * be quick: they only wake waiting threads.
 */
class AppVisibility(initial: Boolean = true) {
    @Volatile var visible: Boolean = initial
        private set
    /** System.currentTimeMillis() of the last change (0: never changed). */
    @Volatile var changedAtMs: Long = 0L
        private set
    private val listeners = CopyOnWriteArrayList<(Boolean) -> Unit>()

    /** A change is told to every listener once; setting the current value again does nothing. */
    fun set(v: Boolean, nowMs: Long = System.currentTimeMillis()) {
        synchronized(this) {
            if (visible == v) return
            visible = v
            changedAtMs = nowMs
        }
        for (l in listeners) runCatching { l(v) }
    }

    /** Adds [l]; the returned function removes it. */
    fun listen(l: (Boolean) -> Unit): () -> Unit {
        listeners.add(l)
        return { listeners.remove(l) }
    }

    val listenerCount: Int get() = listeners.size

    companion object {
        /** The process's own: one app, one screen. */
        val process = AppVisibility()
    }
}

/**
 * Where a thread waits instead of polling: [await] blocks until its condition stops holding and
 * someone calls [wake]; [pause] is a timed wait that [wake] ends early. Every state change a waiter
 * depends on is followed by [wake], so a waiter never needs to look again on a timer; the long
 * [await] timeout is a belt, not a cadence.
 */
class ParkSpot {
    private val lock = Object()
    @Volatile private var waiters = 0
    /** Waits that ended (woken or timed out), for the tests and the log. */
    @Volatile var wakeups = 0L
        private set

    /**
     * Waits while [stay] holds, re-checking it only when woken (or after [maxMs], the belt).
     * Returns the milliseconds spent waiting. [stay] is evaluated under this spot's lock: it must
     * not take a lock that a [wake] caller may hold.
     */
    fun await(maxMs: Long = BELT_MS, stay: () -> Boolean): Long {
        val t0 = System.nanoTime()
        synchronized(lock) {
            waiters++
            try {
                while (stay()) {
                    lock.wait(maxMs)
                    wakeups++
                }
            } finally {
                waiters--
            }
        }
        return (System.nanoTime() - t0) / 1_000_000L
    }

    /** A timed wait of [ms] that [wake] ends early. */
    fun pause(ms: Long) {
        if (ms <= 0) return
        synchronized(lock) {
            waiters++
            try {
                lock.wait(ms)
                wakeups++
            } finally {
                waiters--
            }
        }
    }

    /** Wakes every waiter (they re-check their condition). Cheap when nobody waits. */
    fun wake() {
        if (waiters == 0) return
        synchronized(lock) { lock.notifyAll() }
    }

    /** Wakes every waiter even if one is only about to wait (use after a state change a waiter is checking). */
    fun wakeAll() {
        synchronized(lock) { lock.notifyAll() }
    }

    companion object {
        /** The belt on [await]: one look every 10 s if every wake were lost. */
        const val BELT_MS = 10_000L
    }
}

/**
 * How long to wait before asking an engine for a frame again after it said "no frame".
 *
 * On screen, the first [graceMs] of an unbroken run of refusals keep the [baseMs] cadence the
 * player has always had: a frame not ready yet is normal there, and waiting longer would cost
 * the picture its sync. After the grace, or at once off screen, the wait doubles from [baseMs]
 * up to [capMs] (2, 4, ... 256 ms: at most ~4 asks a second once settled). A frame ([served]) or
 * the app coming back ([reset]) starts over. Thread-safe: the asking thread calls [refused] and
 * [served], the main thread [reset].
 */
class RefusalBackoff(
    val baseMs: Long = BASE_MS,
    val capMs: Long = CAP_MS,
    val graceMs: Long = GRACE_MS,
) {
    private var since = -1L
    private var next = baseMs
    /** Refusals in the current run (0 after [served] / [reset]). */
    @Volatile var refusals = 0L
        private set

    /** The engine said "no frame" at [nowMs]: the wait before asking again. */
    @Synchronized
    fun refused(nowMs: Long, visible: Boolean): Long {
        refusals++
        if (since < 0) { since = nowMs; next = baseMs }
        if (visible && nowMs - since < graceMs) return baseMs
        val d = next
        next = minOf(next * 2, capMs)
        return d
    }

    /** How long the current run of refusals has lasted at [nowMs] (0: none). */
    @Synchronized
    fun refusingForMs(nowMs: Long): Long = if (since < 0) 0L else nowMs - since

    /** A frame arrived. */
    @Synchronized
    fun served() { since = -1L; next = baseMs; refusals = 0 }

    /** The app is visible again: ask at the base cadence at once. */
    @Synchronized
    fun reset() { since = -1L; next = baseMs; refusals = 0 }

    companion object {
        const val BASE_MS = 2L
        const val CAP_MS = 256L
        const val GRACE_MS = 1_000L
    }
}
