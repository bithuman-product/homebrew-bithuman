// Off screen means no polling (OffScreen.kt, 2.6.37): the app's visibility, the spot a thread waits on,
// and the backoff after a refused frame. The SDKs from essence2-android 0.9.5 / expression2-android 0.6.1
// answer "no frame" for as long as the app stays in the background after their 60 s end; the player
// asked again every 2 ms (~500 a second). These tests drive the same loop shapes against an engine
// that refuses every frame.
//
// Plain JVM, no device:
//   (cd <app>/android && ./gradlew :bithuman:testDebugUnitTest --tests 'ai.bithuman.flutter.OffScreenTest')
// or packages/flutter-plugin/scripts/test_android_unit.sh <app dir>.

package ai.bithuman.flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

class OffScreenTest {
    // ------------------------------------------------------------------ AppVisibility

    @Test
    fun aChangeIsToldOnceToEveryListenerAndAnUnchangedSetIsNot() {
        val v = AppVisibility()
        assertTrue("visible until told otherwise", v.visible)
        val a = ArrayList<Boolean>(); val b = ArrayList<Boolean>()
        val offA = v.listen { a += it }
        v.listen { b += it }
        v.set(true)                       // no change
        v.set(false, nowMs = 5L)
        v.set(false)                      // no change
        v.set(true)
        assertEquals(listOf(false, true), a)
        assertEquals(listOf(false, true), b)
        assertEquals(2, v.listenerCount)
        offA()
        v.set(false)
        assertEquals(listOf(false, true), a)
        assertEquals(listOf(false, true, false), b)
        assertEquals(1, v.listenerCount)
    }

    @Test
    fun aListenerThatThrowsDoesNotStopTheOthers() {
        val v = AppVisibility()
        val seen = AtomicInteger()
        v.listen { throw IllegalStateException("boom") }
        v.listen { seen.incrementAndGet() }
        v.set(false)
        assertEquals(1, seen.get())
        assertFalse(v.visible)
    }

    // ------------------------------------------------------------------ RefusalBackoff

    @Test
    fun onScreenTheBaseCadenceHoldsForTheGraceThenTheWaitDoublesToTheCap() {
        val b = RefusalBackoff()
        var t = 10_000L
        // The first second of refusals on screen: 2 ms, as the player always asked (a late frame is normal).
        while (t < 10_000L + RefusalBackoff.GRACE_MS) {
            assertEquals(RefusalBackoff.BASE_MS, b.refused(t, visible = true)); t += 2
        }
        // Then 2, 4, 8, ... 256 and no further.
        val waits = (0 until 12).map { b.refused(t, visible = true).also { w -> t += w } }
        assertEquals(listOf(2L, 4L, 8L, 16L, 32L, 64L, 128L, 256L, 256L, 256L, 256L, 256L), waits)
        assertTrue("the cap is at least 250 ms", RefusalBackoff.CAP_MS >= 250L)
    }

    @Test
    fun offScreenTheWaitDoublesAtOnce() {
        val b = RefusalBackoff()
        val waits = (0 until 9).map { b.refused(1_000L + it, visible = false) }
        assertEquals(listOf(2L, 4L, 8L, 16L, 32L, 64L, 128L, 256L, 256L), waits)
    }

    @Test
    fun aFrameOrTheAppComingBackStartsOver() {
        val b = RefusalBackoff()
        repeat(10) { b.refused(0L, visible = false) }
        assertEquals(256L, b.refused(0L, visible = false))
        assertEquals(11L, b.refusals)
        b.served()
        assertEquals(0L, b.refusals)
        assertEquals(2L, b.refused(5_000L, visible = false))
        assertEquals(4L, b.refused(5_000L, visible = false))
        b.reset()                         // the app is visible again
        assertEquals("back on screen: the base cadence, a fresh grace", 2L, b.refused(9_000L, visible = true))
        assertEquals(2L, b.refused(9_500L, visible = true))
        assertEquals(500L, b.refusingForMs(9_500L))
        b.served()
        assertEquals(0L, b.refusingForMs(9_600L))
    }

    // ------------------------------------------------------------------ ParkSpot

    @Test
    fun aParkedThreadDoesNotWakeUntilTheAppComesBack() {
        val vis = AppVisibility(initial = false)
        val spot = ParkSpot()
        vis.listen { spot.wakeAll() }
        val passes = AtomicInteger()
        val wokeAt = AtomicLong()
        val running = AtomicBoolean(true)
        val t = Thread {
            while (running.get()) {
                passes.incrementAndGet()
                spot.await { running.get() && !vis.visible }
                if (vis.visible && wokeAt.get() == 0L) wokeAt.set(System.nanoTime())
                if (vis.visible) Thread.sleep(2)
            }
        }.apply { isDaemon = true; start() }
        Thread.sleep(400)
        assertEquals("parked: one pass, no polling", 1, passes.get())
        assertEquals("no wake-up while parked", 0L, spot.wakeups)
        val t0 = System.nanoTime()
        vis.set(true)
        val deadline = System.currentTimeMillis() + 2_000
        while (wokeAt.get() == 0L && System.currentTimeMillis() < deadline) Thread.sleep(1)
        assertTrue("woke on the change", wokeAt.get() != 0L)
        assertTrue("within 100 ms of the app coming back", (wokeAt.get() - t0) / 1_000_000L < 100)
        running.set(false); vis.set(false); spot.wakeAll(); t.join(2_000)
        assertFalse(t.isAlive)
    }

    @Test
    fun aPauseEndsEarlyOnAWake() {
        val spot = ParkSpot()
        val took = AtomicLong(-1)
        val t = Thread { val t0 = System.nanoTime(); spot.pause(5_000); took.set((System.nanoTime() - t0) / 1_000_000L) }
        t.start()
        Thread.sleep(100)
        spot.wake()
        t.join(2_000)
        assertTrue("woken after ~100 ms, not 5 s: ${took.get()} ms", took.get() in 50..1_000)
    }

