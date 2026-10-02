// Skip-ahead's clock (PlayoutClock.kt), against a fake essence-2 engine with the SDK's lock shape:
// the clock is mapped per utterance, a barge-in's reset puts it back to the stream's start, a
// frame's position follows the SDK's ordinal, and no lock order can deadlock — the producer's
// position never waits on a feed holding the adapter's monitor.
//
// Plain JVM, no device: PlayoutClock.kt imports nothing from Android.
//   (cd <app>/android && ./gradlew :bithuman:testDebugUnitTest --tests 'ai.bithuman.flutter.PlayoutClockTest')
// or packages/flutter-plugin/scripts/test_android_unit.sh <app dir>.

package ai.bithuman.flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

class PlayoutClockTest {

    /**
     * The essence2-android 0.9.1 shape this adapter talks to: a main lock (feed's block compute,
     * the render, resetAudio) and a playout lock (setPlayoutPosition; resetAudio takes it first;
     * a delivered frame notes itself under it while the main lock is held).
     */
    private class FakeSdk(private val feedMs: Long = 0, private val resetMs: Long = 0, private val record: Boolean = true) {
        val main = Object()
        val playoutLock = Object()
        /** What setPlayoutPosition received, in order; null after a resetAudio forgot it. */
        val positions: MutableList<Long?> = Collections.synchronizedList(ArrayList())
        @Volatile var clockSet = false
        val inFeed = CountDownLatch(1)

        fun setPlayoutPosition(samples16k: Long) = synchronized(playoutLock) { if (record) positions.add(samples16k); clockSet = true }
        fun resetAudio() {
            synchronized(playoutLock) { clockSet = false; if (record) positions.add(null) }
            synchronized(main) { if (resetMs > 0) Thread.sleep(resetMs) }
        }
        fun feed() = synchronized(main) { inFeed.countDown(); if (feedMs > 0) Thread.sleep(feedMs) }
        /** A pull: the render under the main lock, the frame noted under the playout lock. */
        fun pull() = synchronized(main) { synchronized(playoutLock) { } }
    }

    /** The adapter's bookkeeping around the clock, as Essence2Engine does it (its monitor = this). */
    private class FakeAdapter(val sdk: FakeSdk) {
        @Volatile var open = false
        var uttBase = 0L
        var uttFed = 0L
        val clock = PlayoutClock({ sdk.setPlayoutPosition(it) }, { open })

        @Synchronized fun feed(n: Long) {
            if (!open) startUtterance()
            sdk.feed()
            uttFed += n; open = true
        }
        @Synchronized fun startUtterance() {
            uttBase += uttFed; uttFed = 0
            clock.reset(uttBase) { sdk.resetAudio() }
        }
        /** A reply ended (every frame out); the next feed opens a new utterance. */
        @Synchronized fun endUtterance() { open = false }
        @Synchronized fun reset() {
            clock.reset(0L) { sdk.resetAudio() }
            uttBase = 0; uttFed = 0; open = false
        }
        /** The render thread: pull outside the monitor, then the bookkeeping inside it. */
        fun renderOnce() { sdk.pull(); synchronized(this) { } }
    }

    @Test
    fun the_position_is_mapped_onto_the_open_utterance() {
        val sdk = FakeSdk(); val a = FakeAdapter(sdk)
        a.clock.set(500)                      // nothing open yet: dropped
        assertEquals(listOf<Long?>(), sdk.positions.toList())
        a.feed(16_000)                        // utterance 1 at stream 0
        a.clock.set(640)
        a.clock.set(16_000)
        a.endUtterance()
        a.feed(8_000)                         // utterance 2 at stream 16000
        a.clock.set(15_000)                   // the player still plays utterance 1's end: not started
        a.clock.set(16_640)
        assertEquals(listOf<Long?>(null, 640, 16_000, null, -1_000, 640), sdk.positions.toList())
    }

    @Test
    fun a_barge_in_resets_the_clock_to_the_stream_start() {
        val sdk = FakeSdk(); val a = FakeAdapter(sdk)
        a.feed(16_000); a.endUtterance(); a.feed(16_000)      // utterance 2 at stream 16000
        a.clock.set(20_000)
        a.reset()                                              // barge-in: the player's stream restarts at 0
        a.clock.set(320)                                       // nothing open after the purge: dropped
        a.feed(4_000)                                          // the new reply at stream 0
        a.clock.set(320)
        assertEquals(listOf<Long?>(null, null, 4_000, null, null, 320), sdk.positions.toList())
    }

