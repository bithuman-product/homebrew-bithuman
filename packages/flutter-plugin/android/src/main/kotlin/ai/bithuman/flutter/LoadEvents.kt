// Load progress and cancel for Dart — the Android half of `BithumanAvatar.loadEvents` and
// `BithumanAvatar.cancelLoad`.
//
// `load` fetches the identity by code (a first open: ~160–240 MB) and creates the engine (the
// first open of an Expression 2 identity also compiles it for the device's AI accelerator, a
// one-time step of several seconds) in ONE call, and until now Dart heard nothing until it
// returned. So a wait screen can show real progress, each load reports its stages on the
// 'ai.bithuman.avatar/load' MethodChannel while the call runs:
//
//   event {code, stage: "fetch",    done, total, ms}   cumulative bytes of the identity's
//                                                      members against their exact total (a
//                                                      resumed partial counts); ~8 a second,
//                                                      and always the last one
//   event {code, stage: "fetched",  cached, ms}        every member is on disk and verified;
//                                                      cached = nothing had to be fetched
//   event {code, stage: "prepare",  ms}                the engine is being created
//   event {code, stage: "prepared", ms}                the engine exists; its warm-up follows
//
// `ms` is the time since that load began. Dart may call `cancel {code}`: every load of that
// code still running ends with the error `load_cancelled`. A fetch stops at its next read and
// keeps its partial (the store resumes it with Range next time); an engine create cannot be
// interrupted, so the engine is closed the moment it exists and no player is started. The
// answer is true when a load was cancelled, false when none of that code was running.
//
// Additive: an app that never listens sees no change (LoadEventQueue: at most one event
// waits in the channel buffer, so no "message discarded" warnings), and `load` answers
// exactly as before unless `cancel` was called.

package ai.bithuman.flutter

import android.os.Handler
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CopyOnWriteArrayList

private const val LOAD_TAG = "BithumanAvatar"

internal class LoadEvents(messenger: BinaryMessenger, private val main: Handler) {
    private val channel = MethodChannel(messenger, CHANNEL)
    private val running = CopyOnWriteArrayList<LoadHandle>()
    @Volatile private var closed = false

    /** Platform thread only. */
    private val queue = LoadEventQueue(
        send = { event, answered -> sendToDart(event, answered) },
        schedule = { ms, block -> main.postDelayed({ block() }, ms) },
    )

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "cancel" -> {
                    val code = call.argument<String>("code")
                    if (code.isNullOrBlank()) result.error("bad_args", "cancel needs the agent code", null)
                    else result.success(cancel(code))
                }
                else -> result.notImplemented()
            }
        }
    }

    /** A load of [code] starts. Pair with [end]. */
    fun begin(code: String): LoadHandle = LoadHandle(code).also { running.add(it) }

    /** The load returned (either way); it can no longer be cancelled. */
    fun end(load: LoadHandle) {
        running.remove(load)
        main.post { queue.finished(load) }
    }

    /** Cancel every running load of [code]. True when one was still cancellable. */
    fun cancel(code: String): Boolean {
        var any = false
        for (load in running) if (load.code == code && load.cancel()) any = true
        if (any) Log.i(LOAD_TAG, "load of $code: cancel requested")
        return any
    }

    /**
     * Cancel every running load, whatever its code (sign-out, `BithumanAvatar.clearCredentials`, 2.6.36).
     * True when one was still cancellable. Each ends with `load_cancelled`, as [cancel]'s do.
     */
    fun cancelAll(): Boolean {
        var any = false
        for (load in running) if (load.cancel()) any = true
        if (any) Log.i(LOAD_TAG, "every running load: cancel requested (the app cleared the credentials)")
        return any
    }

    /** The store's progress callback for [load], forwarded (throttled). Loader thread. */
    fun fetchProgress(load: LoadHandle, done: Long, total: Long) {
        load.fetchTick(done, total)?.let { post(load, it) }
    }

    /** The fetch returned: every member is on disk. Loader thread. */
    fun fetched(load: LoadHandle) =
        post(load, load.event(LoadHandle.STAGE_FETCHED, "cached" to !load.fetchedAny))

    fun stage(load: LoadHandle, stage: String) = post(load, load.event(stage))

    /** The engine detached: stop every fetch, send nothing more. */
    fun close() {
        closed = true
        channel.setMethodCallHandler(null)
        for (load in running) load.cancel()
        main.post { queue.clear() }
    }

    private fun post(load: LoadHandle, event: Map<String, Any>) {
        if (closed) return
        main.post { if (!closed) queue.offer(load, event) }
    }

    private fun sendToDart(event: Map<String, Any>, answered: (Boolean) -> Unit) {
        try {
            channel.invokeMethod("event", event, object : MethodChannel.Result {
                override fun success(result: Any?) = answered(true)
                override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) = answered(true)
                override fun notImplemented() = answered(false)
            })
        } catch (e: Exception) {
            Log.w(LOAD_TAG, "load event not sent: $e")
            answered(false)
        }
    }

    companion object {
        const val CHANNEL = "ai.bithuman.avatar/load"
    }
}
