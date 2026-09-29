// Load progress, the platform-free half: one load's cancel latch and fetch-tick throttle, and
// the queue that hands its events to Dart one at a time. LoadEvents.kt is the channel glue
// around them; nothing here imports Android or Flutter, so it runs on a plain JVM.

package ai.bithuman.flutter

import java.util.concurrent.CancellationException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * One `load` in flight.
 *
 * Cancelling is a three-state latch, so `cancel` answers true exactly when the load WILL end
 * with `load_cancelled`: RUNNING → CANCELLED (a cancel won), or RUNNING → DONE (the engine
 * exists and the load is about to succeed; a cancel after that is too late and says so).
 */
internal class LoadHandle(val code: String, val t0: Long = System.nanoTime()) {
    /** The SDK store's own cancel flag: its fetch checks it before every read. */
    val storeCancel = AtomicBoolean(false)
    private val state = AtomicInteger(RUNNING)

    val cancelled: Boolean get() = state.get() == CANCELLED

    /** Ask this load to stop. True when it was still running, so it will end cancelled. */
    fun cancel(): Boolean {
        if (!state.compareAndSet(RUNNING, CANCELLED)) return false
        storeCancel.set(true)
        return true
    }

    /** Close the cancellable part (the engine exists). False when a cancel got there first. */
    fun finish(): Boolean = state.compareAndSet(RUNNING, DONE)

    /** Between the fetch and the engine create: a cancel that landed stops the load here. */
    fun throwIfCancelled() {
        if (cancelled) throw CancellationException("load of $code cancelled")
    }

    // ---- fetch ticks: called on the loader thread only ----

    /** True once the store reported member bytes, i.e. the identity was not fully cached. */
    @Volatile var fetchedAny = false
        private set
    private var lastTick = 0L
    private var ticked = false

    /**
     * One store progress callback — cumulative bytes of every member of the identity (a
     * resumed partial included) against their exact total — to the event to send, or null
     * while throttled: at most one per [TICK_NS], and always the final one (done == total).
     */
    fun fetchTick(done: Long, total: Long, now: Long = System.nanoTime()): Map<String, Any>? {
        fetchedAny = true
        val last = total in 1..done
        if (ticked && !last && now - lastTick < TICK_NS) return null
        ticked = true
        lastTick = now
        return event(STAGE_FETCH, "done" to done, "total" to total, now = now)
    }

    /** `{code, stage, ms}` plus [extra]; `ms` is the time since this load began. */
    fun event(stage: String, vararg extra: Pair<String, Any>, now: Long = System.nanoTime()): Map<String, Any> {
        val m = HashMap<String, Any>(4 + extra.size)
        m["code"] = code
        m["stage"] = stage
        m["ms"] = (now - t0) / 1_000_000
        for ((k, v) in extra) m[k] = v
        return m
    }

    companion object {
        private const val RUNNING = 0
        private const val CANCELLED = 1
        private const val DONE = 2

        /** ~8 fetch events a second. */
        const val TICK_NS = 125_000_000L

        const val STAGE_FETCH = "fetch"
        const val STAGE_FETCHED = "fetched"
        const val STAGE_PREPARE = "prepare"
        const val STAGE_PREPARED = "prepared"
    }
}

/**
 * Load events to Dart, one at a time: the next goes out only when Dart has answered the last.
 *
 * With a listener that costs nothing (the answer comes back at once). With NO Dart handler on
 * the channel, the one unanswered event waits in the engine's channel buffer and nothing more
 * is sent, so an app that never listens gets no "message discarded" warnings and no backlog:
 * the unsent events of a load are dropped when it returns. A newer fetch tick of a load
 * replaces its queued one (ticks are cumulative); stage events are never merged. Once a
 * listener has answered, an answer that never comes (a hot restart dropped it) stops holding
 * the queue after [ANSWER_TIMEOUT_MS].
 *
 * Confined to one thread (the platform thread): [send]'s `answered` and [schedule]'s block
 * must run there too.
 */
internal class LoadEventQueue(
    private val send: (event: Map<String, Any>, answered: (fromHandler: Boolean) -> Unit) -> Unit,
    private val schedule: (delayMs: Long, block: () -> Unit) -> Unit,
) {
    private val queue = ArrayList<Pair<LoadHandle, Map<String, Any>>>()
    private var serial = 0L
    /** The serial of the event awaiting its answer; 0 = none. */
    private var inFlight = 0L

    /** True while the last answer came from a Dart handler: someone listens. */
    var listening = false
        private set

    val queued: Int get() = queue.size
    val awaitingAnswer: Boolean get() = inFlight != 0L

    fun offer(load: LoadHandle, event: Map<String, Any>) {
        if (event["stage"] == LoadHandle.STAGE_FETCH) {
            queue.removeAll { it.first === load && it.second["stage"] == LoadHandle.STAGE_FETCH }
        }
        queue.add(load to event)
        while (queue.size > MAX_QUEUED) queue.removeAt(0)
        pump()
    }

    /** [load] returned. With nobody listening, whatever of it is unsent is news to no one. */
    fun finished(load: LoadHandle) {
        if (!listening) queue.removeAll { it.first === load }
    }

    fun clear() {
        queue.clear()
    }

    private fun pump() {
        if (inFlight != 0L || queue.isEmpty()) return
        val event = queue.removeAt(0).second
        val id = ++serial
        inFlight = id
        send(event) { fromHandler -> answered(id, fromHandler) }
        if (listening && inFlight == id) {
            schedule(ANSWER_TIMEOUT_MS) {
                if (inFlight == id) {
                    inFlight = 0L
                    pump()
                }
            }
        }
    }

    private fun answered(id: Long, fromHandler: Boolean) {
        // Any answer says whether a handler is there (a dropped message answers "not
        // implemented"); only the awaited one releases the queue.
        listening = fromHandler
        if (inFlight != id) return
        inFlight = 0L
        pump()
    }

    companion object {
        const val MAX_QUEUED = 32
        const val ANSWER_TIMEOUT_MS = 2_000L
    }
}
