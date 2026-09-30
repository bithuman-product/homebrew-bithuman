// The session's audio route and its interruptions, as decided (AudioRules.kt). Plain JVM, no
// device: AudioRules reads only framework constants, which the compiler inlines.
//
// Run from any Flutter app that depends on this plugin:
//   packages/flutter-plugin/scripts/test_android_unit.sh <app dir>

package ai.bithuman.flutter

import android.media.AudioDeviceInfo.TYPE_BLE_HEADSET
import android.media.AudioDeviceInfo.TYPE_BLUETOOTH_A2DP
import android.media.AudioDeviceInfo.TYPE_BLUETOOTH_SCO
import android.media.AudioDeviceInfo.TYPE_BUILTIN_EARPIECE
import android.media.AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
import android.media.AudioDeviceInfo.TYPE_USB_HEADSET
import android.media.AudioDeviceInfo.TYPE_WIRED_HEADSET
import android.media.AudioManager
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AudioRulesTest {

    // ── the route ──────────────────────────────────────────────────────────────────────

    @Test fun nothingConnected_theLoudspeaker_neverTheEarpiece() {
        assertEquals(TYPE_BUILTIN_SPEAKER,
            AudioRules.pickCommunicationDevice(listOf(TYPE_BUILTIN_EARPIECE, TYPE_BUILTIN_SPEAKER), TYPE_BUILTIN_EARPIECE))
    }

    /** The defect: the microphone forced the loudspeaker with Bluetooth earbuds connected. */
    @Test fun bluetoothEarbuds_keepTheCall() {
        assertEquals(TYPE_BLUETOOTH_SCO,
            AudioRules.pickCommunicationDevice(listOf(TYPE_BUILTIN_EARPIECE, TYPE_BUILTIN_SPEAKER, TYPE_BLUETOOTH_SCO), TYPE_BUILTIN_EARPIECE))
        assertEquals(TYPE_BLE_HEADSET,
            AudioRules.pickCommunicationDevice(listOf(TYPE_BUILTIN_SPEAKER, TYPE_BLE_HEADSET), null))
    }

    @Test fun wiredAndUsbHeadsets_keepTheCall() {
        assertEquals(TYPE_WIRED_HEADSET, AudioRules.pickCommunicationDevice(listOf(TYPE_BUILTIN_SPEAKER, TYPE_WIRED_HEADSET), TYPE_BUILTIN_SPEAKER))
        assertEquals(TYPE_USB_HEADSET, AudioRules.pickCommunicationDevice(listOf(TYPE_BUILTIN_SPEAKER, TYPE_USB_HEADSET), null))
    }

    /** Two personal devices: the one the system already routes to stands (the person's choice). */
    @Test fun thePersonsCurrentHeadsetStands() {
        assertEquals(TYPE_WIRED_HEADSET,
            AudioRules.pickCommunicationDevice(listOf(TYPE_BUILTIN_SPEAKER, TYPE_BLUETOOTH_SCO, TYPE_WIRED_HEADSET), TYPE_WIRED_HEADSET))
    }

    /** Earbuds taken out mid-call: the system falls back to the earpiece; the rule moves it to the loudspeaker. */
    @Test fun headsetGone_backToTheLoudspeaker() {
        assertEquals(TYPE_BUILTIN_SPEAKER,
            AudioRules.pickCommunicationDevice(listOf(TYPE_BUILTIN_EARPIECE, TYPE_BUILTIN_SPEAKER), TYPE_BLUETOOTH_SCO))
    }

    @Test fun nothingSelectable_leavesTheRouteAlone() {
        assertNull(AudioRules.pickCommunicationDevice(listOf(TYPE_BUILTIN_EARPIECE), null))
        assertNull(AudioRules.pickCommunicationDevice(emptyList(), null))
    }

    @Test fun beforeApi31_theSameRule() {
        assertEquals(AudioRules.LegacyRoute.SPEAKER, AudioRules.legacyRoute(listOf(TYPE_BUILTIN_EARPIECE, TYPE_BUILTIN_SPEAKER)))
        // A Bluetooth headset lists both profiles; the call needs its SCO link.
        assertEquals(AudioRules.LegacyRoute.BLUETOOTH_SCO,
            AudioRules.legacyRoute(listOf(TYPE_BUILTIN_SPEAKER, TYPE_BLUETOOTH_A2DP, TYPE_BLUETOOTH_SCO)))
        assertEquals(AudioRules.LegacyRoute.HEADSET, AudioRules.legacyRoute(listOf(TYPE_BUILTIN_SPEAKER, TYPE_WIRED_HEADSET)))
        // A2DP alone (music-only headphones) cannot carry a call: the loudspeaker, as before.
        assertEquals(AudioRules.LegacyRoute.SPEAKER, AudioRules.legacyRoute(listOf(TYPE_BUILTIN_SPEAKER, TYPE_BLUETOOTH_A2DP)))
    }

    // ── interruptions ──────────────────────────────────────────────────────────────────

    @Test fun aPhoneCallRingingOrAnswered_isACall() {
        assertTrue(AudioRules.isCallMode(AudioManager.MODE_RINGTONE))
        assertTrue(AudioRules.isCallMode(AudioManager.MODE_IN_CALL))
        assertTrue(AudioRules.isCallMode(AudioManager.MODE_CALL_SCREENING))
    }

    /** The session's own communication mode (and a plain one) is not a call. */
    @Test fun theSessionsOwnMode_isNotACall() {
        assertFalse(AudioRules.isCallMode(AudioManager.MODE_IN_COMMUNICATION))
        assertFalse(AudioRules.isCallMode(AudioManager.MODE_NORMAL))
    }

    @Test fun focusLost_forAWhileOrForGood_isAnInterruption() {
        assertEquals(AudioRules.Focus.LOST, AudioRules.focusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT))
        assertEquals(AudioRules.Focus.LOST, AudioRules.focusChange(AudioManager.AUDIOFOCUS_LOSS))
        assertEquals(AudioRules.Focus.REGAINED, AudioRules.focusChange(AudioManager.AUDIOFOCUS_GAIN))
    }

    /** A notification's chime asks us to duck: the call goes on. */
    @Test fun aDuckRequest_isNotAnInterruption() {
        assertEquals(AudioRules.Focus.IGNORE, AudioRules.focusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK))
    }
}
