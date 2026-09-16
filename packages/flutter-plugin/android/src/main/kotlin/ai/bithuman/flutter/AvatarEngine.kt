// The engine, as the player sees it — and the two on-device engines behind it.
//
// AvatarPlayer's contract is about UNITS: a frame and the samples it was generated from,
// admitted whole and presented when the device reaches them. Nothing in that contract
// names an engine, so the player is written against this interface and the two SDKs
// are adapted to it here, in one file, where the differences are visible side by side:
//
//   expression-2 (`ai.bithuman:expression2-android`)  20 fps, 416x720 portrait.
//     `pull` returns a frame that CARRIES its first 16 kHz sample (`audioSample`,
//     0.4.5+); the stream runs on across replies and restarts at `resetState(true)`.
//     `flushTail` closes a reply; the next `feed` continues the same stream.
//     Idle: `Expression2IdleLoop`, the SDK's cursor over the identity's clip.
//
//   essence-2 (`ai.bithuman:essence2-android`)  25 fps, 1248x704 landscape.
//     `pull` returns a bare RGBA frame — but the engine's audio leg (`le_a2x`) emits
//     motion frame i for 16 kHz samples [640 i, 640 (i+1)) of the OPEN UTTERANCE,
//     in order, one per HOP, so the frame's audio position is its ordinal. This
//     adapter counts. `endOfAudio` closes an utterance and the engine REFUSES a feed
//     after it, so the next reply starts a new utterance with `resetAudio` — and the
//     adapter keeps the stream position across that boundary so the player's byte
//     stream, which resets only on a barge-in, still indexes correctly.
//     Idle: `Essence2Avatar.idle` — a memcpy of the identity's `target_frames.mp4`,
//     forward with wrap on the SDK's own cursor. The speech walk starts at that
//     cursor and the cursor is stepped once per speech frame, so the driver footage
//     runs on through a reply and idle resumes where speech left off — the owner's
//     "the driver video plays regardless of state".
//
// The ADMISSION, WRITE-AHEAD, PRESENTATION and IDLE rules are the player's and apply
// to both. What differs per engine is stated here: the frame rate (so the unit's
// sample count), where a frame's audio is found, and what a reset and a tail are.
package ai.bithuman.flutter

import ai.bithuman.elevate.Essence2Avatar
import ai.bithuman.expression2.Expression2Avatar
import ai.bithuman.expression2.Expression2IdleLoop
import android.graphics.Bitmap
import java.nio.ByteBuffer
import java.util.concurrent.ArrayBlockingQueue

/** The engine's own counters, for the log lines that split a turn into waiting and rendering. */
class EngineStats(val wallMs: Double, val chunks: Long, val frames: Long)

/** The identity's idle clip: the next frame of it, in order, wrapping at the end. */
interface IdleClip {
    /** Fills [dst] with the next frame and returns its index in the clip, or -1 when none is ready yet. */
    fun next(dst: Bitmap): Int
    val frameCount: Int
    val wraps: Int
    val lastIndex: Int
}

/** What the player asks of an engine. The player knows neither engine by name. */
interface AvatarEngine : AutoCloseable {
    /** For the log and `engineVersion`. */
    val name: String
    val width: Int
    val height: Int
    /** Frames per second the engine produces: a unit is one frame and `RATE / fps` samples. */
    val fps: Int
    fun newFrameBitmap(): Bitmap
    /** 16 kHz mono float samples of the agent's voice (the player converts from the 24 kHz wire). */
    fun feed(f16k: FloatArray)
    /** The reply's audio has stopped: render what is left. */
    fun flushTail()
    /** A barge-in: drop every unrendered frame and start the sample count over. */
    fun reset()
    /**
     * The next speech frame into [dst]. Returns the first 16 kHz sample — counted over
     * everything fed since [reset] — of the audio it was generated from, or -1 when no
     * frame is ready.
     */
    fun pull(dst: Bitmap): Long
    /** The engine still owes frames for audio it was fed. */
    val hasPendingTail: Boolean
    /** Frames rendered (or motion computed) and not yet pulled. */
    val queuedFrames: Int
    /** Audio slices the engine holds unrendered, where it can say; -1 where it cannot. */
    val pendingAudioSlices: Int
    fun stats(): EngineStats?
    val idle: IdleClip?
}

