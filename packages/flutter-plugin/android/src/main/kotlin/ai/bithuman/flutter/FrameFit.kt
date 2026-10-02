// How a frame lands on the avatar's surface (2.6.32). The surface is sized once, at load, to the
// engine's full frame (`width x height`). A frame of exactly that size is drawn as it always was —
// 1:1 at (0, 0), the same call, so a full-size frame is pixel-for-pixel what 2.6.31 drew. A smaller
// frame (essence2-android steps down to 720p while the phone is throttled, when the presenter says it
// scales) is drawn filtered over the whole surface, so the engine no longer pays for an upscale of
// its own. Free of Android: FrameFitTest.
package ai.bithuman.flutter

object FrameFit {
    /** True when a [fw] x [fh] frame is drawn 1:1 on a [sw] x [sh] surface (the unchanged path). */
    fun oneToOne(fw: Int, fh: Int, sw: Int, sh: Int): Boolean = fw == sw && fh == sh

    /**
     * The destination rectangle (left, top, right, bottom) a [fw] x [fh] frame is scaled into on a
     * [sw] x [sh] surface: the whole surface. Null for a 1:1 frame or a degenerate size (nothing
     * to scale; the caller draws 1:1 or skips).
     */
    fun scaledDst(fw: Int, fh: Int, sw: Int, sh: Int): IntArray? =
        if (oneToOne(fw, fh, sw, sh) || fw <= 0 || fh <= 0 || sw <= 0 || sh <= 0) null else intArrayOf(0, 0, sw, sh)
}
