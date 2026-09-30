// The plain decisions behind a session's audio route and its interruptions (Android).
//
// Only constants from the framework are read here (the compiler inlines them), never a
// framework call, so the plain-JVM unit tests (AudioRulesTest) grade these rules exactly as
// they ship. MicCapture applies the route; AudioInterruptions applies the focus rules.

package ai.bithuman.flutter

import android.media.AudioDeviceInfo
import android.media.AudioManager

internal object AudioRules {

    /**
     * Outputs a person connected to hear the call privately, most specific first. While one of
     * these is available the session's sound goes there. The loudspeaker is chosen only when
     * none is ("the earpiece" is never chosen: an avatar call is held at arm's length).
     *
     * ★Until 2.6.25 the microphone forced the loudspeaker as it opened, whatever was
     * connected: a person in Bluetooth earbuds heard the agent from the phone's speaker.
     */
    val PERSONAL = intArrayOf(
        AudioDeviceInfo.TYPE_BLE_HEADSET,       // LE Audio earbuds or headset
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO,     // a classic Bluetooth headset or earbuds (HFP)
        AudioDeviceInfo.TYPE_HEARING_AID,
        AudioDeviceInfo.TYPE_USB_HEADSET,
        AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
        AudioDeviceInfo.TYPE_BLE_SPEAKER,       // an LE Audio speaker the person connected
    )

    fun isPersonal(type: Int): Boolean = PERSONAL.contains(type)

    /**
     * The communication device for a session, by type: the one the system routes to now when it
     * is personal (the person's own choice stands), else the first personal device available,
     * else the loudspeaker. Null when there is nothing to select (the route is left alone).
     */
    fun pickCommunicationDevice(available: List<Int>, current: Int?): Int? {
        if (current != null && isPersonal(current) && current in available) return current
        for (t in PERSONAL) if (t in available) return t
        return if (AudioDeviceInfo.TYPE_BUILTIN_SPEAKER in available) AudioDeviceInfo.TYPE_BUILTIN_SPEAKER else null
    }

    /**
     * Before API 31 there is no communication-device API: what to do with the outputs the system
     * lists. A Bluetooth headset needs its SCO link started; a wired or USB headset needs only the
     * speakerphone off; with nothing personal connected, the speakerphone goes on.
     */
    enum class LegacyRoute { BLUETOOTH_SCO, HEADSET, SPEAKER }

    fun legacyRoute(outputs: List<Int>): LegacyRoute = when {
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO in outputs -> LegacyRoute.BLUETOOTH_SCO
        outputs.any { isPersonal(it) } -> LegacyRoute.HEADSET
        else -> LegacyRoute.SPEAKER
    }

    /**
     * The audio mode says a call owns the audio: a phone call ringing, answered or being screened.
     * (The session's own MODE_IN_COMMUNICATION is not one; a VoIP app's call is seen through the
     * audio focus it takes instead.)
     */
    fun isCallMode(mode: Int): Boolean =
        mode == AudioManager.MODE_RINGTONE || mode == AudioManager.MODE_IN_CALL ||
            mode == AudioManager.MODE_CALL_SCREENING || mode == MODE_CALL_REDIRECT

    /** AudioManager.MODE_CALL_REDIRECT (API 33), named here so the rule reads the same on every level. */
    private const val MODE_CALL_REDIRECT = 5

    enum class Focus { LOST, REGAINED, IGNORE }

    /**
     * What an audio-focus change means for a live session. Lost (for good or for a while: a phone
     * call rings or is answered, another app's call, an assistant) = the session's sound was taken.
     * A loss that only asks us to duck (a notification's chime, a navigation prompt) is ignored:
     * the call goes on.
     */
    fun focusChange(change: Int): Focus = when (change) {
        AudioManager.AUDIOFOCUS_LOSS, AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> Focus.LOST
        AudioManager.AUDIOFOCUS_GAIN, AudioManager.AUDIOFOCUS_GAIN_TRANSIENT,
        AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE, AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK -> Focus.REGAINED
        else -> Focus.IGNORE
    }

    const val REASON_CALL = "call"
    const val REASON_FOCUS = "focus"
}
