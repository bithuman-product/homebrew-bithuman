// When a reply's first speech unit may skip the silence queued ahead of it (AvatarPlayer's writer,
// "SPEECH START DOES NOT WAIT BEHIND SILENCE"). Plain JVM, no device.
//
// Run from any Flutter app that depends on this plugin:
//   packages/flutter-plugin/scripts/test_android_unit.sh <app dir>

package ai.bithuman.flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SpeechStartTest {

    @Test fun idleAndHeldUnitsAreSilence_speechCatchUpAndTailAreNot() {
        assertTrue(AvatarPlayer.isSilentKind('I'))
        assertTrue(AvatarPlayer.isSilentKind('H'))
        assertFalse(AvatarPlayer.isSilentKind('S'))
        assertFalse(AvatarPlayer.isSilentKind('C'))
        assertFalse(AvatarPlayer.isSilentKind('T'))
    }

    /** The case it exists for: idle units queued ahead of the reply's first speech unit. */
    @Test fun silenceThenSpeech_mayBeSkipped() {
        assertTrue(AvatarPlayer.nextVoicedIsSpeech(listOf('I', 'I', 'S', 'S')))
        assertTrue(AvatarPlayer.nextVoicedIsSpeech(listOf('H', 'H', 'S')))
        assertTrue(AvatarPlayer.nextVoicedIsSpeech(listOf('S')))
    }

    /** Voice under an older frame (catch-up, tail) would be written before any re-base: never skip. */
    @Test fun catchUpOrTailFirst_neverSkipped() {
        assertFalse(AvatarPlayer.nextVoicedIsSpeech(listOf('I', 'C', 'S')))
        assertFalse(AvatarPlayer.nextVoicedIsSpeech(listOf('H', 'T', 'S')))
        assertFalse(AvatarPlayer.nextVoicedIsSpeech(listOf('C')))
    }

    /** Nothing that carries voice is waiting: the silence is played as before. */
    @Test fun onlySilenceQueued_notSkipped() {
        assertFalse(AvatarPlayer.nextVoicedIsSpeech(emptyList()))
        assertFalse(AvatarPlayer.nextVoicedIsSpeech(listOf('I', 'I', 'H')))
    }

    /** The device's depth in units, rounded up; an unreadable buffer never counts as all-silence. */
    @Test fun deviceUnits() {
        assertEquals(4, AvatarPlayer.unitsIn(4800, 1200))   // expression-2: 200 ms at 24 kHz, 20 fps
        assertEquals(4, AvatarPlayer.unitsIn(3840, 960))    // essence-2: 160 ms, 25 fps
        assertEquals(5, AvatarPlayer.unitsIn(4801, 1200))
        assertEquals(Int.MAX_VALUE, AvatarPlayer.unitsIn(-1, 1200))
        assertEquals(Int.MAX_VALUE, AvatarPlayer.unitsIn(4800, 0))
    }
}