/** expression-2 through the published AAR: the SDK answers every question itself. */
class Expression2Engine(private val avatar: Expression2Avatar) : AvatarEngine {
    override val name = "expression2-android"
    override val width get() = avatar.width
    override val height get() = avatar.height
    override val fps = Expression2Avatar.FRAMES_PER_SECOND
    override fun newFrameBitmap(): Bitmap = avatar.newFrameBitmap()
    override fun feed(f16k: FloatArray) = avatar.feed(f16k)
    override fun flushTail() = avatar.flushTail()
    override fun reset() = avatar.resetState(true)      // also restarts the engine's audioSample count
    override fun pull(dst: Bitmap): Long = avatar.pull(dst)?.audioSample ?: -1L
    override val hasPendingTail get() = avatar.hasPendingTail
    override val queuedFrames get() = avatar.queuedFrames
    override val pendingAudioSlices get() = runCatching { avatar.pendingAudioSlices }.getOrDefault(-1)
    override fun stats(): EngineStats? =
        runCatching { avatar.stats() }.getOrNull()?.let { EngineStats(it.wallMs, it.chunks, it.frames) }
    override val idle: IdleClip? = avatar.idleLoop?.let { loop -> Expression2Idle(loop) }
    override fun close() = avatar.close()

    private class Expression2Idle(private val loop: Expression2IdleLoop) : IdleClip {
        override fun next(dst: Bitmap): Int = loop.next(dst)
        override val frameCount get() = loop.frameCount
        override val wraps get() = loop.wraps
        override val lastIndex get() = loop.lastIndex
    }
}

/**
 * essence-2 through the published AAR. The frame's audio position is its ordinal in the
 * open utterance; the stream position carries across utterances; idle is the SDK's
 * cursor, stepped in lockstep with speech.
 *
 * ★THE RENDER RUNS ON A THREAD OF THIS ADAPTER'S, NOT THE PLAYER'S. The SDK renders
 * INSIDE `Essence2Avatar.pull`, on the caller's thread — by design, so an integrator
 * pays for what they consume. The player's contract is the opposite: [pull] is a poll
 * (expression-2's is a queue read), and the producer loop that calls it is also the
 * loop that keeps the speaker fed while a frame is late. Measured 2026-09-16 on a
 * Galaxy S25+: the first `pull` of a reply — the renderer's prime after a barge purge
 * plus the first finished frame — took up to 292 ms on the producer's thread, the
 * sink held its floor of 3 units + 4 on the device (280 ms), and the speaker under-ran
 * once per run, always in a reply's first 200 ms. So `e2-render` pulls from the SDK
 * into a ring of [DEPTH] frames and the player's [pull] is a copy of a finished one
 * (~2 ms at 1080p) or -1 — the producer is never inside a render. A reset moves
 * [gen]; a frame rendered under an older gen is dropped, never presented.
 *
 * One monitor guards the counters that make a frame's ordinal mean something; the
 * SDK call itself runs outside it (the SDK serialises feed / pull / reset on locks of
 * its own), so a [reset] waits for at most the render in flight, as it did before.
 */
