package ai.bithuman.flutter.brain

/**
 * Everything the brain does to text between the model and the voice: the persona and
 * its house rules, the crisis guard, emoji/markdown stripping, and cutting the streamed
 * reply into speakable chunks. Pure functions — unit-testable off device.
 */
internal object TextShaping {

    /**
     * The built-in persona when the app passes none: Wise Pup, the free tier's avatar.
     * Short spoken replies, a cartoon dog who never claims to be human, no romance.
     */
    const val WISE_PUP_PROMPT =
        "You are Wise Pup, a friendly, witty cartoon dog who chats with people in a phone app. " +
        "Reply in one or two short, playful sentences meant to be spoken aloud, under 35 words. " +
        "You are a cartoon dog and an AI: never claim to be human, and say so if asked. " +
        "Keep it kind and family-friendly: no romance, no flirting, no dating role-play. " +
        "No emojis, no lists, no markdown, no stage directions."

    /**
     * Appended to ANY persona (the app's own included), because a 1B model forgets rules
     * that are only stated once in a long prompt and these are not negotiable.
     */
    const val HOUSE_RULES =
        " Rules that always apply: never say you are human; no romantic or sexual role-play; " +
        "no emojis or markdown; keep replies short and speakable. If the user mentions suicide, " +
        "self-harm, or being in danger, drop the character and tell them kindly to call or text 988 " +
        "(US Suicide and Crisis Lifeline) or their local emergency number."

    fun systemPrompt(appPrompt: String?): String =
        (if (appPrompt.isNullOrBlank()) WISE_PUP_PROMPT else appPrompt.trim()) + HOUSE_RULES

    /**
     * The crisis guard does not ask the 1B model: a deterministic match on the user's words
     * answers with a fixed, reviewed message and stops the role-play for that turn.
     */
    private val crisis = Regex(
        "\\b(kill(ing)? my ?self|suicid\\w*|end(ing)? my life|want to die|wanna die|self[- ]?harm\\w*|" +
        "hurt(ing)? my ?self|cut(ting)? my ?self|take my (own )?life|no reason to live|better off dead|overdos\\w*)\\b",
        RegexOption.IGNORE_CASE)

    const val CRISIS_REPLY =
        "I'm going to step out of the game for a moment, because what you said really matters. " +
        "You deserve support from a real person right now. Please call or text 9 8 8 to reach the " +
        "Suicide and Crisis Lifeline, or call your local emergency number if you are in danger."

    fun isCrisis(userText: String): Boolean = crisis.containsMatchIn(userText)

    /** Remove emoji, markdown and *stage directions* so neither the voice nor the caption carries them. */
    fun clean(s: String): String {
        var t = s.replace(Regex("\\*[^*\\n]{1,60}\\*"), " ")          // *wags tail*
        val sb = StringBuilder(t.length)
        var i = 0
        while (i < t.length) {
            val cp = t.codePointAt(i)
            i += Character.charCount(cp)
            if (isEmoji(cp)) continue
            when (cp) {
                '*'.code, '#'.code, '`'.code, '_'.code, '~'.code, '>'.code, '|'.code -> continue
            }
            sb.appendCodePoint(cp)
        }
        t = sb.toString()
        return t.replace(Regex("[ \\t]{2,}"), " ")
    }

    private fun isEmoji(cp: Int): Boolean =
        cp in 0x1F000..0x1FAFF || cp in 0x2600..0x27BF || cp in 0x2B00..0x2BFF || cp in 0x2300..0x23FF ||
        cp in 0x1F1E6..0x1F1FF || cp == 0xFE0F || cp == 0xFE0E || cp == 0x200D || cp == 0x20E3 ||
        cp in 0xE0020..0xE007F || cp == 0x3030 || cp == 0x303D || cp == 0x3297 || cp == 0x3299

    /**
     * Streams model text in, emits speakable chunks out. The first [clauseChunks] chunks are cut
     * early (a clause of >= [firstMinWords] words ending in , ; : —) so the voice starts while the
     * model is still writing and the second chunk is ready before the first has played; later
     * chunks are whole sentences unless a clause runs long. Defaults = libconverse on Apple.
     */
    class Chunker(private val firstMinWords: Int = 3, private val longClauseChars: Int = 90,
                  private val clauseChunks: Int = 2,
                  /**
                   * The FIRST chunk is never cut (at a clause or a sentence end) before it holds this many
                   * words; 0 = no floor. Android: the avatar engines start a reply's mouth only once they
                   * hold ~1.3 s of its audio, and Supertonic voices a 1-3 word line in about the time of
                   * a 6-word one, so such a first chunk is heard LATER, not sooner (see ConverseEngine).
                   */
                  private val firstFloorWords: Int = 0) {
        private val buf = StringBuilder()
        private var emitted = 0
        /** Characters of the pushed text consumed by the chunks cut so far (where the next chunk starts). */
        private var consumed = 0

        fun push(text: String): List<String> = pushWithEnds(text).map { it.first }

        /**
         * [push], each chunk with the position in the WHOLE pushed text (characters, as streamed) it ends
         * at — what a host counts heard characters in (reply_cancel `heardChars`).
         */
        fun pushWithEnds(text: String): List<Pair<String, Int>> {
            buf.append(text)
            val out = ArrayList<Pair<String, Int>>()
            while (true) {
                val cut = findCut() ?: break
                val chunk = buf.substring(0, cut).trim()
                buf.delete(0, cut)
                consumed += cut
                if (chunk.isNotEmpty()) { out.add(chunk to consumed); emitted++ }
            }
            return out
        }

        fun flush(): String? = flushWithEnd()?.first

        fun flushWithEnd(): Pair<String, Int>? {
            val raw = buf.toString(); buf.setLength(0)
            val c = raw.trim()
            consumed += raw.trimEnd().length
            return if (c.isEmpty()) null else (c to consumed).also { emitted++ }
        }

        private fun findCut(): Int? {
            val s = buf
            for (i in s.indices) {
                val ch = s[i]
                val next = if (i + 1 < s.length) s[i + 1] else null
                // A terminator counts only once the next char proves it is not "3.5" / "Mr." mid-word.
                if ((ch == '.' || ch == '!' || ch == '?' || ch == '\n') && next != null && (next.isWhitespace() || next == '"')) {
                    if (ch == '.' && isAbbrev(s, i)) continue
                    if (ch == '\n') return i + 1
                    val w = words(s, i)
                    if (w >= 2 && (emitted > 0 || w >= firstFloorWords)) return i + 1
                }
                if ((ch == ',' || ch == ';' || ch == ':' || ch == '—') && next != null && next.isWhitespace()) {
                    val w = words(s, i)
                    if (emitted < clauseChunks && w >= firstMinWords && (emitted > 0 || w >= firstFloorWords)) return i + 1
                    if (i >= longClauseChars && (emitted > 0 || w >= firstFloorWords)) return i + 1
                }
            }
            return null
        }

        private fun words(s: CharSequence, end: Int): Int {
            var n = 0; var inWord = false
            for (k in 0..end) { val w = !s[k].isWhitespace(); if (w && !inWord) n++; inWord = w }
            return n
        }

        private fun isAbbrev(s: CharSequence, dot: Int): Boolean {
            var k = dot - 1
            while (k >= 0 && s[k].isLetter()) k--
            val word = s.subSequence(k + 1, dot).toString().lowercase()
            return word in setOf("mr", "mrs", "ms", "dr", "st", "vs", "etc", "e.g", "i.e")
        }
    }
}
