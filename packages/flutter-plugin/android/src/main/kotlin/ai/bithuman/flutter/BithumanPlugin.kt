// bithuman Android plugin — the Android half of the umbrella plugin.
//
// The SAME Dart contract the Apple half serves ('ai.bithuman.avatar' MethodChannel,
// 'ai.bithuman.avatar.mic/<textureId>/<gen>' EventChannel), so ONE Flutter app runs on
// a Galaxy with byte-for-byte the widgets it runs on an iPhone. Nothing here draws
// chrome; the kit does.
//
// Engines: expression-2 through the published `ai.bithuman:expression2-android` AAR and
// essence-2 through the published `ai.bithuman:essence2-android` AAR (both Maven
// Central — a stranger's clone needs no private SDK). `load(engine:)` picks one by name,
// and the player runs the same rules on either through [AvatarEngine]. The identity is
// fetched by CODE through the metered door with the app's credential, into the SDK's
// own store; `load(path)` therefore takes the agent code on Android where the Apple
// half takes a staged container directory.
//
// Presentation: AvatarPlayer — the audited one-unit A/V player from the Android chat
// example (a frame and its 50 ms of sound are ONE object, admitted whole, presented
// against the device's own sample counter; idle is the same machinery) — adopted as a
// file, not re-implemented. The plugin's only contribution is a SurfaceTexture sink for
// its frames and the channel glue around it.
//
// Audio: the realtime session (Dart, WebSocket) hands the agent's 24 kHz PCM16 in via
// playSpeakerPCM and takes the microphone's 24 kHz PCM16 out over the mic EventChannel;
// MicCapture keeps the microphone open on the platform's communication path (full duplex).

package ai.bithuman.flutter

import ai.bithuman.elevate.Essence2Avatar
import ai.bithuman.essence2.Essence2Credential
import ai.bithuman.elevate.Essence2ModelStore
import ai.bithuman.expression2.Expression2Avatar
import ai.bithuman.expression2.Expression2ModelStore
import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Surface
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry
import io.flutter.view.TextureRegistry
import java.util.concurrent.atomic.AtomicBoolean

private const val TAG = "BithumanAvatar"
/** How long a fresh player (setIdleHold(false)) waits for the held player's threads to return. */
private const val RESUME_WAIT_MS = 2_000L
private const val MIC_PERMISSION_REQUEST = 0xB17