    // ------------------------------------------------------------------ the loops, against a refusing engine

    /** An engine after the SDK's background end: every ask is answered "no frame". */
    private class RefusingEngine { val asks = AtomicInteger(); fun idle(): Int { asks.incrementAndGet(); return -1 } }

    /** The producer's idle stall as it was through 2.6.36: ask again after 2 ms. */
    private fun oldLoop(e: RefusingEngine, running: () -> Boolean) {
        while (running()) { if (e.idle() < 0) Thread.sleep(2) }
    }

    /** The idle stall from 2.6.37 (AvatarPlayer.produce): the backoff, waited on the producer's spot. */
    private fun newLoop(e: RefusingEngine, vis: AppVisibility, spot: ParkSpot, b: RefusalBackoff, running: () -> Boolean) {
        while (running()) {
            if (e.idle() >= 0) { b.served(); continue }
            val wait = b.refused(System.currentTimeMillis(), vis.visible)
            if (wait <= RefusalBackoff.BASE_MS && vis.visible) Thread.sleep(wait) else spot.pause(wait)
        }
    }

    private fun asksPerSecond(e: RefusingEngine, fromMs: Long, toMs: Long, t0: Long): Double {
        while (System.currentTimeMillis() - t0 < fromMs) Thread.sleep(5)
        val a0 = e.asks.get()
        while (System.currentTimeMillis() - t0 < toMs) Thread.sleep(5)
        return (e.asks.get() - a0) * 1000.0 / (toMs - fromMs)
    }

    @Test
    fun offScreenARefusingEngineIsAskedAFewTimesASecondNotHundreds() {
        // Before: the 2 ms re-ask.
        val old = RefusingEngine(); val runOld = AtomicBoolean(true)
        val t0 = System.currentTimeMillis()
        val to = Thread { oldLoop(old) { runOld.get() } }.apply { isDaemon = true; start() }
        val before = asksPerSecond(old, 200, 1_200, t0)
        runOld.set(false); to.join(1_000)

        // After, off screen: 2, 4, ... 256 ms, then ~4 asks a second.
        val vis = AppVisibility(initial = false); val spot = ParkSpot(); val b = RefusalBackoff()
        val e = RefusingEngine(); val run = AtomicBoolean(true)
        val t1 = System.currentTimeMillis()
        val tn = Thread { newLoop(e, vis, spot, b) { run.get() } }.apply { isDaemon = true; start() }
        val after = asksPerSecond(e, 800, 2_300, t1)
        run.set(false); spot.wakeAll(); tn.join(1_000)

        assertTrue("before: hundreds of asks a second ($before)", before > 100)
        assertTrue("after: at most ~5 asks a second once settled ($after)", after <= 6.0)
    }

    @Test
    fun onScreenARefusingEngineKeepsTheCadenceForASecondThenBacksOffAndTheAppComingBackAsksAtOnce() {
        val vis = AppVisibility(initial = true); val spot = ParkSpot(); val b = RefusalBackoff()
        vis.listen { v -> if (v) b.reset(); spot.wakeAll() }
        val e = RefusingEngine(); val run = AtomicBoolean(true)
        val t0 = System.currentTimeMillis()
        val t = Thread { newLoop(e, vis, spot, b) { run.get() } }.apply { isDaemon = true; start() }
        val grace = asksPerSecond(e, 100, 700, t0)
        val settled = asksPerSecond(e, 2_000, 3_000, t0)
        assertTrue("inside the grace the 2 ms cadence stands ($grace)", grace > 100)
        assertTrue("after the grace ~4 asks a second ($settled)", settled <= 6.0)
        // Off screen and back: the reset ends the 256 ms wait and the base cadence returns at once.
        vis.set(false); Thread.sleep(50)
        val a0 = e.asks.get()
        vis.set(true)
        Thread.sleep(60)
        assertTrue("asked again at once on coming back (${e.asks.get() - a0} asks in 60 ms)", e.asks.get() - a0 >= 5)
        run.set(false); spot.wakeAll(); t.join(1_000)
    }

    @Test
    fun offScreenWithNothingToSayTheProducerShapedLoopAsksNothingUntilAudioOrTheApp() {
        // The producer's park (AvatarPlayer.parkAway): off screen and quiet, it waits; audio wakes it.
        val vis = AppVisibility(initial = false); val spot = ParkSpot()
        vis.listen { spot.wakeAll() }
        val audio = AtomicInteger(0)                // chunks in hand
        val asks = AtomicInteger(); val parks = AtomicInteger()
        val run = AtomicBoolean(true)
        val t = Thread {
            while (run.get()) {
                if (!vis.visible && audio.get() == 0) { parks.incrementAndGet(); spot.await { run.get() && !vis.visible && audio.get() == 0 }; continue }
                asks.incrementAndGet()
                if (audio.get() > 0) audio.decrementAndGet()     // a unit admitted
                Thread.sleep(2)
            }
        }.apply { isDaemon = true; start() }
        Thread.sleep(300)
        assertEquals("parked off screen: nothing asked", 0, asks.get())
        assertEquals(1, parks.get())
        audio.set(5); spot.wakeAll()                // a reply arrives in the background: it still plays
        Thread.sleep(200)
        assertEquals("the reply's five units were admitted, then it parked again", 5, asks.get())
        assertEquals(2, parks.get())
        vis.set(true)
        Thread.sleep(100)
        assertTrue("on screen it runs", asks.get() > 10)
        run.set(false); vis.set(false); spot.wakeAll(); t.join(1_000)
    }
}
