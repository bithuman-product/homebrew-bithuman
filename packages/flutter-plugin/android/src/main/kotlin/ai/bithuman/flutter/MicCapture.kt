package ai.bithuman.flutter

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.AutomaticGainControl
import android.media.audiofx.NoiseSuppressor
import android.content.pm.ApplicationInfo
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log

/**
 * Microphone -> 24 kHz PCM16 chunks, continuous for the life of the session, on the
 * platform's COMMUNICATION path so its echo canceller runs against the avatar's own
 * voice. The Flutter side forwards the chunks over its mic EventChannel exactly as
 * iOS does; the server's turn detector (server_vad) hears the user start and the
 * session cancels the reply — that is the whole interruption path, and it only
 * exists if the microphone is open while the agent talks.
 *
 * What the platform needs from us for the canceller to hold, each measured on a
 * Galaxy S25+ (2026-09-15):
 *
 *  - Source VOICE_COMMUNICATION, and the speaker on USAGE_VOICE_COMMUNICATION
 *    (AvatarPlayer): both ends on the comm stream, or there is no reference signal.
 *
 *  - ★ AudioManager.MODE_IN_COMMUNICATION while the microphone is open. This is what
 *    engages the HAL's tuned canceller on Samsung (WebRTC and every VoIP app set it);
 *    in MODE_NORMAL the residual of the agent's own voice at speakerphone volume
 *    reached the uplink, the server transcribed it as the USER and answered it, and
 *    the earlier fix for that was to ZERO THE MICROPHONE WHILE THE AGENT WAS AUDIBLE
 *    (+1 s tail). That mute was the interruption defect: the user could never be
 *    heard over the agent, so `speech_started` never fired (0 in a 5-minute owner
 *    session). The mode is restored on [stop].
 *
 *  - ★THE ROUTE IS THE PERSON'S (2.6.25). Bluetooth earbuds or a headset (classic SCO or LE
 *    Audio), a wired or USB headset or a hearing aid keep the call; the loudspeaker is selected
 *    only when none is connected, never the earpiece. Until 2.6.25 the loudspeaker was forced
 *    here whatever was connected. Devices that come or go during the call re-route it the same
 *    way (AudioRules.pickCommunicationDevice; `[bhroute]` lines).
 *
 *  - SILENCE IS SENT, NOT NOTHING. Dropping chunks leaves a hole in the uplink and the
 *    resumption reads to the server's turn detector as an onset. The stream is
 *    continuous at 10 chunks/s; the `bhmic` line every second carries the running
 *    count, so a gap is visible as a count that did not advance by 10.
 */
