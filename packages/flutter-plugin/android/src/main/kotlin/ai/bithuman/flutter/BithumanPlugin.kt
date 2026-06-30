// bithuman Android plugin — elevate-frames path (minimal revival).
//
// Implements the 'ai.bithuman.avatar' MethodChannel subset needed to load an
// Elevate le-bundle and play its driving protocol onto a Flutter texture
// (texture pattern from the archived converse plugin: SurfaceTexture entry ->
// Surface -> lockCanvas + drawBitmap). Audio/PiP/converse methods are stubbed
// — the Android LIVE chain is the LMDM keypoint actor, scoped in bithuman-sdk
// engine/elevate/runtime-cpu/actor/ACTOR_SCOPE.md.
//
// Render architecture (task48): CHUNKED pipeline + sustainable-rate governor.
// An engine thread renders batches of `batch` drive frames per ORT call
// (b24 graph: ~1.4x cheaper per frame than b1 on SM8550) into one of two
// native crop caches; the 40 ms display tick pastes cached frames on demand
// at a governed cadence (25/12.5/8.33 fps) chosen so the engine duty cycle
// stays under ~70% — steady medium fps instead of the flat-out -> thermal
// throttle -> 3 fps spiral. Playback is paced by WALL CLOCK throughout: a
// late engine drops content, never stretches time (bithuman-apps 3805209).
// Chunk lookahead note: a chunk is up to batch x stride x 40 ms of canned-
// loop lookahead — fine here; a future LMDM live-speech path needs a small
// streaming batch instead. Mouth-gate flips (setSpeaking) therefore take
// effect with ~1 chunk-render of latency: the stale prefetch is dropped and
// the fresh-mode chunk preempts the playing one as soon as it renders.
//
// load() contract here: engine MUST be 'elevate'; 'path' is the le-bundle
// directory on device storage.

package ai.bithuman.flutter

import ai.bithuman.elevate.ElevateFrames
import android.graphics.Bitmap
import android.util.Log
import android.view.Surface
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.view.TextureRegistry
import java.nio.ByteBuffer
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

private const val TAG = "BithumanAvatar"
private const val SLOT_MS = 40L  // 25 fps drive-protocol slot
private const val SLOT_NS = SLOT_MS * 1_000_000L

// Governor: displayed cadence = 25/stride fps, stride in 1..MAX_STRIDE. The
// fastest cadence whose engine duty cycle (render+paste ms per displayed
// frame / cadence period) stays under target wins; hysteresis so it doesn't
// flap. Rendering flat-out heats the SoC until Samsung's foreground throttle
// collapses fps 9.7 -> 3.4 (ANDROID_RESULTS.md §Flutter e2e); a duty-capped
// steady cadence is strictly better to watch.
private const val MAX_STRIDE = 3      // 25 / 12.5 / 8.33 fps
private const val DUTY_TARGET = 0.70  // initial cadence pick
private const val DUTY_DOWN = 0.78    // demote (slower cadence) above this
private const val DUTY_UP = 0.62      // promote (faster) below this, held...
private const val UP_HOLD_CHUNKS = 3  // ...for this many consecutive chunks

