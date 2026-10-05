package ai.bithuman.flutter.brain

import org.junit.Assert.assertEquals
import org.junit.Test

/** The voice chunker's first-audio rule: the same as libconverse on Apple (3 words, 2 clause chunks). */
class ChunkerTest {
    /** Feeds [text] the way a model streams it (a few characters at a time) and flushes. */
    private fun chunks(text: String, c: TextShaping.Chunker = TextShaping.Chunker()): List<String> {
        val out = ArrayList<String>()
        var i = 0
        while (i < text.length) { out += c.push(text.substring(i, minOf(text.length, i + 4))); i += 4 }
        c.flush()?.let { out += it }
        return out
    }

    @Test fun firstTwoChunksMayEndAtAClauseOfThreeWords() {
        assertEquals(
            listOf("Sure thing, my friend,", "here is the plan,", "we start small and practice a little, then we grow."),
            chunks("Sure thing, my friend, here is the plan, we start small and practice a little, then we grow."))
    }

    @Test fun aShortLeadClauseWaitsForMoreWords() {
        // "Well," alone is one word: it rides with the rest of the sentence.
        assertEquals(listOf("Well, there are so many things I could tell you about that.", "First, it helps."),
            chunks("Well, there are so many things I could tell you about that. First, it helps."))
    }

    @Test fun sentencesStayWholeAfterTheClauseChunks() {
        assertEquals(listOf("Oh, that is wonderful,", "I love that.", "Tell me more, please, about it."),
            chunks("Oh, that is wonderful, I love that. Tell me more, please, about it."))
    }

    @Test fun theOldRuleIsOneClauseChunkOfFourWords() {
        assertEquals(listOf("Sure thing, my friend,", "here is the plan, we go."),
            chunks("Sure thing, my friend, here is the plan, we go.", TextShaping.Chunker(4, clauseChunks = 1)))
        assertEquals(listOf("Oh, that is great, I love it."),
            chunks("Oh, that is great, I love it.", TextShaping.Chunker(5, clauseChunks = 1)))
    }

    @Test fun aFirstChunkFloorHoldsShortOpeningsBack() {
        // A floor of 6: no first chunk under 6 words, at a clause or a sentence end; later chunks keep the
        // usual rules.
        val floor = { TextShaping.Chunker(3, clauseChunks = 2, firstFloorWords = 6) }
        assertEquals(listOf("Aw, hi friend! I'm not a doctor,", "but for kids your age,", "espresso is not great."),
            chunks("Aw, hi friend! I'm not a doctor, but for kids your age, espresso is not great.", floor()))
        assertEquals(listOf("Oh heck yes, you've got the makings of something delicious,", "penguin-style!"),
            chunks("Oh heck yes, you've got the makings of something delicious, penguin-style!", floor()))
        assertEquals(listOf("Oh pup, I'm sorry that day got so rough on you.", "That's heavy on the heart,"),
            chunks("Oh pup, I'm sorry that day got so rough on you. That's heavy on the heart,", floor()))
        // A reply shorter than the floor is spoken whole when the stream ends.
        assertEquals(listOf("Sure! Sounds good."), chunks("Sure! Sounds good.", floor()))
        // No floor: the short opening goes first.
        assertEquals(listOf("Aw, hi friend!", "I'm not a doctor,", "but that is fine."),
            chunks("Aw, hi friend! I'm not a doctor, but that is fine."))
    }

    @Test fun androidsDefaultFloorHoldsOpeningsOfUpToThreeWords() {
        // ConverseEngine's default (FIRST_CHUNK_FLOOR_WORDS = 4): a 2- or 3-word opening rides with what
        // follows; a 4-word clause goes first, as without a floor.
        val d = { TextShaping.Chunker(3, clauseChunks = 2, firstFloorWords = ConverseEngine.FIRST_CHUNK_FLOOR_WORDS) }
        assertEquals(listOf("Hi there! How are you doing today?", "Tell me more."),
            chunks("Hi there! How are you doing today? Tell me more.", d()))
        assertEquals(listOf("Oh heck yes, you've got the makings of something delicious,", "penguin-style!"),
            chunks("Oh heck yes, you've got the makings of something delicious, penguin-style!", d()))
        assertEquals(listOf("Oh mornings are lovely,", "aren't they?"),
            chunks("Oh mornings are lovely, aren't they?", d()))
    }

    @Test fun decimalsAndAbbreviationsDoNotSplit() {
        assertEquals(listOf("Mr. Smith paid 3.5 dollars today."), chunks("Mr. Smith paid 3.5 dollars today."))
    }
}
