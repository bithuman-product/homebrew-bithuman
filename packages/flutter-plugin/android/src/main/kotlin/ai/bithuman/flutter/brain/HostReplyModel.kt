package ai.bithuman.flutter.brain

import android.os.SystemClock
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * The reply stage supplied by the app ("hybrid" brain): speech in and the voice stay on the
 * device, and the reply text comes from wherever the app gets it — typically a cheap cloud
 * text model behind the app's own server, so no model key ever sits on the phone.
 *
 * The same shape as libconverse 2.5.0's host LLM (`bc_session_create_with_llm`): the engine
 * keeps everything around the model — the crisis guard (a crisis turn never reaches the host),
 * the bounded history, clause chunking, emoji/markdown stripping, the voice and barge-in — and
 * the host only streams text.
 *
 * Flow: [generate] calls [request] (`reply_request` {id, messages} to Dart) and then waits for
 * the pieces the app hands back through [push] (`localReplyText` {id, text, done, result}).
 * A barge-in, or the engine having enough sentences, ends the wait at once and calls
 * [cancelRequest] (`reply_cancel` {id} to Dart) so the app can drop its HTTP stream: nothing
 * the host sends for an old id is ever spoken.
 */
internal class HostReplyModel(
    private val request: (id: Int, messages: List<Pair<String, String>>, maxTokens: Int) -> Unit,
    private val cancelRequest: (id: Int) -> Unit,
    /** No first piece within this long: the turn fails (the engine then says its error reply). */
    private val firstPieceTimeoutMs: Long = 12_000,
    /** A stream that stalls this long after its first piece is treated as finished. */
    private val stallTimeoutMs: Long = 8_000,
    /** Monotonic milliseconds (injectable so the JVM unit tests run without android.os). */
    private val clock: () -> Long = { SystemClock.elapsedRealtime() },
) : ReplyModel {
    private class Piece(val id: Int, val text: String, val done: Boolean, val result: Int)

    private val pieces = LinkedBlockingQueue<Piece>()
    private val ids = AtomicInteger(0)
    @Volatile private var current = -1
    @Volatile private var cancelled = false
    @Volatile private var stats = ""

    /** The last finished stream's result (one of the RESULT_* codes). */
    @Volatile var lastResult = RESULT_OK
        private set

    override fun generate(messages: List<Pair<String, String>>, maxTokens: Int, temperature: Float,
                          onText: (String) -> Boolean): Int {
        val id = ids.incrementAndGet()
        pieces.clear()
        cancelled = false
        lastResult = RESULT_OK
        current = id
        val t0 = clock()
        var n = 0
        var firstMs = -1L
        var lastAt = t0
        var why = "done"
        try {
            request(id, messages, maxTokens)
            while (true) {
                if (cancelled) { why = "cancelled"; cancelRequest(id); return n }
                val p = pieces.poll(10, TimeUnit.MILLISECONDS)
                val now = clock()
                if (p == null) {
                    if (n == 0 && now - t0 > firstPieceTimeoutMs) {
                        why = "no first piece in ${firstPieceTimeoutMs} ms"; lastResult = RESULT_ERROR; cancelRequest(id); return -1
                    }
                    if (n > 0 && now - lastAt > stallTimeoutMs) { why = "stalled"; cancelRequest(id); return n }
                    continue
                }
                if (p.id != id) continue
                if (p.text.isNotEmpty()) {
                    if (firstMs < 0) firstMs = now - t0
                    n++; lastAt = now
                    if (!onText(p.text)) { why = "stopped by the engine"; cancelRequest(id); return n }
                }
                if (p.done) {
                    lastResult = p.result
                    if (p.result != RESULT_OK) why = "host result ${p.result}"
                    return if (p.result == RESULT_OK || n > 0) n else -1
                }
            }
        } finally {
            current = -1
            stats = "host id=$id pieces=$n firstPieceMs=$firstMs totalMs=${clock() - t0} end=$why"
        }
    }

    /** A piece of the reply for request [id] (any thread). Pieces for any other id are dropped. */
    fun push(id: Int, text: String, done: Boolean, result: Int = RESULT_OK) {
        if (id == current) pieces.offer(Piece(id, text, done, result))
    }

    override fun cancel() { cancelled = true }

    override fun reset() {}

    override fun lastStats(): String = stats

    override fun close() { cancelled = true }

    companion object {
        // bc_llm_result
        const val RESULT_OK = 0
        const val RESULT_REFUSED = 1
        const val RESULT_CONTEXT_FULL = 2
        const val RESULT_ERROR = 3
    }
}