class BithumanPlugin : FlutterPlugin, MethodCallHandler, ActivityAware,
    PluginRegistry.RequestPermissionsResultListener {

    private lateinit var channel: MethodChannel
    /** Load progress out and `cancel` in, on their own channel (LoadEvents.kt). */
    private lateinit var loadEvents: LoadEvents
    private lateinit var messenger: BinaryMessenger
    private lateinit var textureRegistry: TextureRegistry
    private lateinit var context: Context
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private val main = Handler(Looper.getMainLooper())
    private val sessions = HashMap<Long, AvatarSession>()
    /** Callers waiting on a RECORD_AUDIO answer: Dart results and deferred mic starts. */
    private val permissionWaiters = ArrayList<(Boolean) -> Unit>()

    /** One loaded identity: engine + player + the texture its frames land on. */
    private inner class AvatarSession(
        val code: String,
        val avatar: AvatarEngine,
        val entry: TextureRegistry.SurfaceTextureEntry,
        val surface: Surface,
    ) {
        val ready = AtomicBoolean(false)
        val stopped = AtomicBoolean(false)
        /**
         * Every thread that runs on [avatar] (each player's feeder, producer and writer), and the
         * one way to close it: stop them, wait until each has returned, then close (EngineUsers.kt).
         */
        val users = EngineUsers(avatar) { Log.w(TAG, it) }
        var player: AvatarPlayer? = null
        /** setIdleHold's last word (platform thread): true = the app is off screen, no player. */
        var held = false
        /** A fresh player is waiting for the held one's threads to return (platform thread). */
        var resuming = false
        var mic: MicCapture? = null
        var micSink: EventChannel.EventSink? = null
        var micChannel: EventChannel? = null
        var framesDrawn = 0L
        private val hwCanvas = avatar.hardwareFrames

        /**
         * Called on the player's presenter thread; the copy into the texture happens here — or,
         * with zero-copy delivery, a GPU draw of the engine's own buffer: a hardware Bitmap needs
         * a hardware canvas (a software one refuses it). One kind per surface, for its whole life:
         * a Surface connects to one producer API, CPU or GPU.
         */
        fun draw(bmp: Bitmap) {
            if (stopped.get()) return
            val canvas = try { if (hwCanvas) surface.lockHardwareCanvas() else surface.lockCanvas(null) } catch (e: Exception) {
                if (!stopped.get()) Log.w(TAG, "lock${if (hwCanvas) "Hardware" else ""}Canvas: ${e.message}"); return
            }
            try { canvas.drawBitmap(bmp, 0f, 0f, null) } finally { surface.unlockCanvasAndPost(canvas) }
            framesDrawn++
            if (!ready.getAndSet(true)) Log.i(TAG, "first frame on the texture")
            if (framesDrawn % 200 == 0L) Log.i(TAG, "texture frames=$framesDrawn ${player?.census() ?: ""}")
        }
    }

    // ---------------------------------------------------------------- lifecycle

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        messenger = binding.binaryMessenger
        textureRegistry = binding.textureRegistry
        channel = MethodChannel(messenger, "ai.bithuman.avatar")
        channel.setMethodCallHandler(this)
        loadEvents = LoadEvents(messenger, main)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        loadEvents.close()
        sessions.keys.toList().forEach { destroy(it) }
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity; activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
    }
    override fun onDetachedFromActivityForConfigChanges() { detachActivity() }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) { onAttachedToActivity(binding) }
    override fun onDetachedFromActivity() { detachActivity() }
    private fun detachActivity() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activity = null; activityBinding = null
    }

    // ---------------------------------------------------------------- the channel

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "load" -> load(call, result)
            "frameSize" -> {
                val s = session(call) ?: return result.error("no_session", "unknown textureId", null)
                result.success(mapOf("width" to s.avatar.width, "height" to s.avatar.height))
            }
            "isReady" -> result.success(session(call)?.ready?.get() ?: false)
            "engineVersion" -> result.success(
                (sessions.values.firstOrNull()?.avatar?.name ?: "expression2-android|essence2-android") +
                    " (AvatarPlayer one-unit presenter)")

            // --- the agent's voice in: play it AND lipsync from it, one unit ---
            "playSpeakerPCM" -> {
                val s = session(call) ?: return result.error("no_session", "unknown textureId", null)
                val pcm = call.argument<ByteArray>("pcm")
                if (pcm != null && pcm.isNotEmpty()) { s.player?.noteFirstByte(); s.player?.offer(pcm) }
                result.success(null)
            }
            "notifyTurnEnd" -> { session(call)?.player?.endOfReply(); result.success(null) }
            "interrupt" -> { session(call)?.player?.bargeIn(call.argument<String>("reason") ?: "app"); result.success(null) }
            // The transport's instrument lines, into logcat beside the player's own.
            "log" -> { Log.i("bhdart", call.argument<String>("line") ?: ""); result.success(null) }
            // The mouth is driven by the real audio here; nothing to gate.
            "setSpeaking" -> result.success(true)

            // --- the microphone out ---
            "audioStart" -> audioStart(call, result)
            "audioStop" -> { session(call)?.let { stopMic(it) }; result.success(null) }
            "micPermissionStatus" -> result.success(if (micGranted()) "authorized" else "notDetermined")
            "requestMicPermission" -> requestMic { granted -> result.success(if (granted) "authorized" else "denied") }

            // --- the app is not on screen: no picture, no sound, no CPU ---
            // ★Measured on the shared Galaxy (mobile-SDK lane, 2026-09-15): the player kept
            // rendering idle frames for 74 minutes in the BACKGROUND — battery, heat, and a
            // confound for every measurement on the handset. Hold = the player is stopped
            // (its threads exit, the track is released); release = a fresh player on the same
            // engine and idle loop. The engine itself stays warm.
            "setIdleHold" -> {
                val s = session(call) ?: return result.error("no_session", "unknown textureId", null)
                val hold = call.argument<Boolean>("hold") ?: false
                s.held = hold
                if (hold) {
                    if (s.player != null) Log.i(TAG, "held: player stopped (app off screen)")
                    s.player?.stop(); s.player = null
                } else resume(s)
                result.success(null)
            }

            // --- Apple-only surface, answered honestly ---
            "pipAvailable", "isLocalModeSupported", "setDisplayMode" -> result.success(false)
            "pipStart", "pipStop", "fitWindowToCanvas", "setExpression2AgentDir",
            "attachWebrtcRemoteAudio", "detachWebrtcRemoteAudio" -> result.success(null)

            // A container FILE is not expanded on Android: the SDK fetches an identity's
            // members by code through the download door (see load). `isModelContainer`
            // falls through to notImplemented, which the Dart side reads as "cannot tell".
            "unpackModelContainer" -> result.error("unsupported",
                "Android loads an identity by code (BithumanAvatar.load); a container file is not expanded on this platform", null)

            "dispose" -> {
                // Answered once the engine is closed (its threads first, then the engine, off the
                // platform thread): the app may load the next engine the moment this returns.
                val id = call.argument<Number>("textureId")?.toLong()
                if (id == null) result.success(null) else destroy(id) { result.success(null) }
            }
            else -> result.notImplemented()
        }
    }

    private fun session(call: MethodCall): AvatarSession? =
        call.argument<Number>("textureId")?.let { sessions[it.toLong()] }

    // ---------------------------------------------------------------- load

    private fun load(call: MethodCall, result: Result) {
        val code = call.argument<String>("path")
        val engine = call.argument<String>("engine") ?: "expression2"
        val secret = call.argument<String>("apiSecret")
        val essence2 = engine == "essence2" || engine == "elevate"
        if (code.isNullOrBlank() || !(essence2 || engine == "expression2" || engine == "embody")) {
            return result.error("unsupported",
                "Android runs engine='expression2' or 'essence2'; 'path' is the agent code (e.g. A02HCY0444)", null)
        }
        // Texture registration must happen on the platform thread; the fetch and the
        // engine warm-up must not (a first run downloads ~158 MB).
        val entry = textureRegistry.createSurfaceTexture()
        val handle = loadEvents.begin(code)
        val t0 = handle.t0
        Thread({
            try {
                val avatar: AvatarEngine = if (essence2) loadEssence2(code, secret, t0, handle) else loadExpression2(code, secret, t0, handle)
                // A cancel that came while the engine was being created: close it, start no player.
                if (!handle.finish()) {
                    runCatching { avatar.close() }
                    handle.throwIfCancelled()
                }
                entry.surfaceTexture().setDefaultBufferSize(avatar.width, avatar.height)
                val s = AvatarSession(code, avatar, entry, Surface(entry.surfaceTexture()))
                val p = newPlayer(s)
                s.player = p
                main.post {
                    sessions[entry.id()] = s
                    p.start()
                    result.success(entry.id().toInt())
                }
            } catch (e: Throwable) {
                // Asked for (BithumanAvatar.cancelLoad): its own error code, and not an error in the log.
                val cancelled = handle.cancelled
                // The exception's own words in the line itself: android.util.Log prints NO stack
                // trace when the cause chain holds an UnknownHostException, so a bare "load failed"
                // was all a failed fetch ever logged.
                if (cancelled) Log.i(TAG, "load of $code cancelled +${(System.nanoTime() - t0) / 1_000_000} ms: $e")
                else Log.e(TAG, "load failed: $e${e.cause?.let { " (cause: $it)" } ?: ""}", e)
                main.post { entry.release(); result.error(if (cancelled) "load_cancelled" else "load_failed", e.message ?: e.toString(), null) }
            } finally {
                loadEvents.end(handle)
            }
        }, "bh-load").start()
    }

    /** Fetch by code into the SDK's store and open the engine — expression-2. Off the platform thread. */
    private fun loadExpression2(code: String, secret: String?, t0: Long, handle: LoadHandle): AvatarEngine {
        val store = if (secret.isNullOrBlank()) Expression2ModelStore(context)
            else Expression2ModelStore(context, java.io.File(context.filesDir, "expression2"),
                3L * 1024 * 1024 * 1024, Expression2ModelStore.MeteredDoorResolver(secret))
        val model = store.fetch(code, false, handle.storeCancel) { member, done, total ->
            if (total > 0 && done == total) Log.i(TAG, "fetched $member")
            loadEvents.fetchProgress(handle, done, total)
        }
        loadEvents.fetched(handle)
        handle.throwIfCancelled()
        loadEvents.stage(handle, LoadHandle.STAGE_PREPARE)
        // From expression2-android 0.4.9 the engine meters the session it serves and refuses
        // to create one without an API secret. 0.4.10's one setter arms the meter (and any
        // store resolver built without a credential), exactly as the essence-2 path does.
        if (!secret.isNullOrBlank()) ai.bithuman.expression2.Expression2Credential.set(secret)
        val avatar = Expression2Avatar.create(context, model)
        loadEvents.stage(handle, LoadHandle.STAGE_PREPARED)
        // The idle loop the agent plays between turns is the SDK's: the identity's own
        // clip from the same store as the weights, decoded in place, every frame of it.
        // No clip is a logged reason and a still face, never a second download.
        val idle = avatar.idleLoop
        if (idle == null) Log.w(TAG, "idle loop unavailable: ${avatar.idleLoopUnavailableReason}")
        Log.i(TAG, "avatar ready ${avatar.width}x${avatar.height} (${avatar.accelerator}${avatar.acceleratorNote.let { if (it.isBlank()) "" else " — $it" }}, " +
            "overlap=${avatar.overlapActive}, idle ${idle?.frameCount ?: 0}f in place) +${(System.nanoTime() - t0) / 1_000_000} ms")
        return Expression2Engine(avatar)
    }

    /**
     * The same for essence-2. The identity's members come through the metered door into
     * the SDK's store — the shared audio frontend among them — and the credential also
     * arms the engine's own meter, which refuses every frame without one (0.5.7).
     */
    private fun loadEssence2(code: String, secret: String?, t0: Long, handle: LoadHandle): AvatarEngine {
        if (secret.isNullOrBlank()) throw IllegalArgumentException(
            "essence-2 on Android needs the app's credential: members are served through the metered door and every frame is metered")
        Essence2Credential.set(secret)   // 0.5.15: the one setter for the door and the meter
        val store = Essence2ModelStore(context, java.io.File(context.filesDir, "essence2"),
            3L * 1024 * 1024 * 1024, Essence2ModelStore.MeteredDoorResolver(secret))
        val bundle = store.fetch(code, false, handle.storeCancel) { member, done, total ->
            if (total > 0 && done == total) Log.i(TAG, "fetched $member")
            loadEvents.fetchProgress(handle, done, total)
        }
        loadEvents.fetched(handle)
        handle.throwIfCancelled()
        loadEvents.stage(handle, LoadHandle.STAGE_PREPARE)
        val w2v = java.io.File(bundle.dir, Essence2Avatar.W2V_MEMBER)
        val avatar = Essence2Avatar.create(bundle.dir, w2v, 0)
        loadEvents.stage(handle, LoadHandle.STAGE_PREPARED)
        // Zero-copy delivery by default (2.6.19). `debug.bh.e2.copy=1` keeps the copy path for a
        // same-bytes A/B, and only a DEBUGGABLE host app honours it (see AvatarPlayer.debuggable).
        val debuggable = (context.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0
        val forceCopy = debuggable && AvatarPlayer.devInt("debug.bh.e2.copy") == 1
        val e = Essence2Engine(avatar, zeroCopy = !forceCopy)
        Log.i(TAG, "avatar ready ${avatar.width}x${avatar.height} (essence-2, ${e.fps} fps, driver ${avatar.targetFrames} frames" +
            " in place, delivery ${if (e.hardwareFrames) "zero-copy (${Essence2Engine.HW_SLOTS} hardware buffers)" else "copy"}" +
            "${if (forceCopy) ", debug.bh.e2.copy=1" else ""}) +${(System.nanoTime() - t0) / 1_000_000} ms")
        return e
    }

    /** A player on [s]'s engine; its threads are registered with [AvatarSession.users]. */
    private fun newPlayer(s: AvatarSession): AvatarPlayer {
        val debuggable = (context.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0
        val workers = s.users.newWorkers { name, e -> Log.e(TAG, "$name stopped on an exception: $e", e) }
        return AvatarPlayer(s.avatar, workers, debuggable = debuggable, capturable = false) { bmp -> s.draw(bmp) }
    }

    /**
     * setIdleHold(false): a fresh player on the same engine — ★but only once the held player's
     * threads have returned, so two producers never pull from one engine (until 2.6.23 the new
     * player started at once, beside an old producer that could still be decoding an idle frame).
     * The wait is off the platform thread; the player starts on it.
     */
    private fun resume(s: AvatarSession) {
        if (s.player != null || s.resuming || s.stopped.get()) return
        // The usual case: the app was off screen for a while and the held player's threads are
        // long gone — start now, so audio sent right after this call has a player to land in.
        if (s.users.awaitStopped(0)) return startPlayer(s)
        s.resuming = true
        Thread({
            val t0 = System.nanoTime()
            var quiet = false
            while (!quiet && !s.stopped.get() && (System.nanoTime() - t0) / 1_000_000 < EngineUsers.GIVE_UP_MS) {
                quiet = s.users.awaitStopped(RESUME_WAIT_MS)
                if (!quiet) Log.w(TAG, "released: a held player's thread is still running; the fresh player waits")
            }
            main.post {
                s.resuming = false
                if (s.stopped.get() || s.held || s.player != null || s.users.isClosing) return@post
                // Never a second producer beside one that did not return: the picture stays on its
                // last frame (logged) rather than two players pulling from one engine.
                if (!quiet) { Log.e(TAG, "released: the held player never returned; no fresh player"); return@post }
                startPlayer(s)
            }
        }, "bh-resume").start()
    }

    /** Platform thread. */
    private fun startPlayer(s: AvatarSession) {
        val p = newPlayer(s)
        s.player = p; p.start()
        Log.i(TAG, "released: fresh player started")
    }

    /**
     * dispose: safe at ANY moment — mid idle decode, mid feed, straight after load, while a held
     * player winds down, twice. The platform thread only detaches (map, mic, player flag); a
     * background thread then waits until every player thread has returned and closes the engine
     * (EngineUsers.close), and [done] runs on the platform thread once it is closed.
     * ★Until 2.6.23 the engine was closed right here, under a producer that could be decoding an
     * idle frame: IllegalStateException on bh-produce, and the app died (bitHuman Live, 09-29).
     */
    private fun destroy(id: Long, done: (() -> Unit)? = null) {
        val s = sessions.remove(id) ?: run { done?.invoke(); return }
        s.stopped.set(true)
        stopMic(s)
        s.player?.let { runCatching { it.stop() } }
        s.player = null
        Thread({
            val t0 = System.nanoTime()
            try {
                val closed = s.users.close()
                Log.i(TAG, "disposed ${s.code}: its threads returned, then the engine " +
                    "${if (closed) "closed" else "was LEFT OPEN"} (${(System.nanoTime() - t0) / 1_000_000} ms in all, off the UI thread)")
            } catch (e: Throwable) {
                Log.e(TAG, "dispose of ${s.code}: $e", e)
            } finally {
                // Dart hears back whatever happened above: its dispose() never hangs.
                main.post {
                    runCatching { s.surface.release() }
                    runCatching { s.entry.release() }
                    done?.invoke()
                }
            }
        }, "bh-dispose").start()
    }

    // ---------------------------------------------------------------- microphone

    private fun audioStart(call: MethodCall, result: Result) {
        val s = session(call) ?: return result.error("no_session", "unknown textureId", null)
        val enableMic = call.argument<Boolean>("enableMic") ?: true
        val gen = call.argument<Number>("micGen")?.toInt() ?: 0
        stopMic(s)
        if (!enableMic) return result.success(null)
        // The channel name must match Dart byte-for-byte, gen and all.
        val ch = EventChannel(messenger, "ai.bithuman.avatar.mic/${s.entry.id()}/$gen")
        ch.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink) { s.micSink = sink }
            override fun onCancel(args: Any?) { s.micSink = null }
        })
        s.micChannel = ch
        val startCapture = {
            val mic = MicCapture(context) { buf, n ->
                val sink = s.micSink ?: return@MicCapture
                val chunk = buf.copyOf(n)
                main.post { if (!s.stopped.get()) sink.success(chunk) }
            }
            if (mic.start()) s.mic = mic else Log.w(TAG, "mic not started")
        }
        // Reply now so the session opens; the mic joins the moment the permission is answered.
        result.success(null)
        if (micGranted()) startCapture() else requestMic { granted ->
            if (granted && !s.stopped.get() && s.micChannel === ch) startCapture()
            else Log.w(TAG, "microphone permission denied — speaker-only session")
        }
    }

    private fun stopMic(s: AvatarSession) {
        s.mic?.stop(); s.mic = null
        s.micSink = null
        s.micChannel?.setStreamHandler(null); s.micChannel = null
    }

    private fun micGranted() =
        context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    private fun requestMic(then: (Boolean) -> Unit) {
        if (micGranted()) return then(true)
        val a = activity ?: return then(false)
        synchronized(permissionWaiters) { permissionWaiters.add(then) }
        a.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), MIC_PERMISSION_REQUEST)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
        if (requestCode != MIC_PERMISSION_REQUEST) return false
        val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        val waiters = synchronized(permissionWaiters) { val w = permissionWaiters.toList(); permissionWaiters.clear(); w }
        waiters.forEach { it(granted) }
        return true
    }
}
