// dispose is safe at any time: the threads that use an engine return BEFORE it is closed.
// Plain JVM, no device: EngineUsers.kt imports nothing from Android.
//
// Run from any Flutter app that depends on this plugin:
//   (cd <app>/android && ./gradlew :bithuman:testDebugUnitTest --tests 'ai.bithuman.flutter.EngineUsersTest')
// or packages/flutter-plugin/scripts/test_android_unit.sh <app dir>.

package ai.bithuman.flutter

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class EngineUsersTest {

    /**
     * An engine whose idle decode takes [decodeMs] and, like the SDK's decoder, throws when the
     * engine is closed before or during a decode.
     */
    private class FakeEngine(private val decodeMs: Long = 20) : AutoCloseable {
        @Volatile var closed = false
        val closes = AtomicInteger()
        val decodes = AtomicInteger()
        val inDecode = CountDownLatch(1)
        private val busy = AtomicInteger()
        /** close() ran while a decode was in progress: what crashed the app. Recorded, not raced. */
        @Volatile var closedUnderDecode = false

        fun decodeIdle() {
            check(!closed) { "decode on a closed engine" }
            busy.incrementAndGet()
            try {
                inDecode.countDown()
                Thread.sleep(decodeMs)
                check(!closed) { "the engine was closed under a decode" }
                decodes.incrementAndGet()
            } finally {
                busy.decrementAndGet()
            }
        }

        override fun close() {
            if (busy.get() > 0) closedUnderDecode = true
            closed = true
            closes.incrementAndGet()
        }
    }

    private val died = Collections.synchronizedList(ArrayList<String>())
    private val uncaught = Collections.synchronizedList(ArrayList<String>())
    private var previousHandler: Thread.UncaughtExceptionHandler? = null
    private val onDied: (String, Throwable) -> Unit = { name, e -> died += "$name: ${e.message}" }

    @Before fun watchUncaught() {
        previousHandler = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { t, e -> uncaught += "${t.name}: ${e.message}" }
    }

    @After fun restoreUncaught() {
        Thread.setDefaultUncaughtExceptionHandler(previousHandler)
    }

    /** A player's producer, reduced to what matters here: it decodes idle frames while running. */
    private fun startProducer(users: EngineUsers, engine: FakeEngine): Workers {
        val w = users.newWorkers(onDied)
        w.spawn("bh-produce") { while (w.running) engine.decodeIdle() }
        return w
    }

    @Test fun disposeMidIdleDecodeClosesTheEngineOnlyAfterTheProducerReturned() {
        val engine = FakeEngine(decodeMs = 40)
        val users = EngineUsers(engine)
        val w = startProducer(users, engine)
        assertTrue(engine.inDecode.await(2, TimeUnit.SECONDS))   // the producer is inside a decode now

        assertTrue("the engine is closed by this call", users.close())

        assertFalse("never closed while a decode was in progress", engine.closedUnderDecode)
        assertEquals("every thread returned before close() did", emptyList<String>(), w.alive())
        assertTrue(engine.closed)
        assertEquals("closed exactly once", 1, engine.closes.get())
        w.join(2_000)   // (a close that did not wait leaves the producer mid decode: let it report)
        assertEquals("no thread saw a closed engine: $died", emptyList<String>(), died.toList())
        assertEquals(emptyList<String>(), uncaught.toList())
    }

    @Test fun negativeControlClosingWithoutJoiningIsWhatCrashed() {
        // The order before 2.6.23: lower the flag, close at once. The producer is mid decode and
        // finds the engine closed under it — on Android an uncaught exception there kills the app.
        val engine = FakeEngine(decodeMs = 40)
        val users = EngineUsers(engine)
        val w = startProducer(users, engine)
        assertTrue(engine.inDecode.await(2, TimeUnit.SECONDS))
        w.stop()
        engine.close()
        assertTrue(engine.closedUnderDecode)
        assertTrue(w.join(2_000))
        assertEquals(1, died.size)
        assertTrue(died.single(), died.single().contains("closed under a decode"))
    }

    @Test fun disposeIsSafeBeforeAnyThreadRanAndTwice() {
        val engine = FakeEngine()
        val users = EngineUsers(engine)
        assertTrue(users.close())
        assertFalse("a second dispose does nothing", users.close())
        assertEquals(1, engine.closes.get())
        assertTrue(users.isClosing)
        val refused = runCatching { users.newWorkers(onDied) }.exceptionOrNull()
        assertTrue("no player may start on a closed engine", refused is IllegalStateException)
    }

    @Test fun disposeWaitsForEveryPlayerThatEverRanOnTheEngine() {
        // An idle hold stops a player without closing the engine; its threads may still be
        // winding down when the app disposes. Both players' threads return before the close.
        val engine = FakeEngine(decodeMs = 30)
        val users = EngineUsers(engine)
        val held = startProducer(users, engine)
        assertTrue(engine.inDecode.await(2, TimeUnit.SECONDS))
        held.stop()                                   // setIdleHold(true): no wait
        startProducer(users, engine)                  // a fresh player, still running
        assertTrue(users.close())
        assertFalse(engine.closedUnderDecode)
        assertEquals(emptyList<String>(), held.alive())
        assertEquals(emptyList<String>(), died.toList())
        assertEquals(1, engine.closes.get())
    }

    @Test fun aFreshPlayerWaitsForTheHeldPlayersThreads() {
        val engine = FakeEngine(decodeMs = 60)
        val users = EngineUsers(engine)
        val held = startProducer(users, engine)
        assertTrue(engine.inDecode.await(2, TimeUnit.SECONDS))
        held.stop()
        assertTrue("the held producer returns within the wait", users.awaitStopped(2_000))
        assertEquals("no thread of the held player is left", emptyList<String>(), held.alive())
        assertFalse("the engine stays open for the fresh player", engine.closed)
        startProducer(users, engine)
        assertTrue(users.close())
        assertEquals(emptyList<String>(), died.toList())
    }

    @Test fun aThreadStuckInsideTheEngineLeavesItOpenRatherThanClosingUnderIt() {
        val engine = FakeEngine()
        val logs = Collections.synchronizedList(ArrayList<String>())
        val users = EngineUsers(engine) { logs += it }
        val release = CountDownLatch(1)
        val w = users.newWorkers(onDied)
        w.spawn("bh-produce") { release.await() }     // ignores the flag, as a wedged SDK call would
        val t0 = System.nanoTime()
        assertFalse(users.close(warnMs = 50, giveUpMs = 200))
        assertTrue("bounded", (System.nanoTime() - t0) / 1_000_000 < 2_000)
        assertFalse("never closed under a live thread", engine.closed)
        assertTrue(logs.toString(), logs.any { it.contains("NOT closed") && it.contains("bh-produce") })
        release.countDown()
        assertTrue(w.join(2_000))
    }

    @Test fun anExceptionOnAPlayerThreadIsReportedNotThrownToTheProcess() {
        val users = EngineUsers(FakeEngine())
        val w = users.newWorkers(onDied)
        w.spawn("bh-write") { throw IllegalStateException("released track") }
        assertTrue(w.join(2_000))
        assertEquals(listOf("bh-write: released track"), died.toList())
        assertEquals("nothing reached the default handler (it would end an Android app)",
            emptyList<String>(), uncaught.toList())
    }

    @Test fun nothingStartsAfterStop() {
        val users = EngineUsers(FakeEngine())
        val w = users.newWorkers(onDied)
        w.stop()
        assertNull(w.spawn("bh-feed") { error("must not run") })
        assertTrue(w.join(100))
        assertTrue(users.close())
    }
}