class BithumanPlugin : FlutterPlugin, MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var textureRegistry: TextureRegistry
    private val sessions = HashMap<Long, Session>()
    private val executor = Executors.newSingleThreadScheduledExecutor()
    // Chunk renders run here so the display tick (paste + upload on
    // `executor`) keeps pacing while the engine is inside a 1-2 s batch call.
    private val engineExecutor = Executors.newSingleThreadExecutor()

    /// IDLE/TALKING frame ranges of the canned drive protocol, from the
    /// optional `motion_ranges.json` sidecar (tools/classify_motion_ranges.py)
    /// next to the bundle's manifest. The drive protocol is captured from a
    /// TALKING person, so looping all of it flaps the mouth forever; with the
    /// sidecar the render loop ping-pongs inside an idle range while the
    /// agent is silent and inside a talking range while it speaks
    /// (`setSpeaking` from Dart). No sidecar -> legacy full-protocol loop.
    private class MotionRanges(val idle: List<IntRange>, val talking: List<IntRange>) {
        fun ranges(speaking: Boolean) = if (speaking) talking else idle
    }

    /// One pre-rendered chunk's display-side bookkeeping (the crops live in
    /// the native cache of the same index).
    private class Cache {
        var count = 0
        var displayed = 0       // next entry to paste (display thread)
        var gen = 0L            // mode-flip generation at build time
        var speakingMode = false
    }

    private class Session(
        val avatar: ElevateFrames,
        val entry: TextureRegistry.SurfaceTextureEntry,
        val surface: Surface,
        val motion: MotionRanges?,
        val loadT0: Long,
    ) {
        // Speaking hint from Dart (`setSpeaking`); applied at chunk build.
        @Volatile var speaking = false
        // Ping-pong cursor over the active range (motion != null only).
        // Engine-thread-owned: advanced at chunk BUILD time.
        var mode = false          // mode the cursor currently follows
        var range: IntRange? = null
        var pos = 0               // current drive-frame index
        var dir = 1               // +1 forward, -1 backward
        // Chunk pipeline. front is display-owned; pending hand-off is
        // synchronized(this). Invariant: the engine only writes a cache that
        // is neither front nor pending, and front cannot change while a build
        // is in flight (adoption requires a pending chunk, and pending stays
        // -1 until the build publishes).
        val caches = arrayOf(Cache(), Cache())
        @Volatile var front = -1
        var pending = -1
        val building = AtomicBoolean(false)
        var flipGen = 0L
        var lastBuiltMode = false
        // Governor state. stride is written by the engine thread, read by the
        // display tick; pasteEmaMs the reverse.
        @Volatile var stride = MAX_STRIDE
        var firstChunk = true
        var upHold = 0
        var renderEmaMs = 0.0           // engine ms per rendered frame
        @Volatile var pasteEmaMs = 0.0  // display ms per displayed frame
        val rgba: ByteBuffer = avatar.newFrameBuffer()
        val bitmap: Bitmap =
            Bitmap.createBitmap(avatar.width, avatar.height, Bitmap.Config.ARGB_8888)
        // Drive playback is paced by WALL CLOCK (slot = elapsed / 40 ms): a
        // slow engine drops chunk entries (choppy) instead of stretching time.
        var startNs = 0L
        var nextSlot = -1L  // wall slot the next chunk entry is due at
        // True after the pipeline ran EMPTY (engine slower than even the
        // slowest cadence). On resume the backlog is forgiven (nextSlot
        // rebased): a starved engine PAUSES then resumes at cadence —
        // without this, unservable backlog accumulates and every new chunk
        // is instantly consumed by one huge catch-up (skip 23, display 1),
        // degenerating to ~1 displayed frame per chunk (seen in-emulator).
        // Backlog from transient lateness (pipeline non-empty) still
        // catch-up-skips: content drops, time never stretches.
        var stalled = false
        val inFlight = AtomicBoolean(false)
        var future: ScheduledFuture<*>? = null
        val stopped = AtomicBoolean(false)
        val ready = AtomicBoolean(false)
        // validation instrumentation: per-window pacing (logged /100 frames)
        var winNs = 0L      // chunkFrame (paste + RGBA fetch) time
        var winUpNs = 0L    // texture upload (bitmap copy + lockCanvas/draw/post)
        var winFrames = 0
        var winSkipped = 0L // entries dropped to hold wall-clock pace
        var winStalls = 0L  // ticks with an empty pipeline (engine behind)
        var winStartMs = 0L
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "ai.bithuman.avatar")
        channel.setMethodCallHandler(this)
        textureRegistry = binding.textureRegistry
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        sessions.keys.toList().forEach { destroy(it) }
        engineExecutor.shutdown()
        executor.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "load" -> load(call, result)
            "frameSize" -> {
                val s = session(call) ?: return result.error("no_session", null, null)
                result.success(mapOf("width" to s.avatar.width, "height" to s.avatar.height))
            }
            "isReady" -> result.success(session(call)?.ready?.get() ?: false)
            "engineVersion" -> result.success("libelevate-android 0.1.0 (frames)")
            // Agent-audio lifecycle hint from the Dart WebRTC transport.
            // With a motion_ranges sidecar this flips the drive loop between
            // its IDLE and TALKING ranges; without one it is a no-op.
            "setSpeaking" -> {
                val s = session(call)
                val sp = call.argument<Boolean>("speaking") ?: false
                if (s != null && s.speaking != sp) {
                    s.speaking = sp
                    // Drop a prefetched chunk of the now-wrong mode so the
                    // next build (within a tick) renders the fresh mode; the
                    // currently playing chunk keeps motion alive until the
                    // fresh one preempts it (~1 chunk render of latency).
                    synchronized(s) {
                        if (s.pending >= 0 && s.caches[s.pending].speakingMode != sp)
                            s.pending = -1
                    }
                    Log.i(TAG, "setSpeaking($sp)")
                }
                result.success(null)
            }
            "dispose" -> {
                (call.argument<Number>("textureId"))?.let { destroy(it.toLong()) }
                result.success(null)
            }
            // Converse/audio/PiP surface — not on the Android frames path.
            "audioStart", "localAudioStart" -> result.success(false)
            "audioStop", "localAudioStop", "pushAudio", "playSpeakerPCM",
            "interrupt", "setIdleHold", "setDisplayMode", "fitWindowToCanvas",
            "attachWebrtcRemoteAudio", "detachWebrtcRemoteAudio" ->
                result.success(null)
            "pipAvailable" -> result.success(false)
            "pipStart", "pipStop" -> result.success(false)
            else -> result.notImplemented()
        }
    }

    private fun session(call: MethodCall): Session? =
        call.argument<Number>("textureId")?.let { sessions[it.toLong()] }

    private fun load(call: MethodCall, result: Result) {
        val path = call.argument<String>("path")
        val engine = call.argument<String>("engine") ?: "essence"
        if (engine != "elevate" || path == null) {
            result.error("unsupported",
                "Android supports engine='elevate' (le-bundle frames path) only", null)
            return
        }
        // Texture registration must happen on the platform thread
        // (FlutterRenderer.registerSurfaceTexture creates a Handler — throws
        // on the executor). onMethodCall IS the platform thread; register
        // here, then run the heavy create (bundle load + target JPEG decodes)
        // off it.
        val entry = textureRegistry.createSurfaceTexture()
        val loadT0 = System.nanoTime()
        executor.execute {
            try {
                // Prefer the batch-24 fp16 graph: fp16 on the ORT CPU EP
                // (MLAS NEON) is ~1.18x over fp32 and b24 amortizes another
                // ~1.4x per frame (runtime-cpu/ANDROID_RESULTS.md); big-core
                // pinning is on by default in ElevateFrames. Bundles without
                // the staged graph fall back down the chain (the chunk
                // pipeline is batch-agnostic; b1 = chunks of 1).
                var avatar: ElevateFrames? = null
                for (model in listOf("b24_fp16", "b24_fp32", "b1_fp16", "b1_fp32")) {
                    try {
                        avatar = ElevateFrames(path, model = model)
                        Log.i(TAG, "model $model loaded (batch ${avatar.batch})")
                        break
                    } catch (e: Exception) {
                        Log.i(TAG, "model $model unavailable (${e.message})")
                    }
                }
                if (avatar == null) throw RuntimeException("no m4b model graph in $path")
                entry.surfaceTexture().setDefaultBufferSize(avatar.width, avatar.height)
                val s = Session(avatar, entry, Surface(entry.surfaceTexture()),
                    loadMotionRanges(path, avatar.driveFrames), loadT0)
                sessions[entry.id()] = s
                maybeBuild(s)  // first chunk starts rendering immediately
                s.future = executor.scheduleAtFixedRate(
                    { renderTick(s) }, 0, SLOT_MS, TimeUnit.MILLISECONDS)
                channelPost { result.success(entry.id().toInt()) }
            } catch (e: Exception) {
                Log.e(TAG, "load failed", e)
                channelPost {
                    entry.release()
                    result.error("load_failed", e.message, null)
                }
            }
        }
    }

    // ---- engine side: chunk builds ----

    /// Kicks a chunk build if the pipeline has room (no pending chunk and no
    /// build in flight). Called from the display tick — the 40 ms cadence is
    /// the pipeline's only wake-up source, which keeps this allocation-free.
    private fun maybeBuild(s: Session) {
        if (s.stopped.get()) return
        synchronized(s) { if (s.pending >= 0) return }
        if (!s.building.compareAndSet(false, true)) return
        engineExecutor.execute {
            try {
                if (!s.stopped.get()) buildChunk(s)
            } catch (e: Exception) {
                if (!s.stopped.get()) Log.e(TAG, "buildChunk", e)
            } finally {
                s.building.set(false)
            }
        }
    }

    /// Renders the next `batch` drive frames (cursor advanced `stride` per
    /// entry — the governed cadence drops drive frames, it does not slow the
    /// motion down) into the cache that is not being displayed.
    private fun buildChunk(s: Session) {
        val mode = s.speaking  // sampled once; entries are single-mode
        val cacheIdx = if (s.front == 0) 1 else 0
        val n = s.avatar.batch
        val stride = s.stride
        val idx = IntArray(n)
        if (s.motion == null) {
            var p = s.pos
            for (k in 0 until n) { p = (p + stride) % s.avatar.driveFrames; idx[k] = p }
            s.pos = p
        } else {
            for (k in 0 until n) idx[k] = advanceCursor(s, stride.toLong(), mode)
        }
        if (mode != s.lastBuiltMode) { s.flipGen++; s.lastBuiltMode = mode }
        val t0 = System.nanoTime()
        if (!s.avatar.renderChunk(cacheIdx, idx)) {
            Log.e(TAG, "renderChunk failed (cache $cacheIdx, n=$n)")
            return
        }
        val perF = (System.nanoTime() - t0) / 1e6 / n
        // validation instrumentation: every submit must be the FULL batch (a
        // partial b24 chunk charges whole-batch cost to fewer frames — the
        // ~2-20x pathology in ANDROID_RESULTS.md §Chunk-batch sweep), and in
        // gated mode every index must sit inside the active range.
        Log.d(TAG, "chunk: cache=%d n=%d stride=%d mode=%s idx[%d..%d] %.1f ms/f"
            .format(cacheIdx, n, stride, if (mode) "T" else "I",
                idx.min(), idx.max(), perF))
        s.renderEmaMs = if (s.renderEmaMs == 0.0) perF else 0.7 * s.renderEmaMs + 0.3 * perF
        val c = s.caches[cacheIdx]
        c.count = n
        c.displayed = 0
        c.gen = s.flipGen
        c.speakingMode = mode
        governor(s)
        // A flip during this render makes the chunk stale — discard it (the
        // next tick's maybeBuild renders the fresh mode into the same cache).
        if (mode != s.speaking) return
        synchronized(s) { if (!s.stopped.get()) s.pending = cacheIdx }
    }

    /// Sustainable-rate governor: keep engine duty (render+paste ms per
    /// displayed frame over the cadence period) under target. Demote fast,
    /// promote only after UP_HOLD_CHUNKS consecutive chunks of clear headroom.
    private fun governor(s: Session) {
        val per = s.renderEmaMs + s.pasteEmaMs
        if (s.firstChunk) {
            s.firstChunk = false
            var st = 1
            while (st < MAX_STRIDE && per / (SLOT_MS * st) > DUTY_TARGET) st++
            s.stride = st
            Log.i(TAG, "governor: first chunk %.1f ms/f -> %.2f fps (stride %d)"
                .format(per, 25.0 / st, st))
            return
        }
        val duty = per / (SLOT_MS * s.stride)
        if (duty > DUTY_DOWN && s.stride < MAX_STRIDE) {
            s.stride++
            s.upHold = 0
            Log.i(TAG, ("governor: duty %.2f (render %.1f + paste %.1f ms/f) -> " +
                "%.2f fps (stride %d)").format(duty, s.renderEmaMs, s.pasteEmaMs,
                25.0 / s.stride, s.stride))
        } else if (s.stride > 1 && per / (SLOT_MS * (s.stride - 1)) <= DUTY_UP) {
            if (++s.upHold >= UP_HOLD_CHUNKS) {
                s.stride--
                s.upHold = 0
                Log.i(TAG, "governor: headroom (%.1f ms/f) -> %.2f fps (stride %d)"
                    .format(per, 25.0 / s.stride, s.stride))
            }
        } else {
            s.upHold = 0
        }
    }

    // ---- display side: 40 ms tick ----

    private fun renderTick(s: Session) {
        if (s.stopped.get()) return
        // Cheap overrun: queued ticks fall through instantly when a paste is
        // in flight or no chunk entry is due yet.
        if (!s.inFlight.compareAndSet(false, true)) return
        try {
            val now = System.nanoTime()
            if (s.startNs == 0L) s.startNs = now
            val slot = (now - s.startNs) / SLOT_NS
            maybeBuild(s)
            // Adopt a fresher-mode chunk immediately (abandon the stale
            // remainder — this is the mouth-flip taking effect); same-gen
            // chunks are adopted on exhaustion below.
            synchronized(s) {
                val p = s.pending
                if (p >= 0 && (s.front < 0 || s.caches[p].gen > s.caches[s.front].gen)) {
                    s.front = p
                    s.pending = -1
                }
            }
            if (s.front < 0) return  // first chunk still rendering
            if (s.nextSlot < 0) s.nextSlot = slot
            // Coming out of a true stall: the backlog was never servable —
            // forgive it (pause-then-resume at cadence, see `stalled`).
            if (s.stalled) { s.stalled = false; s.nextSlot = slot }
            if (slot < s.nextSlot) return
            // Wall-clock discipline: one entry per `stride` slots; when late,
            // skip entries (content drops, time never stretches).
            var due = (slot - s.nextSlot) / s.stride + 1
            var consumed = 0L
            var entry = -1
            var cacheOf = -1
            while (due > 0) {
                val c = s.caches[s.front]
                if (c.displayed >= c.count) {
                    val adopted = synchronized(s) {
                        val p = s.pending
                        if (p >= 0) { s.front = p; s.pending = -1; true } else false
                    }
                    if (!adopted) {  // engine behind: hold frame, pause clock
                        s.winStalls++
                        s.stalled = true
                        break
                    }
                    maybeBuild(s)
                    continue
                }
                entry = c.displayed
                cacheOf = s.front
                c.displayed++
                due--
                consumed++
            }
            if (entry < 0) return
            s.nextSlot += consumed * s.stride
            s.winSkipped += consumed - 1
            val t0 = System.nanoTime()
            s.rgba.rewind()
            if (!s.avatar.chunkFrame(cacheOf, entry, s.rgba)) return
            val t1 = System.nanoTime()
            s.rgba.rewind()
            s.bitmap.copyPixelsFromBuffer(s.rgba)
            val canvas = try {
                s.surface.lockCanvas(null)
            } catch (e: Exception) {
                if (!s.stopped.get()) Log.w(TAG, "lockCanvas: ${e.message}")
                return
            }
            try {
                canvas.drawBitmap(s.bitmap, 0f, 0f, null)
            } finally {
                s.surface.unlockCanvasAndPost(canvas)
            }
            val t2 = System.nanoTime()
            if (!s.ready.getAndSet(true)) {
                Log.i(TAG, "first frame +%d ms after load() (model+targets+chunk)"
                    .format((t2 - s.loadT0) / 1_000_000))
            }
            // instrumentation: paste + upload ms, achieved fps /100 frames
            s.winNs += t1 - t0
            s.winUpNs += t2 - t1
            s.pasteEmaMs = if (s.pasteEmaMs == 0.0) (t2 - t0) / 1e6
                           else 0.95 * s.pasteEmaMs + 0.05 * (t2 - t0) / 1e6
            s.winFrames += 1
            if (s.winFrames == 100) {
                val nowMs = System.currentTimeMillis()
                val fps = if (s.winStartMs > 0) 100_000.0 / (nowMs - s.winStartMs) else 0.0
                Log.i(TAG,
                    ("perf: paste %.1f + upload %.1f ms/frame, render %.1f ms/f, " +
                        "%.1f fps displayed @ stride %d (%.2f target), " +
                        "%d entries skipped, %d stall ticks over last 100 frames")
                        .format(s.winNs / 100 / 1e6, s.winUpNs / 100 / 1e6,
                            s.renderEmaMs, fps, s.stride, 25.0 / s.stride,
                            s.winSkipped, s.winStalls))
                s.winNs = 0; s.winUpNs = 0; s.winFrames = 0
                s.winSkipped = 0; s.winStalls = 0
                s.winStartMs = nowMs
            }
        } catch (e: Exception) {
            if (!s.stopped.get()) Log.e(TAG, "renderTick", e)
        } finally {
            s.inFlight.set(false)
        }
    }

    /// Cursor advance over the active IDLE/TALKING range set (engine thread,
    /// chunk-build time): the cursor ping-pongs inside ONE range (reverse
    /// playback of a face is imperceptible; no seam pops) and advances
    /// `steps` frames per call, so the governed cadence skips drive frames
    /// exactly like the legacy modulo. On a mode flip it jumps to the NEAREST
    /// frame across the target ranges (idle and talking ranges tile the same
    /// protocol, so the nearest frame is a near-identical head pose with the
    /// mouth near the open/close threshold).
    private fun advanceCursor(s: Session, steps: Long, want: Boolean): Int {
        val m = s.motion!!
        var r = s.range
        if (r == null || s.mode != want) {
            val target = m.ranges(want).minByOrNull { c ->
                if (s.pos in c) 0
                else minOf(Math.abs(s.pos - c.first), Math.abs(s.pos - c.last))
            }!!
            val np = s.pos.coerceIn(target.first, target.last)
            if (r != null) {
                Log.i(TAG, "mode -> ${if (want) "TALKING" else "IDLE"} " +
                    "[${target.first},${target.last}] jump ${s.pos} -> $np")
            }
            s.mode = want
            s.range = target
            s.pos = np
            r = target
        }
        val len = r.last - r.first + 1
        if (len <= 1) { s.pos = r.first; return s.pos }
        // Closed-form ping-pong: phase in [0, 2*(len-1)), position = first +
        // (phase < len ? phase : period - phase). O(1) for any `steps`.
        val period = 2L * (len - 1)
        val off = (s.pos - r.first).toLong()
        var ph = (if (s.dir >= 0) off else period - off) + steps
        ph %= period
        if (ph < len) {
            s.pos = r.first + ph.toInt()
            s.dir = if (ph == (len - 1).toLong()) -1 else 1
        } else {
            s.pos = r.first + (period - ph).toInt()
            s.dir = -1
        }
        return s.pos
    }

    /// Parse `<bundle>/motion_ranges.json` (see tools/classify_motion_ranges
    /// .py). Returns null — legacy full-loop behavior — when the sidecar is
    /// absent, malformed, or out of bounds for this protocol.
    private fun loadMotionRanges(dir: String, driveFrames: Int): MotionRanges? {
        val f = java.io.File(dir, "motion_ranges.json")
        if (!f.exists()) return null
        return try {
            val j = org.json.JSONObject(f.readText())
            fun parse(key: String): List<IntRange> {
                val a = j.optJSONArray(key) ?: return emptyList()
                val out = ArrayList<IntRange>(a.length())
                for (k in 0 until a.length()) {
                    val p = a.getJSONArray(k)
                    val r = p.getInt(0)..p.getInt(1)
                    if (r.first in 0..r.last && r.last < driveFrames) out.add(r)
                }
                return out
            }
            val idle = parse("idle")
            val talking = parse("talking")
            if (idle.isEmpty() || talking.isEmpty()) {
                Log.w(TAG, "motion_ranges.json ignored (idle=${idle.size}, talking=${talking.size} usable ranges)")
                return null
            }
            Log.i(TAG, "motion_ranges: ${idle.size} idle $idle + " +
                "${talking.size} talking $talking of $driveFrames drive frames")
            MotionRanges(idle, talking)
        } catch (e: Exception) {
            Log.w(TAG, "motion_ranges.json ignored: ${e.message}")
            null
        }
    }

    private fun destroy(id: Long) {
        val s = sessions.remove(id) ?: return
        s.stopped.set(true)
        s.future?.cancel(false)
        // Drain the engine thread first (a chunk render may be in flight),
        // then close on the display executor (serialized with render ticks).
        engineExecutor.execute {
            executor.execute {
                s.surface.release()
                s.entry.release()
                s.avatar.close()
            }
        }
    }

    private fun channelPost(body: () -> Unit) {
        android.os.Handler(android.os.Looper.getMainLooper()).post { body() }
    }
}
