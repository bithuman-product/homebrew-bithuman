// A Flutter texture's release, and the order in which the plugin lets go of its textures when the
// Flutter engine detaches. Nothing here imports Android or Flutter, so the order runs on a plain
// JVM (src/test/kotlin/ai/bithuman/flutter/TextureGateTest.kt), as EngineUsers.kt's does.
//
// ★WHY (2.6.27). "FlutterJNI is not attached to native" in
// FlutterRenderer$ImageReaderSurfaceProducer.onImage, after Back on the call screen (Galaxy S24,
// 1 run in 4, 2026-09-30). The avatar's texture (a SurfaceProducer: an ImageReader) was released
// only at the END of a dispose: a bh-dispose thread first waited for the player's threads, and a
// main.post then called entry.release(). When the Flutter engine itself goes away, FlutterEngine
// .destroy() detaches the plugins and then lets FlutterJNI go of native in the SAME main-thread
// message, so that post ran with FlutterJNI already detached. Worse, the last frame the presenter
// drew had queued an onImageAvailable callback on the main looper; it ran on a producer that was
// not released yet, onImage asked FlutterJNI for a frame, and FlutterJNI threw. An exception on the
// main thread ends the app.
//
// Now the texture goes FIRST and synchronously: in onDetachedFromEngine, while FlutterJNI is still
// attached, every session is stopped and its texture released before any asynchronous close
// starts, and the texture of a load still in flight is released too. A released producer closes
// any image still queued for it instead of calling onImage, a draw after the release is a no-op,
// and the release itself runs once however many paths ask for it (the detach, the end of the
// dispose, a load that finishes after the detach).

package ai.bithuman.flutter

/**
 * One texture's release. [release] and [draw] run on the platform (main) thread, the one thread
 * Flutter allows a SurfaceProducer to be released on and the one the presenter draws on, so a draw
 * and the release never overlap; the flags are volatile so any other thread reads them current.
 */
class TextureGate(private val releaseProducer: () -> Unit) {
    /** The producer was released (or a release was asked for): nothing may be drawn into it again. */
    @Volatile var released = false
        private set

    /**
     * The producer took its surface away (SurfaceProducer.Callback.onSurfaceCleanup) and has not
     * handed out a new one yet (onSurfaceAvailable). A frame drawn now would go to a dead surface.
     */
    @Volatile var surfaceGone = false

    /** Whether a frame may be drawn now. */
    val open: Boolean get() = !released && !surfaceGone

    /**
     * Releases the producer, once: a second call (the end of a dispose after the detach already
     * released it) does nothing. True when this call released it. An exception from the producer
     * is the caller's to log; the gate is closed either way.
     */
    fun release(): Boolean {
        if (released) return false
        released = true
        releaseProducer()
        return true
    }

    /** Runs [frame] only while the gate is [open]; true when it ran. */
    inline fun draw(frame: () -> Unit): Boolean {
        if (!open) return false
        frame()
        return true
    }
}

/**
 * The plugin's textures across one attachment to a Flutter engine: the loads still in flight and
 * the order of the detach. Platform thread only.
 */
class TextureGates {
    /** The engine let go of the plugin. Set by [detach], cleared by [attach]. */
    var detached = false
        private set

    /** Textures created for a load that has not finished (or failed) yet. */
    private val pending = LinkedHashSet<TextureGate>()

    fun attach() { detached = false }

    /** A load created [gate]'s texture and went off the platform thread. */
    fun loadStarted(gate: TextureGate) { pending += gate }

    /**
     * A load finished (back on the platform thread). True: register the session as usual. False:
     * the engine detached while the load ran; the texture is released NOW (a no-op when the detach
     * already released it) and the caller closes what the load made instead of registering it.
     */
    fun loadFinished(gate: TextureGate): Boolean {
        pending -= gate
        if (!detached) return true
        gate.release()
        return false
    }

    /** A load failed or was cancelled: its texture is released now. */
    fun loadFailed(gate: TextureGate) {
        pending -= gate
        gate.release()
    }

    /** Textures of loads still in flight (for logs). */
    val inFlight: Int get() = pending.size

    /**
     * The engine's detach, in the one safe order: every live session is [quiesce]d (stopped, its
     * texture released) and every in-flight load's texture released, ALL before [closeAsync] starts
     * the first asynchronous close. Everything up to [closeAsync] runs in this call, on the platform
     * thread, while FlutterJNI is still attached.
     */
    fun <S> detach(live: Collection<S>, quiesce: (S) -> Unit, closeAsync: (S) -> Unit) {
        detached = true
        val sessions = live.toList()
        sessions.forEach(quiesce)
        val loads = pending.toList()
        pending.clear()
        loads.forEach { it.release() }
        sessions.forEach(closeAsync)
    }
}
