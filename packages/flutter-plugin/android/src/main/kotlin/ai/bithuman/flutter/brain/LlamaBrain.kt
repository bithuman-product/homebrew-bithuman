package ai.bithuman.flutter.brain

/**
 * The LLM leg of the on-device brain: llama.cpp on the CPU behind `libbhbrain.so`
 * (src/main/cpp). One model, one context, one conversation. See bh_llm_jni.cpp for
 * the cache-reuse and cancel rules; this class only carries the handle.
 *
 * Not thread-safe for concurrent [generate] calls — [ConverseEngine] runs all
 * generation on one thread. [cancel] is safe from any thread.
 */
internal class LlamaBrain private constructor(private var handle: Long) : ReplyModel {

    /** Receives each generated piece as raw UTF-8 bytes; return false to stop. */
    fun interface PieceSink { fun onPiece(bytes: ByteArray): Boolean }

    /** [roles]/[contents] are the whole conversation, system first, ending with the user turn. */
    fun generate(roles: Array<String>, contents: Array<ByteArray>, maxTokens: Int, temperature: Float,
                 seed: Int, sink: PieceSink): Int =
        nativeGenerate(handle, roles, contents, maxTokens, temperature, seed, sink)

    /**
     * [ReplyModel]: the template is the model's own (applied natively); pieces arrive as
     * UTF-8 bytes and are handed on only as whole characters.
     */
    override fun generate(messages: List<Pair<String, String>>, maxTokens: Int, temperature: Float,
                          onText: (String) -> Boolean): Int {
        val pending = java.io.ByteArrayOutputStream()
        return generate(messages.map { it.first }.toTypedArray(), messages.map { it.second.toByteArray() }.toTypedArray(),
            maxTokens, temperature, (System.nanoTime() and 0x7fffffff).toInt()) { piece ->
            pending.write(piece)
            val all = pending.toByteArray()
            val ok = completeUtf8(all)
            if (ok == 0) return@generate true
            pending.reset(); if (ok < all.size) pending.write(all, ok, all.size - ok)
            onText(String(all, 0, ok, Charsets.UTF_8))
        }
    }

    override fun cancel() = nativeCancel(handle)
    override fun reset() = nativeReset(handle)
    override fun lastStats(): String = nativeLastStats(handle)

    override fun close() {
        if (handle != 0L) { nativeFree(handle); handle = 0L }
    }

    companion object {
        init { System.loadLibrary("bhbrain") }

        /** Length of the longest prefix of [b] made of complete UTF-8 sequences. */
        fun completeUtf8(b: ByteArray): Int {
            var k = 0
            while (k < 4 && b.size - k - 1 >= 0) {
                val c = b[b.size - k - 1].toInt() and 0xFF
                if (c and 0xC0 != 0x80) {
                    val need = when { c < 0x80 -> 1; c >= 0xF0 -> 4; c >= 0xE0 -> 3; c >= 0xC0 -> 2; else -> 1 }
                    return if (k + 1 >= need) b.size else b.size - k - 1
                }
                k++
            }
            return b.size
        }

        /** Null when the model cannot be loaded (the reason is in logcat under `bhbrain`). */
        fun load(path: String, nCtx: Int = 2048, threads: Int = 4, threadsBatch: Int = 4, gpuLayers: Int = 0): LlamaBrain? {
            val h = nativeLoad(path, nCtx, threads, threadsBatch, gpuLayers)
            return if (h == 0L) null else LlamaBrain(h)
        }

        @JvmStatic private external fun nativeLoad(path: String, nCtx: Int, threads: Int, threadsBatch: Int, gpuLayers: Int): Long
        @JvmStatic private external fun nativeGenerate(h: Long, roles: Array<String>, contents: Array<ByteArray>,
                                                       maxTokens: Int, temp: Float, seed: Int, sink: PieceSink): Int
        @JvmStatic private external fun nativeCancel(h: Long)
        @JvmStatic private external fun nativeReset(h: Long)
        @JvmStatic private external fun nativeLastStats(h: Long): String
        @JvmStatic private external fun nativeFree(h: Long)
    }
}
