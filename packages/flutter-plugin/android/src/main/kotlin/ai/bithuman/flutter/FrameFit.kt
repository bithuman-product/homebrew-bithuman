// How a frame lands on the avatar's surface (2.6.32). The surface is sized once, at load, to the
// engine's full frame (`width x height`). A frame of exactly that size is drawn as it always was —
// 1:1 at (0, 0), the same call, so a full-size frame is pixel-for-pixel what 2.6.31 drew. A smaller
// frame (essence2-android delivers the identity's 720 output while the phone is throttled, once the
// presenter says it scales: `Essence2Avatar.presenterScalesFrames`) is drawn filtered over the whole
// surface, so the engine no longer upscales 720 -> 1080 itself. Both are 9:16 (or 16:9); should the
// aspects ever differ, the frame is letterboxed (centred, its own aspect) rather than stretched.
// Free of Android: FrameFitTest.
package ai.bithuman.flutter

import kotlin.math.abs

object FrameFit {
    /** True when a [fw] x [fh] frame is drawn 1:1 on a [sw] x [sh] surface (the unchanged path). */
    fun oneToOne(fw: Int, fh: Int, sw: Int, sh: Int): Boolean = fw == sw && fh == sh

    /** The frame has the surface's aspect, to within a pixel of the surface (e.g. 720x1280 on 1080x1920). */
    fun sameAspect(fw: Int, fh: Int, sw: Int, sh: Int): Boolean =
        fw > 0 && fh > 0 && sw > 0 && sh > 0 && abs(fw.toLong() * sh / fh - sw) <= 1

    /**
     * Where a [fw] x [fh] frame is drawn on a [sw] x [sh] surface, as (left, top, right, bottom): the
     * whole surface when the aspects agree, else the largest centred rectangle of the frame's own
     * aspect (letterbox / pillarbox). Null for a 1:1 frame or a degenerate size: the caller draws 1:1.
     */
    fun scaledDst(fw: Int, fh: Int, sw: Int, sh: Int): IntArray? {
        if (oneToOne(fw, fh, sw, sh) || fw <= 0 || fh <= 0 || sw <= 0 || sh <= 0) return null
        if (sameAspect(fw, fh, sw, sh)) return intArrayOf(0, 0, sw, sh)
        val wAtH = (fw.toLong() * sh / fh).toInt()          // the frame's width at the surface's height
        return if (wAtH < sw) { val l = (sw - wAtH) / 2; intArrayOf(l, 0, l + wAtH, sh) }
        else { val hAtW = (fh.toLong() * sw / fw).toInt(); val t = (sh - hAtW) / 2; intArrayOf(0, t, sw, t + hAtW) }
    }

    /** [dst] covers the whole [sw] x [sh] surface (no bars to clear). */
    fun fills(dst: IntArray, sw: Int, sh: Int): Boolean = dst[0] == 0 && dst[1] == 0 && dst[2] == sw && dst[3] == sh
}
