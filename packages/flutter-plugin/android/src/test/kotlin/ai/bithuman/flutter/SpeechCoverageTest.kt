// Speech coverage as a viewer sees it (SpeechCoverage.kt): unique speech frames shown ÷ frames due
// for the audio played, per utterance, and a FROZEN line when a second of voice showed under half
// its frames. Plain JVM:
//   (cd <app>/android && ./gradlew :bithuman:testDebugUnitTest --tests 'ai.bithuman.flutter.SpeechCoverageTest')

package ai.bithuman.flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SpeechCoverageTest {
    private val lines = ArrayList<String>()
    private fun cov() = SpeechCoverage(25, log = { lines.add(it) })
    /** [n] units of turn [t]: 'S' shown new frame, 'C' audio under the held frame, 'K' an S coalesced, 'H' silence. */
    private fun SpeechCoverage.play(t: Int, pattern: String) {
        for (k in pattern) when (k) {
            'S' -> onSpeechUnit(t, carriesAudio = true, newFrame = true)
            'C', 'T' -> onSpeechUnit(t, carriesAudio = true, newFrame = false)
            'K' -> onSpeechUnit(t, carriesAudio = true, newFrame = false)
            'H' -> onSpeechUnit(t, carriesAudio = false, newFrame = false)
        }
    }

    @Test
    fun a_face_in_step_reads_100_percent_and_never_frozen() {
        val c = cov()
        c.play(1, "S".repeat(125)); c.endUtterance()
        assertEquals(listOf("UTT 1 unique=125 due=125 cov=100% frozen=0ms episodes=0"), lines)
        assertEquals(100, c.coveragePct)
    }

    @Test
    fun a_held_frame_re_shown_under_its_audio_is_due_but_not_shown() {
        // The frozen face the old line called 86-93%: one new frame, then its frame held under 9 units of audio.
        val c = cov()
        c.play(1, ("S" + "C".repeat(9)).repeat(10)); c.endUtterance()
        // Below half from the 25th unit (1.0 s), flagged once that has lasted a second (unit 50), to the end.
        assertTrue(lines.toString(), lines.any { it.startsWith("FROZEN utterance=1 at=1000ms: under 50% unique frames for 1000ms") })
        assertEquals("UTT 1 unique=10 due=100 cov=10% frozen=3000ms episodes=1", lines.last())
        assertEquals(10, c.coveragePct)
    }

    @Test
    fun frozen_needs_more_than_a_second_below_half_and_ends_when_it_recovers() {
        val c = cov()
        c.play(1, "S".repeat(25))            // 1 s in step
        c.play(1, "C".repeat(13))            // the last second drops to 12/25 at unit 38
        c.play(1, "S".repeat(13))            // back to 13/25 at unit 51: a 0.52 s dip, not flagged
        assertTrue("a short dip is not a frozen face: $lines", lines.none { it.startsWith("FROZEN") })
        c.play(1, "C".repeat(60))            // below half from unit 64 (a window of 12 unique)
        assertTrue(lines.toString(), lines.last().startsWith("FROZEN utterance=1 at=2560ms: under 50% unique frames for 1000ms"))
        c.play(1, "S".repeat(13))            // the last second back to 13/25
        assertTrue(lines.last(), lines.last().startsWith("FROZEN-END utterance=1 after 2400ms"))
        c.endUtterance()
        assertEquals("UTT 1 unique=51 due=124 cov=41% frozen=2400ms episodes=1", lines.last())
    }

    @Test
    fun coalesced_frames_count_as_due_silence_does_not_and_turns_split_utterances() {
        val c = cov()
        c.play(1, "SKSKHHH")                 // two shown, two coalesced, silence not due
        c.play(2, "SSS")                     // a new reply: utterance 1 closes
        c.endUtterance(); c.endUtterance()   // idle twice: one summary
        assertEquals(listOf(
            "UTT 1 unique=2 due=4 cov=50% frozen=0ms episodes=0",
            "UTT 2 unique=3 due=3 cov=100% frozen=0ms episodes=0"), lines)
        assertEquals(5L, c.uniqueTotal); assertEquals(7L, c.dueTotal); assertEquals(2, c.utterances)
    }

    @Test
    fun an_utterance_that_ends_frozen_says_so() {
        val c = cov()
        c.play(1, "S" + "C".repeat(60)); c.endUtterance()
        assertTrue(lines.toString(), lines.any { it.startsWith("FROZEN-END utterance=1 after 1440ms") && it.endsWith("the utterance ended frozen") })
        assertTrue(lines.last(), lines.last().startsWith("UTT 1 unique=1 due=61 cov=1% frozen=1440ms episodes=1"))
    }
}
