// The presenter's starve counter (StarveCounter.kt): only an empty-queue hold of at least MIN_HOLD_MS (50 ms)
// before frames come back is a starve. The 2-8 ms gaps between expression2-android 0.6.0's per-block
// publishes are not counted; holds of ~200-550 ms are.
//
// Plain JVM, no device:
//   (cd <app>/android && ./gradlew :bithuman:testDebugUnitTest --tests 'ai.bithuman.flutter.StarveCounterTest')
// or packages/flutter-plugin/scripts/test_android_unit.sh <app dir>.

package ai.bithuman.flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class StarveCounterTest {
    @Test
    fun publishGapsOfAFewMillisecondsAreNotStarves() {
        val s = StarveCounter()
        var t = 1_000L
        // One utterance on 0.6.0: the queue empties between every publish of a block for 2-8 ms.
        for (gap in listOf(2L, 3L, 5L, 8L, 4L, 7L, 6L, 2L)) {
            s.empty(t)
            val h = s.refill(t + gap)!!
            assertEquals(gap, h.ms)
            assertFalse("a $gap ms publish gap is not a starve", h.counted)
            t += gap + 16
        }
        assertEquals(0, s.count)
        assertEquals(-1L, s.emptySince)
    }

    @Test
    fun holdsOfAtLeastTheThresholdAreStarves() {
        val s = StarveCounter()
        for ((at, ms) in listOf(0L to 200L, 1_000L to 550L, 3_000L to StarveCounter.MIN_HOLD_MS)) {
            s.empty(at)
            val h = s.refill(at + ms)!!
            assertEquals(ms, h.ms)
            assertTrue("a $ms ms hold is a starve", h.counted)
        }
        assertEquals(3, s.count)
        // One millisecond short of the threshold is not.
        s.empty(10_000L)
        assertFalse(s.refill(10_000L + StarveCounter.MIN_HOLD_MS - 1)!!.counted)
        assertEquals(3, s.count)
        assertEquals(50L, StarveCounter.MIN_HOLD_MS)
    }

    @Test
    fun aHoldIsTimedFromItsFirstEmptyPullAndClosesOnce() {
        val s = StarveCounter()
        assertNull("no hold open: a good pull closes nothing", s.refill(5L))
        s.empty(100L)
        s.empty(130L)   // later empty pulls of the same hold do not move its start
        s.empty(160L)
        assertEquals(100L, s.emptySince)
        val h = s.refill(400L)!!
        assertEquals(300L, h.ms)
        assertTrue(h.counted)
        assertNull("the hold closed once", s.refill(420L))
        assertEquals(1, s.count)
    }
}