class Essence2Engine(private val avatar: Essence2Avatar) : AvatarEngine {
    override val name = "essence2-android"
    override val width get() = avatar.width
    override val height get() = avatar.height
    override val fps = FPS
    /** One idle buffer per caller: the presenter's walk ([Essence2Idle.next]) and the render thread's step ([stepIdle]). */
    private val idleBuf: ByteBuffer = avatar.newFrameBuffer()
    private val stepBuf: ByteBuffer = avatar.newFrameBuffer()
    /** Stream sample (16 kHz, since [reset]) where the open utterance began. */
    private var uttBase = 0L
    /** Samples fed to the open utterance. */
    private var uttFed = 0L
    /** Frames pulled from the open utterance: the next frame's ordinal. */
    private var delivered = 0L
    /** An utterance has audio the engine has not finished turning into frames. */
    @Volatile private var open = false
    /** `endOfAudio` has been called on the open utterance; the next audio starts a new one. */
    private var closed = false
    /**
     * The next reply's audio, arrived while the previous utterance was still draining its
     * tail. The engine refuses a feed after `endOfAudio` and a reset would drop the
     * frames still coming out, so it waits here and opens the next utterance the moment
     * the last frame is out. Bounded by the transport: one reply's worth at most.
     */
    private val pending = ArrayList<FloatArray>()
    private var pendingClose = false
    @Volatile private var pendingN = 0
    /** Speech utterances started (for the log). */
    private var utterances = 0L
    @Volatile private var framesTotal = 0L
    @Volatile private var pullNanos = 0L
    @Volatile private var queued = 0
    private val nt: Int = avatar.targetFrames
    /** Where the SDK's idle cursor stands: the index `idle()` will emit next. Under [idleLock]. */
    private var cursor = 0
    /**
     * The idle cursor's own monitor — for [cursor] ONLY, never across the SDK call.
     * ★NOT the engine's: a [reset] holds the engine monitor for the SDK's reset — which
     * waits for the block and the render in flight, up to ~350 ms on the S25+ — and the
     * presenter decodes its idle frames on exactly that path; measured 2026-09-16, the
     * first idle frame after a cut came 61 ms late and the speaker under-ran once, at
     * the cut. ★AND NOT HELD ACROSS `avatar.idle()`: the SDK's cursor pull waits for its
     * decode thread, ~35 of every 40 ms on this identity, and a reset that needed the
     * monitor to read [cursor] lost it to the presenter's next pull every time — RESET
     * landed 900-960 ms after four of 22 cuts (the picture did not stall; the sink held).
     * The SDK's cursor is safe to step from two threads; only the mirror needs a monitor.
     */
    private val idleLock = Object()
    private val idleClip = Essence2Idle()

    /** A frame the render thread finished: its pixels, its stream position, the [gen] it was rendered under. */
    private class Rendered(val buf: ByteBuffer, val at: Long, val gen: Int)
    private val free = ArrayBlockingQueue<ByteBuffer>(DEPTH).apply { repeat(DEPTH) { offer(avatar.newFrameBuffer()) } }
    private val ready = ArrayBlockingQueue<Rendered>(DEPTH)
    /** Moved by [reset]: a frame rendered under an older value belongs to a cancelled reply. */
    @Volatile private var gen = 0
    /**
     * ★A REPLY'S FIRST FRAME WAITS FOR A LEAD. The voice starts the moment the first
     * frame is admitted and does not stop for a late one (the player's rule) — so a
     * frame that arrives after its audio has gone out under the held one is dropped as
     * stale. At a reply's start the engine is at its slowest: the renderer primes after
     * the purge, and the motion thread's first two blocks (150-200 ms each on the S25+
     * beside the render) are the ones the second and third frames wait for. Measured
     * 2026-09-16 with no lead: frame 1 came 310 ms after frame 0, the head had moved 7
     * units meanwhile, and the next ~30 frames were dropped stale while the picture
     * caught up — a frozen first frame 1.2 s long at the top of a reply (45 stale, 45
     * catch-up units over 8 replies). With the lead: [pull] hands out nothing until
     * [LEAD] frames are finished and a block of motion waits behind them, or the
     * utterance is closed (a short reply has no more to wait for). Costs ~LEAD x 40 ms
     * of TTFA once per reply; buys a picture that keeps up with its voice from frame 0.
     */
    @Volatile private var leadPending = false
    @Volatile private var shut = false
    private val renderer = Thread(::renderLoop, "e2-render").apply { isDaemon = true; start() }

