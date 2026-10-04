package ai.bithuman.flutter.brain

/**
 * The reply stage of the on-device brain — the one piece meant to be swapped. The engine
 * owns everything around it (history and its cap, the persona and house rules, the crisis
 * guard, sentence chunking, emoji stripping, barge-in); a model only has to stream text.
 *
 * [LlamaBrain] (llama.cpp, any chat GGUF) is the built-in implementation. Another runtime —
 * LiteRT-LM, an OS model such as Gemini Nano, a different GGUF engine — plugs in through
 * [ConverseEngine.Config.replyModel] without touching the turn logic.
 *
 * Threading: [generate] is called on the engine's single LLM thread, never concurrently;
 * [cancel] may be called from any thread and must make a running [generate] return promptly
 * (a barge-in waits on nothing, but a slow cancel keeps the CPU busy under the next turn).
 */
internal interface ReplyModel {
    /**
     * Stream a reply to [messages] — (role, content) pairs, "system" first, ending with the
     * user's turn. [onText] receives each new piece of text (whole characters); returning
     * false stops generation. Returns the number of tokens (or pieces) produced, 0 when
     * cancelled before the first, -1 on failure.
     */
    fun generate(messages: List<Pair<String, String>>, maxTokens: Int, temperature: Float,
                 onText: (String) -> Boolean): Int

    /** Stop a running [generate] as soon as possible. Any thread. */
    fun cancel()

    /** Forget any cached conversation state (e.g. a KV cache). */
    fun reset()

    /** One line of timing for the log after each [generate]; empty if the model has none. */
    fun lastStats(): String = ""

    fun close()
}
