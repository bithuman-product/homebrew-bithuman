package ai.bithuman.flutter

import android.os.Debug

/**
 * What the app is actually doing, sampled live.
 *
 * This exists because "chunky and choppy" is a distribution, and an average hides it:
 * 20 delivered frames per second with a six-second hole averages out to something that
 * looks fine. So the number that matters here is the interval between PRESENTED frames
 * — p50/p95/p99 and the worst gap — not a mean frame rate.
 *
 * The same numbers a developer will want when their own integration stutters, which is
 * why they live in the example app and not in a test harness.
 */
class AvatarStats {
    @Volatile var deliveredFps = 0.0      // presented frames per second, not the engine's rate
    @Volatile var offsetMs = 0.0          // the shown frame past its own audio at the vsync it was shown (>= 0; backlog is inFlight)
    @Volatile var engineQueue = 0         // frames the engine is holding
    @Volatile var inFlight = 0            // admitted units not yet presented
    @Volatile var dropped = 0             // speech units discarded whole by a barge-in
    @Volatile var idleUnits = 0
    @Volatile var speechUnits = 0
    @Volatile var pssMb = 0

    // ★ Audio continuity, which is its own question: every other number here is about
    // PRESENTED FRAMES, and a speaker can starve while the picture looks fine. One
    // under-run inside a 2-4 s sentence is audible as a pause.
    @Volatile var underruns = 0
    @Volatile var writeGapP50 = 0.0
    @Volatile var writeGapP95 = 0.0
    @Volatile var writeGapMax = 0.0
    private val wgaps = DoubleArray(4096)
    private var nWgaps = 0
    private var lastWrite = 0L

    /** One handoff of audio to the device. */
    fun onAudioWrite() {
        val now = System.currentTimeMillis()
        if (lastWrite > 0) {
            val g = (now - lastWrite).toDouble()
            wgaps[nWgaps++ % wgaps.size] = g
            if (g > writeGapMax) writeGapMax = g
        }
        lastWrite = now
    }

    // presented-frame interval distribution, in ms
    @Volatile var p50 = 0.0
    @Volatile var p95 = 0.0
    @Volatile var p99 = 0.0
    @Volatile var maxGapMs = 0.0

    /** End of input -> first presented frame of the reply, and -> first audio sample. */
    @Volatile var ttffMs = -1L
    @Volatile var ttfaMs = -1L
    /**
     * End of input -> the FIRST BYTE of the agent's voice arriving from the cloud.
     * Everything before this is the brain (LLM + TTS first token) and is not ours;
     * everything between this and [ttffMs] is our engine plus our queueing.
     */
    @Volatile var ttfbMs = -1L

    private val gaps = DoubleArray(4096)
    private var nGaps = 0
    private var lastPresent = 0L
    private var windowStart = 0L
    private var windowCount = 0

    @Volatile var turnStart = 0L
    /** Bumped per turn; a unit admitted under an older turn cannot time this one. */
    @Volatile var turnGen = 0
    @Volatile private var gotFirstFrame = false
    @Volatile private var gotFirstAudio = false
    @Volatile private var gotFirstByte = false

    /** A turn was submitted — typed Enter, or the end of the user's speech. */
    fun markTurnStart() {
        turnStart = System.currentTimeMillis()
        turnGen++
        gotFirstFrame = false
        gotFirstAudio = false
        gotFirstByte = false
        ttffMs = -1L
        ttfaMs = -1L
        ttfbMs = -1L
    }

    /** The agent's first voice byte reached us — the boundary between brain and engine. */
    fun markFirstByte() {
        if (turnStart > 0 && !gotFirstByte) {
            gotFirstByte = true
            ttfbMs = System.currentTimeMillis() - turnStart
        }
    }

    fun markFirstAudio() {
        if (turnStart > 0 && !gotFirstAudio) {
            gotFirstAudio = true
            ttfaMs = System.currentTimeMillis() - turnStart
        }
    }

    fun onPresented(speech: Boolean, unitTurnGen: Int = -1) {
        val now = System.currentTimeMillis()
        if (speech && turnStart > 0 && !gotFirstFrame && unitTurnGen == turnGen) {
            gotFirstFrame = true
            ttffMs = now - turnStart
        }
        if (lastPresent > 0) {
            val gap = (now - lastPresent).toDouble()
            if (nGaps < gaps.size) gaps[nGaps++] = gap else gaps[nGaps++ % gaps.size] = gap
            if (gap > maxGapMs) maxGapMs = gap
        }
        lastPresent = now
        windowCount++
        if (windowStart == 0L) windowStart = now
        if (now - windowStart >= 1000) {
            deliveredFps = windowCount * 1000.0 / (now - windowStart)
            windowStart = now
            windowCount = 0
        }
    }

    /** Recompute the distribution. Cheap enough for a 2 Hz sampler. */
    fun refresh() {
        val n = minOf(nGaps, gaps.size)
        if (n > 1) {
            val v = gaps.copyOf(n)
            v.sort()
            p50 = v[(n * 50 / 100).coerceIn(0, n - 1)]
            p95 = v[(n * 95 / 100).coerceIn(0, n - 1)]
            p99 = v[(n * 99 / 100).coerceIn(0, n - 1)]
        }
        pssMb = runCatching { (Debug.getPss() / 1024).toInt() }.getOrDefault(0)
        val m = minOf(nWgaps, wgaps.size)
        if (m > 1) {
            val v = wgaps.copyOf(m); v.sort()
            writeGapP50 = v[(m * 50 / 100).coerceIn(0, m - 1)]
            writeGapP95 = v[(m * 95 / 100).coerceIn(0, m - 1)]
        }
    }

    fun line(): String = String.format(
        "fps %.1f  late %+.0fms  gap p50 %.0f p95 %.0f p99 %.0f max %.0f\n" +
            "engineQ %d  inFlight %d  dropped %d  idle %d  speech %d\n" +
            "ttfb %s  ttff %s  ttfa %s  pss %d MB\n" +
            "UNDERRUNS %d  writeGap p50 %.0f p95 %.0f max %.0f",
        deliveredFps, offsetMs, p50, p95, p99, maxGapMs,
        engineQueue, inFlight, dropped, idleUnits, speechUnits,
        if (ttfbMs >= 0) "${ttfbMs}ms" else "—",
        if (ttffMs >= 0) "${ttffMs}ms" else "—",
        if (ttfaMs >= 0) "${ttfaMs}ms" else "—",
        pssMb, underruns, writeGapP50, writeGapP95, writeGapMax)
}
