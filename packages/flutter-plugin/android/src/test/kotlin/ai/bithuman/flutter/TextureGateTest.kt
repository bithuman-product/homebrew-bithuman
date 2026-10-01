// The engine's detach releases every texture synchronously, BEFORE any asynchronous close, and a
// texture is released once however many paths ask. Plain JVM, no device: TextureGate.kt imports
// nothing from Android or Flutter.
//
// Run from any Flutter app that depends on this plugin:
//   (cd <app>/android && ./gradlew :bithuman:testDebugUnitTest --tests 'ai.bithuman.flutter.TextureGateTest')
// or packages/flutter-plugin/scripts/test_android_unit.sh <app dir>.

package ai.bithuman.flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TextureGateTest {

    /** A producer that counts its releases into a shared event log. */
    private class Producer(val name: String, val log: MutableList<String>) {
        var releases = 0
        val gate = TextureGate { releases++; log += "release:$name" }
    }

    /** A session as the plugin holds it: a player to stop, a texture, an async close. */
    private class Session(val name: String, val log: MutableList<String>) {
        val producer = Producer(name, log)
        var stopped = false
        var drawn = 0
        fun draw() { if (!stopped) producer.gate.draw { drawn++; log += "draw:$name" } }
    }

    /** The bh-dispose threads, run when the test says (the asynchronous half of a close). */
    private val asyncCloses = ArrayList<() -> Unit>()

    @Test
    fun detachReleasesEveryTextureBeforeTheFirstAsyncClose() {
        val log = ArrayList<String>()
        val gates = TextureGates()
        val sessions = listOf(Session("a", log), Session("b", log), Session("c", log))
        sessions.forEach { it.draw() }

        gates.detach(sessions,
            quiesce = { s -> s.stopped = true; log += "stop:${s.name}"; s.producer.gate.release() },
            closeAsync = { s ->
                log += "close-start:${s.name}"
                // closeSession: threads joined and the engine closed off the platform thread, then
                // main.post { releaseTexture() } — a no-op by now.
                asyncCloses += { log += "engine-closed:${s.name}"; s.producer.gate.release() }
            })

        // Everything the detach must do synchronously is done before the first close starts.
        val firstClose = log.indexOfFirst { it.startsWith("close-start") }
        for (s in sessions) {
            assertTrue("stop:${s.name} before any close: $log", log.indexOf("stop:${s.name}") in 0 until firstClose)
            assertTrue("release:${s.name} before any close: $log", log.indexOf("release:${s.name}") in 0 until firstClose)
            assertTrue(s.producer.gate.released)
        }
        assertTrue(gates.detached)

        // The asynchronous halves land later: no second release.
        asyncCloses.forEach { it() }
        sessions.forEach { assertEquals("${it.name} released once", 1, it.producer.releases) }
        assertEquals(3, log.count { it.startsWith("release:") })
    }

    @Test
    fun aDrawAfterReleaseIsANoOp() {
        val log = ArrayList<String>()
        val s = Session("a", log)
        s.draw()
        assertEquals(1, s.drawn)
        assertTrue(s.producer.gate.release())
        // The presenter's next vsync (the player is not stopped in this case: the gate alone holds).
        s.draw(); s.draw()
        assertEquals("no frame drawn into a released texture", 1, s.drawn)
        assertFalse(s.producer.gate.draw { error("drawn into a released texture") })
    }

    @Test
    fun aDrawWhileTheSurfaceIsGoneIsANoOpAndResumesWhenItIsBack() {
        val s = Session("a", ArrayList())
        s.producer.gate.surfaceGone = true       // SurfaceProducer.Callback.onSurfaceCleanup
        s.draw()
        assertEquals(0, s.drawn)
        s.producer.gate.surfaceGone = false      // onSurfaceAvailable
        s.draw()
        assertEquals(1, s.drawn)
    }

    @Test
    fun aDoubleReleaseCallsTheProducerOnce() {
        val p = Producer("a", ArrayList())
        assertTrue(p.gate.release())
        assertFalse(p.gate.release())
        assertFalse(p.gate.release())
        assertEquals(1, p.releases)
    }

    @Test
    fun aLoadFinishingAfterDetachReleasesImmediately() {
        val log = ArrayList<String>()
        val gates = TextureGates()

        // Load 1 is in flight when the engine detaches: the detach releases its texture.
        val inFlight = Producer("loading", log)
        gates.loadStarted(inFlight.gate)
        gates.detach(emptyList<Session>(), quiesce = {}, closeAsync = {})
        assertEquals("the in-flight load's texture went with the detach", 1, inFlight.releases)
        // ...and when that load finishes it is not registered, and nothing is released twice.
        assertFalse(gates.loadFinished(inFlight.gate))
        assertEquals(1, inFlight.releases)

        // A texture the detach did not see (created as the detach ran): released by loadFinished
        // itself, synchronously, not after the engine's close.
        val late = Producer("late", log)
        assertFalse(gates.loadFinished(late.gate))
        assertEquals("released at once", 1, late.releases)
        assertEquals(0, gates.inFlight)
    }

    @Test
    fun aLoadFinishingWhileAttachedIsRegisteredAndKeepsItsTexture() {
        val gates = TextureGates()
        val p = Producer("a", ArrayList())
        gates.loadStarted(p.gate)
        assertEquals(1, gates.inFlight)
        assertTrue(gates.loadFinished(p.gate))
        assertEquals(0, p.releases)
        assertFalse(p.gate.released)
        assertEquals(0, gates.inFlight)
        // A detach after it does not see it as in flight (the session's own quiesce releases it).
        gates.detach(emptyList<Session>(), quiesce = {}, closeAsync = {})
        assertEquals(0, p.releases)
    }

    @Test
    fun aFailedLoadReleasesItsTextureOnce() {
        val gates = TextureGates()
        val p = Producer("a", ArrayList())
        gates.loadStarted(p.gate)
        gates.loadFailed(p.gate)
        assertEquals(1, p.releases)
        gates.detach(emptyList<Session>(), quiesce = {}, closeAsync = {})
        assertEquals(1, p.releases)
    }

    @Test
    fun reattachClearsDetached() {
        val gates = TextureGates()
        gates.detach(emptyList<Session>(), quiesce = {}, closeAsync = {})
        assertTrue(gates.detached)
        gates.attach()
        assertFalse(gates.detached)
        val p = Producer("a", ArrayList())
        gates.loadStarted(p.gate)
        assertTrue(gates.loadFinished(p.gate))
    }
}