    override fun newFrameBitmap(): Bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)

    /** Caller holds the monitor. The driver walk starts where the idle cursor stands. */
    private fun startUtterance() {
        uttBase += uttFed; uttFed = 0; delivered = 0; closed = false
        avatar.resetAudio(startFrame = synchronized(idleLock) { cursor })
        utterances++
        leadPending = true
    }

    @Synchronized override fun feed(f16k: FloatArray) {
        if (f16k.isEmpty()) return
        if (closed && open) { pending.add(f16k); pendingN = pending.size; return }
        if (!open || closed) startUtterance()
        avatar.feed(f16k)
        uttFed += f16k.size
        open = true
        queued = avatar.available()
    }

    @Synchronized override fun flushTail() {
        if (pending.isNotEmpty()) { pendingClose = true; return }
        if (open && !closed) { avatar.endOfAudio(); closed = true; queued = avatar.available() }
    }

    @Synchronized override fun reset() {
        gen++
        pending.clear(); pendingN = 0; pendingClose = false
        avatar.resetAudio(startFrame = synchronized(idleLock) { cursor })
        uttBase = 0; uttFed = 0; delivered = 0; open = false; closed = false
        queued = 0
        // Finished frames of the cancelled reply go back to the pool; the one in flight
        // comes back through the gen check in [renderLoop].
        while (true) { val r = ready.poll() ?: break; free.offer(r.buf) }
    }

    /** The render thread: one SDK pull into a free buffer, then hand it to [pull]. */
    private fun renderLoop() {
        while (!shut) {
            if (!open) { Thread.sleep(2); continue }
            val buf = free.poll(10, java.util.concurrent.TimeUnit.MILLISECONDS) ?: continue
            val g = gen
            val t0 = System.nanoTime()
            val got = avatar.pull(buf)
            pullNanos += System.nanoTime() - t0
            val at = synchronized(this) {
                queued = avatar.available()
                when {
                    g != gen -> -1L                    // rendered across a reset: belongs to the old reply
                    !got -> { onNoFrame(); -1L }
                    else -> {
                        val a = uttBase + delivered * HOP
                        delivered++; framesTotal++
                        // The driver walk advanced one frame; keep the idle cursor beside it so
                        // the footage runs on when the reply ends, rather than jumping back.
                        stepIdle()
                        a
                    }
                }
            }
            if (at < 0) { free.offer(buf); if (!got) Thread.sleep(2) }
            else { buf.rewind(); ready.offer(Rendered(buf, at, g)) }
        }
    }

    /** Caller holds the monitor. A `false` after endOfAudio means every frame is out: the utterance is done. */
    private fun onNoFrame() {
        if (!closed) return
        open = false
        if (pending.isNotEmpty()) {
            startUtterance()
            for (p in pending) { avatar.feed(p); uttFed += p.size }
            pending.clear(); pendingN = 0
            open = true
            if (pendingClose) { avatar.endOfAudio(); closed = true; pendingClose = false }
            queued = avatar.available()
        }
    }

    override fun pull(dst: Bitmap): Long {
        if (leadPending) {
            if (ready.size >= LEAD && (queued >= 8 || closed || !open)) leadPending = false
            else if (ready.size >= DEPTH || (closed && !open)) leadPending = false
            else return -1L
        }
        while (true) {
            val r = ready.poll() ?: return -1L
            if (r.gen != gen) { free.offer(r.buf); continue }
            r.buf.rewind()
            dst.copyPixelsFromBuffer(r.buf)
            free.offer(r.buf)
            return r.at
        }
    }

    /** Advances the SDK's idle cursor by one without showing the frame (render thread). */
    private fun stepIdle() {
        if (nt <= 0) return
        stepBuf.rewind()
        if (avatar.idle(stepBuf)) synchronized(idleLock) { cursor = (cursor + 1) % nt }
    }

    override val hasPendingTail get() = open || pendingN > 0 || ready.isNotEmpty()
    override val queuedFrames get() = queued + ready.size
    override val pendingAudioSlices get() = -1
    override fun stats(): EngineStats = EngineStats(pullNanos / 1e6, utterances, framesTotal)
    override val idle: IdleClip? = if (nt > 0) idleClip else null
    override fun close() {
        shut = true
        renderer.join()
        synchronized(this) { avatar.close() }
    }

    private inner class Essence2Idle : IdleClip {
        override val frameCount get() = nt
        @Volatile override var wraps = 0; private set
        @Volatile override var lastIndex = -1; private set
        override fun next(dst: Bitmap): Int {
            idleBuf.rewind()
            if (!avatar.idle(idleBuf)) return -1
            idleBuf.rewind()
            dst.copyPixelsFromBuffer(idleBuf)
            val i = synchronized(idleLock) { val c = cursor; cursor = (c + 1) % nt; c }
            if (i == 0 && lastIndex >= 0) wraps++      // the player logs the wrap
            lastIndex = i
            return i
        }
    }

    companion object {
        /** essence-2's rate: one motion frame per 640 samples at 16 kHz (`le_a2x` HOP). */
        const val FPS = 25
        const val HOP = 640L
        /** Finished frames the render thread keeps ahead of the player: 6 x 8.3 MB at 1080p, 240 ms. */
        private const val DEPTH = 6
        /** Finished frames a reply's first delivery waits for (160 ms): see [leadPending]. */
        private const val LEAD = 4
    }
}
