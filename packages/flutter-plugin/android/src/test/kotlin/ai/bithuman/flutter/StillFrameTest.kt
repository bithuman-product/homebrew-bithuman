// StillFrame.kt against a fake engine with no idle clip: the still is rendered from silence once and
// kept; the engine is reset after it (the first reply starts clean); a failed or slow render is retried,
// but not on every presenter call; a reply in progress is never fed silence. Plain JVM:
//   (cd <app>/android && ./gradlew :bithuman:testDebugUnitTest --tests 'ai.bithuman.flutter.StillFrameTest')
package ai.bithuman.flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class StillFrameTest {
    /** An Expression 2 engine with no idle loop: frames only come out of audio, after a flush. */
    private class NoIdleEngine(var framesAfterFlush: Int = 3, var throwOnFeed: Boolean = false) : StillSource<String> {
        override var busy = false
        val calls = ArrayList<String>()
        private var queued = 0
        private var n = 0
        override fun feedSilence(samples16k: Int) { if (throwOnFeed) throw IllegalStateException("closed"); calls.add("feed:$samples16k") }
        override fun flush() { calls.add("flush"); queued = framesAfterFlush }
        override fun pull(): String? = if (queued > 0) { queued--; "frame${n++}" } else null
        override fun reset() { calls.add("reset"); queued = 0 }
    }
    private val log = ArrayList<String>()
    private var now = 0L
    private fun still(e: NoIdleEngine) = StillFrame(e, { log.add(it) }, clock = { now }, sleep = { now += it })

    @Test
    fun the_character_appears_a_still_is_rendered_once_and_kept() {
        val e = NoIdleEngine(); val s = still(e)
        assertEquals("frame0", s.get())
        assertEquals("frame0", s.get())          // kept: no second render
        assertEquals(listOf("feed:5120", "flush", "reset"), e.calls)
        assertEquals(1, s.attempts)
        assertTrue(log.single().startsWith("still frame shown in place of the idle clip"))
    }

    @Test
    fun a_render_that_brings_no_frame_is_retried_but_not_on_every_call() {
        val e = NoIdleEngine(framesAfterFlush = 0); val s = still(e)
        assertNull(s.get())                      // waits up to 3 s of fake time, then gives up
        assertEquals(listOf("feed:5120", "flush", "reset"), e.calls)
        assertNull(s.get()); assertNull(s.get())  // within the retry interval: no new attempt
        assertEquals(1, s.attempts)
        now += 1_000; e.framesAfterFlush = 2
        assertEquals("frame0", s.get())
        assertEquals(2, s.attempts)
    }

    @Test
    fun a_reply_in_progress_is_never_fed_silence_and_a_failure_does_not_throw() {
        val e = NoIdleEngine(); val s = still(e)
        e.busy = true
        assertNull(s.get())
        assertEquals(emptyList<String>(), e.calls)
        e.busy = false; e.throwOnFeed = true; now += 1_000
        assertNull(s.get())                      // logged, no exception to the presenter
        assertTrue(log.any { it.startsWith("still frame: the render failed (closed)") })
        e.throwOnFeed = false; now += 1_000
        assertEquals("frame0", s.get())
    }
}
