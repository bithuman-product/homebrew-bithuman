// FrameFit.kt: a full-size frame keeps the 1:1 draw (pixel-identical to 2.6.31); a smaller frame
// (the engine's 720p step-down) is scaled over the whole surface. Plain JVM:
//   (cd <app>/android && ./gradlew :bithuman:testDebugUnitTest --tests 'ai.bithuman.flutter.FrameFitTest')
package ai.bithuman.flutter

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FrameFitTest {
    @Test
    fun a_full_size_frame_is_drawn_one_to_one() {
        assertTrue(FrameFit.oneToOne(1080, 1920, 1080, 1920))
        assertNull(FrameFit.scaledDst(1080, 1920, 1080, 1920))
        assertTrue(FrameFit.oneToOne(1920, 1080, 1920, 1080))
    }

    @Test
    fun a_720p_frame_fills_a_1080p_surface() {
        assertFalse(FrameFit.oneToOne(720, 1280, 1080, 1920))
        assertArrayEquals(intArrayOf(0, 0, 1080, 1920), FrameFit.scaledDst(720, 1280, 1080, 1920))
        assertArrayEquals(intArrayOf(0, 0, 1920, 1080), FrameFit.scaledDst(1280, 720, 1920, 1080))
    }

    @Test
    fun a_degenerate_size_is_not_scaled() {
        assertNull(FrameFit.scaledDst(0, 0, 1080, 1920))
        assertNull(FrameFit.scaledDst(720, 1280, 0, 0))
    }
}
