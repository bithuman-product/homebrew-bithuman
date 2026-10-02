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
        // Sofia: 720x1280 on 1080x1920 is the same 9:16, to the pixel.
        assertTrue(FrameFit.sameAspect(720, 1280, 1080, 1920))
    }

    @Test
    fun a_different_aspect_is_letterboxed_never_stretched() {
        assertFalse(FrameFit.sameAspect(720, 720, 1080, 1920))
        // A square frame on a portrait surface: full width, centred vertically.
        assertArrayEquals(intArrayOf(0, 420, 1080, 1500), FrameFit.scaledDst(720, 720, 1080, 1920))
        // A 16:9 frame on a 4:3 surface: full width, letterboxed.
        assertArrayEquals(intArrayOf(0, 135, 1440, 945), FrameFit.scaledDst(1280, 720, 1440, 1080))
        // A frame narrower than the surface's aspect: full height, pillarboxed.
        assertArrayEquals(intArrayOf(360, 0, 720, 1080), FrameFit.scaledDst(360, 1080, 1080, 1080))
        assertTrue(FrameFit.fills(intArrayOf(0, 0, 1080, 1920), 1080, 1920))
        assertFalse(FrameFit.fills(intArrayOf(0, 420, 1080, 1500), 1080, 1920))
    }

    @Test
    fun a_degenerate_size_is_not_scaled() {
        assertNull(FrameFit.scaledDst(0, 0, 1080, 1920))
        assertNull(FrameFit.scaledDst(720, 1280, 0, 0))
    }
}
