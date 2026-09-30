// The system taking a session's sound away, told to Dart (Android).
//
// ★WHY. A phone call answered from its notification leaves the app on screen, so nothing in
// the app's lifecycle changes. The call takes the microphone and the speaker, while the
// realtime session went on, and so did its billing (bitHuman Live, 09-30). Until 2.6.25 the
// plugin held no audio focus and watched no audio mode, so it never knew.
//
// Now, from `audioStart` to `audioStop`, the session holds transient audio focus as a call
// does (USAGE_VOICE_COMMUNICATION, AUDIOFOCUS_GAIN_TRANSIENT), and on API 31+ it also watches
// the audio mode. Dart hears `audioInterruption` on the avatar channel:
//
//   {textureId, state: "began", reason: "call" | "focus", shouldResume: false}
//   {textureId, state: "ended", reason, shouldResume: true}   the focus came back
//
// - "call": the mode says a phone call rings, is answered or is screened.
// - "focus": another app took the audio (an assistant, another app's call), or the focus was
//   refused at the start.
// A focus loss that only asks to duck (a notification's chime) is not an interruption.
//
// Telecom takes the focus first and sets the ringtone mode after it, so a lost focus is
// confirmed CONFIRM_MS later, and the reason is read then. A mode change to a call ends that
// wait at once. A focus lost and regained within that window (a blip) is not reported.
//
// The plugin changes nothing else. BithumanRealtimeSession ends itself on "began" by default,
// and the app decides the rest.

package ai.bithuman.flutter

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.util.Log

internal class AudioInterruptions(
    private val context: Context,
    private val main: Handler,
    /** Platform thread. began = true: the sound was taken; false: it came back. */
    private val emit: (began: Boolean, reason: String, shouldResume: Boolean) -> Unit,
) {
    private val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private var request: AudioFocusRequest? = null
    /** An AudioManager.OnModeChangedListener on API 31+ (typed Any so API 29/30 never resolve the class). */
    private var modeListener: Any? = null
    private var live = false
    private var interrupted = false
    /** The sound is taken right now (platform thread). */
    val isInterrupted: Boolean get() = interrupted
    private var reason = AudioRules.REASON_FOCUS
    private val confirm = Runnable {
        if (live && !interrupted) began(if (AudioRules.isCallMode(am.mode)) AudioRules.REASON_CALL else AudioRules.REASON_FOCUS)
    }

    /** True when the call is free to go on; false when a call already holds the audio (Dart has been told). Platform thread. */
    fun start(): Boolean {
        if (live) return !interrupted
        live = true
        val attrs = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .build()
        val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
            .setAudioAttributes(attrs)
            .setAcceptsDelayedFocusGain(false)
            .setWillPauseWhenDucked(false)
            .setOnAudioFocusChangeListener({ change -> onFocus(change) }, main)
            .build()
        request = req
        val granted = runCatching { am.requestAudioFocus(req) }.getOrDefault(AudioManager.AUDIOFOCUS_REQUEST_FAILED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val l = AudioManager.OnModeChangedListener { mode -> main.post { onMode(mode) } }
            if (runCatching { am.addOnModeChangedListener(context.mainExecutor, l) }.isSuccess) modeListener = l
        }
        val mode = am.mode
        Log.i(TAG, "[bhinterrupt] watching: focus ${if (granted == AudioManager.AUDIOFOCUS_REQUEST_GRANTED) "granted" else "REFUSED ($granted)"} mode=$mode")
        // A call already holds the audio (the mode says so), or the focus was refused (a call's focus,
        // or the platform refusing an app that is not on screen): the session must not go on.
        if (AudioRules.isCallMode(mode)) { began(AudioRules.REASON_CALL); return false }
        if (granted == AudioManager.AUDIOFOCUS_REQUEST_FAILED) { began(AudioRules.REASON_FOCUS); return false }
        return true
    }

    /** Idempotent. Platform thread. */
    fun stop() {
        if (!live) return
        live = false
        main.removeCallbacks(confirm)
        request?.let { r -> runCatching { am.abandonAudioFocusRequest(r) } }
        request = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (modeListener as? AudioManager.OnModeChangedListener)?.let { runCatching { am.removeOnModeChangedListener(it) } }
        }
        modeListener = null
    }

    private fun onFocus(change: Int) {
        if (!live) return
        when (AudioRules.focusChange(change)) {
            AudioRules.Focus.LOST -> if (!interrupted) {
                Log.i(TAG, "[bhinterrupt] focus lost ($change, mode=${am.mode}); confirming")
                main.removeCallbacks(confirm)
                main.postDelayed(confirm, CONFIRM_MS)
            }
            AudioRules.Focus.REGAINED -> {
                main.removeCallbacks(confirm)
                if (interrupted) {
                    interrupted = false
                    Log.i(TAG, "[bhinterrupt] ENDED: focus back ($reason)")
                    emit(false, reason, true)
                }
            }
            AudioRules.Focus.IGNORE -> Log.i(TAG, "[bhinterrupt] focus change $change (duck): the call goes on")
        }
    }

    private fun onMode(mode: Int) {
        if (live && !interrupted && AudioRules.isCallMode(mode)) {
            main.removeCallbacks(confirm)
            began(AudioRules.REASON_CALL)
        }
    }

    private fun began(why: String) {
        interrupted = true
        reason = why
        Log.i(TAG, "[bhinterrupt] BEGAN: $why (mode=${am.mode})")
        emit(true, why, false)
    }

    companion object {
        private const val TAG = "BithumanAvatar"
        /** How long a lost focus waits for the mode to say whether it is a call. */
        const val CONFIRM_MS = 200L
    }
}