    @Test
    fun a_position_that_races_the_reset_never_reaches_the_engine() {
        // A barge-in's reset while utterance 2 (stream 16000) is open; the SDK's resetAudio takes
        // 150 ms, and the producer — still on the old stream — keeps calling meanwhile. Without the
        // hold, the base is already 0 and `open` still true: 16099 would land on the SDK after it
        // forgot its clock, and the next reply would skip its first 25 frames.
        val sdk = FakeSdk(); val a = FakeAdapter(sdk)
        a.feed(16_000); a.endUtterance(); a.feed(640)
        a.clock.set(16_099)
        val slow = FakeAdapter(FakeSdk(resetMs = 150))
        slow.feed(16_000); slow.endUtterance(); slow.feed(640)
        val stop = AtomicBoolean(false); val calls = AtomicLong()
        val producer = Thread { while (!stop.get()) { slow.clock.set(16_099); calls.incrementAndGet(); Thread.sleep(1) } }
        producer.start(); Thread.sleep(20)
        val before = slow.clock.forwarded
        slow.reset()                                   // 150 ms in the SDK
        val during = calls.get()
        Thread.sleep(20); stop.set(true); producer.join()
        assertTrue("the producer ran through the reset ($during calls)", during > 20)
        assertTrue("positions were forwarded before the reset", before > 0)
        val log = slow.sdk.positions.toList()
        val afterReset = log.subList(log.lastIndexOf(null) + 1, log.size)
        assertEquals("nothing reached the engine during or after the reset", listOf<Long?>(), afterReset)
        assertEquals(listOf<Long?>(null, null, 99), sdk.positions.toList())
    }

    @Test
    fun a_frame_is_placed_by_the_sdk_ordinal_not_by_counting() {
        val hop = 640L
        // No skip: the SDK's ordinal equals the count.
        assertEquals(16_000 + 3 * hop, PlayoutClock.frameAt(16_000, 3, 3, hop))
        // Frames 4 and 5 skipped: frame 6 is delivered fourth-to-last, at ITS audio.
        assertEquals(16_000 + 6 * hop, PlayoutClock.frameAt(16_000, 6, 4, hop))
        assertEquals(7L, PlayoutClock.nextDelivered(6, 4))
        // An engine that names no ordinal (before 0.9.1): the adapter counts.
        assertEquals(16_000 + 4 * hop, PlayoutClock.frameAt(16_000, -1, 4, hop))
        assertEquals(5L, PlayoutClock.nextDelivered(-1, 4))
        // Over an utterance with skips, positions never fall behind their ordinals (no drift builds up).
        val ordinals = longArrayOf(0, 1, 2, 5, 6, 9, 10, 11, 15, 16)
        var delivered = 0L
        for (k in ordinals) {
            val at = PlayoutClock.frameAt(0, k, delivered, hop)
            assertEquals("frame $k sits on its own audio", k * hop, at)
            delivered = PlayoutClock.nextDelivered(k, delivered)
        }
    }

    @Test
    fun the_idle_cursor_steps_once_per_ordinal() {
        assertEquals(1, PlayoutClock.idleSteps(0, 0, 250))     // the first frame
        assertEquals(1, PlayoutClock.idleSteps(5, 5, 250))     // no skip
        assertEquals(3, PlayoutClock.idleSteps(7, 5, 250))     // 5 and 6 skipped, 7 delivered
        assertEquals(1, PlayoutClock.idleSteps(-1, 9, 250))    // no ordinal: one per frame
        assertEquals(10, PlayoutClock.idleSteps(509, 0, 250))  // two whole laps left out
    }

    @Test(timeout = 10_000)
    fun no_lock_order_deadlock_and_the_producer_never_waits_on_a_feed() {
        // A feed holds the adapter's monitor and the SDK's main lock for 200 ms (the block compute).
        val sdk = FakeSdk(feedMs = 200, resetMs = 5); val a = FakeAdapter(sdk)
        a.feed(640)
        val inner = CountDownLatch(1)
        val feeder = Thread { synchronized(a) { inner.countDown(); a.feed(640) } }
        feeder.start(); inner.await()
        val t0 = System.nanoTime()
        a.clock.set(320)                                   // while the feed is in its block compute
        val ms = (System.nanoTime() - t0) / 1e6
        feeder.join()
        assertTrue("set() waited ${"%.1f".format(ms)} ms behind a feed", ms < 50)

        // Then everything at once: producer positions, feeds, renders, resets, utterance ends.
        val stop = AtomicBoolean(false)
        val errors = Collections.synchronizedList(ArrayList<Throwable>())
        fun loop(name: String, body: () -> Unit) = Thread({
            try { while (!stop.get()) body() } catch (e: Throwable) { errors.add(e) }
        }, name).apply { start() }
        val fast = FakeSdk(feedMs = 1, resetMs = 1, record = false); val b = FakeAdapter(fast)
        var pos = 0L
        val threads = listOf(
            loop("producer") { b.clock.set(pos++) },
            loop("feed") { b.feed(640) },
            loop("render") { b.renderOnce() },
            loop("reset") { Thread.sleep(3); b.reset() },
            loop("end") { Thread.sleep(2); b.endUtterance() },
        )
        Thread.sleep(1_500)
        stop.set(true)
        for (t in threads) { t.join(2_000); assertTrue("${t.name} finished (no deadlock)", !t.isAlive) }
        assertTrue("no errors: $errors", errors.isEmpty())
        assertTrue("positions reached the engine", b.clock.forwarded > 0)
    }
}
