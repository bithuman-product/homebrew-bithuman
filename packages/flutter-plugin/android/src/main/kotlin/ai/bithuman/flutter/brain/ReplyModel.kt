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

    /**
     * [generate] for a user turn the engine describes ([ReplyTurn]: the turn as heard, whether it
     * continues the previous one). A model that keeps no conversation of its own ([HostReplyModel])
     * forwards it; the default ignores it.
     */
    fun generate(turn: ReplyTurn, messages: List<Pair<String, String>>, maxTokens: Int, temperature: Float,
                 onText: (String) -> Boolean): Int = generate(messages, maxTokens, temperature, onText)

    /** Stop a running [generate] as soon as possible. Any thread. */
    fun cancel()

    /** Forget any cached conversation state (e.g. a KV cache). */
    fun reset()

    /** One line of timing for the log after each [generate]; empty if the model has none. */
    fun lastStats(): String = ""

    fun close()
}

/**
 * One user turn as the engine hands it to the reply stage: [text] as heard (the WHOLE utterance when
 * [continuation] — the user went on after a pause and the brain cancelled the reply to the first part).
 * [hostId]: the id a [HostReplyModel] gave the request (-1 = none), so the engine can name it in a
 * later `reply_cancel`.
 */
internal class ReplyTurn(val text: String, val continuation: Boolean) {
    @Volatile var hostId = -1
}