class MicCapture(
    private val context: Context,
    /** One chunk of 24 kHz PCM16 mono, valid for `n` bytes. Called on the capture thread. */
    private val onChunk: (ByteArray, Int) -> Unit,
) {
    @Volatile private var live = false
    /** [stop] was called (platform thread): a start still queued does nothing, one mid-way closes itself. */
    @Volatile private var stopped = false
    private var record: AudioRecord? = null
    private var aec: AcousticEchoCanceler? = null
    private var agc: AutomaticGainControl? = null
    private var ns: NoiseSuppressor? = null
    private var thread: Thread? = null
    private var modeBefore = AudioManager.MODE_NORMAL
    /** This session's turn on the shared audio mode ([modeTurn] when it started). */
    private var turn = 0
    /** API < 31: this session started the Bluetooth SCO link, so it stops it. */
    private var scoStarted = false
    /** API < 31: the SCO link was started and failed (or dropped): the call goes to the speaker. */
    @Volatile private var scoFailed = false
    private var scoReceiver: BroadcastReceiver? = null
    private var deviceCallback: AudioDeviceCallback? = null
    /** API 31+: the device this session selected, and the ones that fell back to the earpiece. */
    private var selected: AudioDeviceInfo? = null
    private val refusedIds = HashSet<Int>()
    /** An AudioManager.OnCommunicationDeviceChangedListener on API 31+ (typed Any for API 29/30). */
    private var commListener: Any? = null

    /** Blocks nothing; the capture runs on its own thread until [stop]. Returns false if the mic did not open. */
    /**
     * Opens the microphone. ★ON THE bh-audio-mode THREAD ONLY ([onModeThread]), never the UI thread
     * (2.6.25): the audio mode, the route, the recorder and the device callbacks held the platform
     * thread ~0.9 s at every dial on a Galaxy Z Flip5 (Choreographer: 104 frames skipped; the
     * AudioManager port cache was busy re-reading the ports the mode change had moved). A previous
     * session's stop queued on the same thread runs first, so mode changes stay in order.
     */
    fun start(): Boolean {
        check(Looper.myLooper() == MODE_THREAD.looper) { "MicCapture.start runs on the bh-audio-mode thread" }
        // Stopped before it opened (a hang-up, a switch): nothing to open, and no second recorder
        // beside the next session's.
        if (stopped) return false
        turn = modeTurn.incrementAndGet()
        val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        modeBefore = am.mode
        am.mode = AudioManager.MODE_IN_COMMUNICATION
        route(am, "start")
        val minBuf = AudioRecord.getMinBufferSize(RATE_IN, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val r = try {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_COMMUNICATION, RATE_IN,
                AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, maxOf(minBuf, RATE_IN)
            )
        } catch (t: Throwable) {
            Log.w(TAG, "the microphone did not open: ${t.message}"); restoreMode(am); turn = 0; return false
        }
        if (r.state != AudioRecord.STATE_INITIALIZED) { Log.w(TAG, "the microphone did not open"); restoreMode(am); turn = 0; return false }
        record = r
        if (AcousticEchoCanceler.isAvailable()) {
            aec = AcousticEchoCanceler.create(r.audioSessionId)?.apply { enabled = true }
        }
        // The platform's other two pre-processors on this session, READ BACK for the `[bhaec]`
        // line (the line said `agc=0` as a constant until 2.6.28). A debuggable host may set them
        // for an A/B: `debug.bh.mic.agc` 1 = off, 2 = on; `debug.bh.mic.ns` 1 = on, 2 = off.
        val debuggable = (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
        val agcWant = if (debuggable) AvatarPlayer.devInt("debug.bh.mic.agc") else 0
        val nsWant = if (debuggable) AvatarPlayer.devInt("debug.bh.mic.ns") else 0
        if (AutomaticGainControl.isAvailable()) runCatching {
            agc = AutomaticGainControl.create(r.audioSessionId)?.apply {
                if (agcWant == 1) enabled = false else if (agcWant == 2) enabled = true
            }
        }
        if (NoiseSuppressor.isAvailable()) runCatching {
            ns = NoiseSuppressor.create(r.audioSessionId)?.apply {
                if (nsWant == 1) enabled = true else if (nsWant == 2) enabled = false
            }
        }
        r.startRecording()
        live = true
        // Earbuds put in or taken out mid-call re-route it (the callback also lists what is there now).
        deviceCallback = object : AudioDeviceCallback() {
            override fun onAudioDevicesAdded(added: Array<out AudioDeviceInfo>) {
                added.forEach { refusedIds.remove(it.id) }   // a headset connected again gets another chance
                if (added.any { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO }) scoFailed = false
                if (live) route(am, "device added")
            }
            override fun onAudioDevicesRemoved(removed: Array<out AudioDeviceInfo>) { if (live) route(am, "device removed") }
        }.also { cb -> runCatching { am.registerAudioDeviceCallback(cb, MODE_THREAD) } }
        watchFallback(am)
        Log.i("bhmic", "OPEN source=VOICE_COMMUNICATION mode=${am.mode} device=${r.routedDevice?.type} " +
            "aec=${aec?.enabled} rateIn=$RATE_IN chunkMs=100 hostMs=${System.currentTimeMillis()}")
        // The SAME attestation Apple's RealtimeAudioIO emits, in the same vocabulary, so
        // ONE reader grades the platform canceller on iOS, macOS and Android alike. Every
        // value is READ BACK from the framework, never the value asked for: `mode` is what
        // AudioManager reports (MODE_IN_COMMUNICATION == 3 is what makes the platform AEC
        // reference the playout), `aec` is AcousticEchoCanceler.enabled. Both can legitimately
        // end up off — no canceller on the device, or the communication device not selected —
        // and before this line the log said so only in an unnamed shape nothing graded.
        Log.i("bhaec", "[bhaec] vpioIn=${if (aec?.enabled == true) 1 else 0} " +
            "vpioOut=${if (am.mode == AudioManager.MODE_IN_COMMUNICATION) 1 else 0} " +
            "agc=${effectState(AutomaticGainControl.isAvailable(), agc?.enabled)} " +
            "ns=${effectState(NoiseSuppressor.isAvailable(), ns?.enabled)} mic=on at=start platform=android " +
            "mode=${am.mode} device=${r.routedDevice?.type} inSr=$RATE_IN " +
            "volume=${am.getStreamVolume(AudioManager.STREAM_VOICE_CALL)}/${am.getStreamMaxVolume(AudioManager.STREAM_VOICE_CALL)}")
        thread = Thread({ loop(r) }, "bh-mic").also { it.start() }
        // Stopped while it opened: close now, on this thread, before any later start runs.
        if (stopped) { release(am); return false }
        return true
    }

    /**
     * ★Off the UI thread (2.6.25): stopping the recorder and handing the audio mode back takes
     * ~0.5 s on a Galaxy Z Flip5 (the platform re-routes out of communication mode), and the app
     * froze for it at every hang-up (58 frames skipped at 120 Hz). It runs on the bh-audio-mode
     * thread, where [start] runs too, so mode changes stay in order.
     */
    fun stop() {
        live = false
        stopped = true
        val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        MODE_THREAD.post { release(am) }
    }

    /** bh-audio-mode thread: the recorder, the canceller, the listeners, then the mode. Idempotent. */
    private fun release(am: AudioManager) {
        live = false
        val r = record; record = null
        val a = aec; aec = null
        val g = agc; agc = null
        val n = ns; ns = null
        thread = null
        if (turn == 0) return   // never opened: nothing of the mode is ours
        val t0 = System.nanoTime()
        runCatching { r?.stop(); r?.release() }
        runCatching { a?.release() }
        runCatching { g?.release() }
        runCatching { n?.release() }
        restoreMode(am, owned = modeTurn.get() == turn)
        turn = 0
        Log.i("bhmic", "CLOSED in ${(System.nanoTime() - t0) / 1_000_000} ms, off the UI thread (mode=${am.mode})")
    }

    /**
     * Let go of the mode and the route. [owned] false: a newer session has started since (its start
     * was queued before this stop), so the mode, the communication device and the SCO link are its
     * own now and are left alone; only this session's listeners go.
     */
    private fun restoreMode(am: AudioManager, owned: Boolean = true) {
        deviceCallback?.let { cb -> runCatching { am.unregisterAudioDeviceCallback(cb) } }
        deviceCallback = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (commListener as? AudioManager.OnCommunicationDeviceChangedListener)?.let { runCatching { am.removeOnCommunicationDeviceChangedListener(it) } }
        }
        commListener = null
        scoReceiver?.let { r -> runCatching { context.unregisterReceiver(r) } }
        scoReceiver = null
        if (!owned) { Log.w(TAG, "a newer session owns the audio mode: this one leaves it alone"); return }
        runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                am.clearCommunicationDevice()
            } else {
                @Suppress("DEPRECATION")
                am.isSpeakerphoneOn = false
                if (scoStarted) {
                    @Suppress("DEPRECATION") am.isBluetoothScoOn = false
                    @Suppress("DEPRECATION") am.stopBluetoothSco()
                    scoStarted = false
                }
            }
            // A phone call that took over owns the mode now: leave it alone.
            if (!AudioRules.isCallMode(am.mode)) am.mode = modeBefore
        }
    }

    /**
     * The session's output: the person's headset or earbuds when one is connected, else the
     * loudspeaker (AudioRules). Called at start and whenever a device comes or goes.
     */
    private fun route(am: AudioManager, why: String) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val available = am.availableCommunicationDevices.filter { it.id !in refusedIds }
            val current = am.communicationDevice
            val want = AudioRules.pickCommunicationDevice(available.map { it.type }, current?.type)
            val dev = if (current != null && current.type == want) current else available.firstOrNull { it.type == want }
            if (dev == null) { Log.w("bhroute", "[bhroute] at=$why nothing to select (available=${available.map { it.type }})"); return }
            selected = dev
            if (current?.id == dev.id) return
            val ok = am.setCommunicationDevice(dev)
            Log.i("bhroute", "[bhroute] at=$why selected=${dev.type}${if (ok) "" else " REFUSED"} was=${current?.type} " +
                "available=${available.map { it.type }} personal=${AudioRules.isPersonal(dev.type)}")
            // A headset the platform refused outright: route once more without it (the speaker last).
            if (!ok && AudioRules.isPersonal(dev.type)) { refusedIds.add(dev.id); route(am, "$why, ${dev.type} refused") }
        } else {
            val outs = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS).map { it.type }
            val r = AudioRules.legacyRoute(outs, scoFailed)
            @Suppress("DEPRECATION")
            when (r) {
                AudioRules.LegacyRoute.BLUETOOTH_SCO -> {
                    am.isSpeakerphoneOn = false
                    if (!scoStarted) { am.startBluetoothSco(); am.isBluetoothScoOn = true; scoStarted = true }
                }
                AudioRules.LegacyRoute.HEADSET -> {
                    am.isSpeakerphoneOn = false
                    if (scoStarted) { am.isBluetoothScoOn = false; am.stopBluetoothSco(); scoStarted = false }
                }
                AudioRules.LegacyRoute.SPEAKER -> {
                    if (scoStarted) { am.isBluetoothScoOn = false; am.stopBluetoothSco(); scoStarted = false }
                    am.isSpeakerphoneOn = true
                }
            }
            Log.i("bhroute", "[bhroute] at=$why legacy=$r outputs=$outs")
        }
    }

    /**
     * A headset that does not take the call (busy, refused, its link failed) must not leave it on
     * the earpiece. API 31+: the communication device falling back to the earpiece after a personal
     * device was selected re-routes without that device. API < 31: a failed or dropped SCO link
     * sends the call to the speaker.
     */
    private fun watchFallback(am: AudioManager) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val l = AudioManager.OnCommunicationDeviceChangedListener { now ->
                val sel = selected
                if (!live || sel == null || now?.id == sel.id) return@OnCommunicationDeviceChangedListener
                if (AudioRules.fellBack(now?.type, AudioRules.isPersonal(sel.type))) {
                    refusedIds.add(sel.id)
                    Log.w("bhroute", "[bhroute] ${sel.type} did not take the call (now ${now?.type}): re-routing without it")
                    route(am, "fell back")
                }
            }
            if (runCatching { am.addOnCommunicationDeviceChangedListener({ MODE_THREAD.post(it) }, l) }.isSuccess) commListener = l
        } else {
            val r = object : BroadcastReceiver() {
                override fun onReceive(c: Context, i: Intent) {
                    if (isInitialStickyBroadcast || !live || !scoStarted) return
                    val st = i.getIntExtra(AudioManager.EXTRA_SCO_AUDIO_STATE, AudioManager.SCO_AUDIO_STATE_ERROR)
                    if (st == AudioManager.SCO_AUDIO_STATE_ERROR || st == AudioManager.SCO_AUDIO_STATE_DISCONNECTED) {
                        scoFailed = true
                        Log.w("bhroute", "[bhroute] the Bluetooth SCO link failed or dropped ($st): the speaker")
                        route(am, "sco failed")
                    }
                }
            }
            val f = IntentFilter(AudioManager.ACTION_SCO_AUDIO_STATE_UPDATED)
            if (runCatching {
                    if (Build.VERSION.SDK_INT >= 33) context.registerReceiver(r, f, null, MODE_THREAD, Context.RECEIVER_NOT_EXPORTED)
                    else context.registerReceiver(r, f, null, MODE_THREAD)
                }.isSuccess) scoReceiver = r
        }
    }

    private fun loop(r: AudioRecord) {
        val inBuf = ShortArray(RATE_IN / 10)      // 100 ms
        val outBuf = ByteArray(inBuf.size)        // half as many samples, two bytes each
        var chunks = 0L
        var peak = 0
        var sumSq = 0.0
        var nSq = 0L
        while (live) {
            val n = r.read(inBuf, 0, inBuf.size)
            if (n <= 0) continue
            // 48 kHz -> 24 kHz: average each pair, which decimates and low-passes at once.
            var o = 0
            var i = 0
            while (i + 1 < n) {
                val v = (inBuf[i] + inBuf[i + 1]) / 2
                val a = if (v < 0) -v else v
                if (a > peak) peak = a
                sumSq += v.toDouble() * v; nSq++
                outBuf[o++] = (v and 0xFF).toByte()
                outBuf[o++] = ((v shr 8) and 0xFF).toByte()
                i += 2
            }
            onChunk(outBuf, o)
            // One line per second: the count proves the stream is continuous (10/s), the
            // peak is the loudest sample of the last second (the agent's residual, the room).
            if (++chunks % 10 == 0L) {
                val rms = Math.sqrt(sumSq / maxOf(1L, nSq))
                Log.i("bhmic", "chunks=$chunks peak1s=$peak rms1s=${rms.toInt()} dbfs=%.1f hostMs=${System.currentTimeMillis()}"
                    .format(20 * Math.log10(maxOf(rms, 1.0) / 32768.0)))
                peak = 0; sumSq = 0.0; nSq = 0L
            }
        }
    }

    /** `1`/`0` read back from the effect, `na` when the device has none. */
    private fun effectState(available: Boolean, enabled: Boolean?): String =
        if (!available) "na" else if (enabled == true) "1" else "0"

    companion object {
        private const val TAG = "BithumanAvatar"
        /** The recorder's release and every audio-mode hand-back, in order, off the UI thread. */
        private val MODE_THREAD: Handler by lazy { Handler(HandlerThread("bh-audio-mode").apply { start() }.looper) }
        /** Bumped by every start(): a late stop of an older session does not touch the newer one's mode. */
        private val modeTurn = java.util.concurrent.atomic.AtomicInteger()

        /** Run [block] on the bh-audio-mode thread, after every stop queued before it. */
        fun onModeThread(block: () -> Unit) { MODE_THREAD.post(block) }
        /** The device rate captured; decimated by two on the way out. */
        const val RATE_IN = 48_000
    }
}
