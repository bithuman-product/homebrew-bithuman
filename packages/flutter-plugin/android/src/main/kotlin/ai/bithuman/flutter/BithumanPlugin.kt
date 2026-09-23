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
import ai.bithuman.elevate.Essence2Metering
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
private const val MIC_PERMISSION_REQUEST = 0xB17

class BithumanPlugin : FlutterPlugin, MethodCallHandler, ActivityAware,
    PluginRegistry.RequestPermissionsResultListener {

    private lateinit var channel: MethodChannel
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
        var player: AvatarPlayer? = null
        var mic: MicCapture? = null
        var micSink: EventChannel.EventSink? = null
        var micChannel: EventChannel? = null
        var framesDrawn = 0L

        /** Called on the player's presenter thread; the copy into the texture happens here. */
        fun draw(bmp: Bitmap) {
            if (stopped.get()) return
            val canvas = try { surface.lockCanvas(null) } catch (e: Exception) {
                if (!stopped.get()) Log.w(TAG, "lockCanvas: ${e.message}"); return
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
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
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
                if (hold) {
                    s.player?.stop(); s.player = null
                    Log.i(TAG, "held: player stopped (app off screen)")
                } else if (s.player == null && !s.stopped.get()) {
                    val debuggable = (context.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0
                    val p = AvatarPlayer(s.avatar, debuggable = debuggable, capturable = false) { bmp -> s.draw(bmp) }
                    s.player = p; p.start()
                    Log.i(TAG, "released: fresh player started")
                }
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

            "dispose" -> { call.argument<Number>("textureId")?.let { destroy(it.toLong()) }; result.success(null) }
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
        val t0 = System.nanoTime()
        Thread({
            try {
                val avatar: AvatarEngine = if (essence2) loadEssence2(code, secret, t0) else loadExpression2(code, secret, t0)
                entry.surfaceTexture().setDefaultBufferSize(avatar.width, avatar.height)
                val s = AvatarSession(code, avatar, entry, Surface(entry.surfaceTexture()))
                val debuggable = (context.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0
                val p = AvatarPlayer(avatar, debuggable = debuggable, capturable = false) { bmp -> s.draw(bmp) }
                s.player = p
                main.post {
                    sessions[entry.id()] = s
                    p.start()
                    result.success(entry.id().toInt())
                }
            } catch (e: Throwable) {
                Log.e(TAG, "load failed", e)
                main.post { entry.release(); result.error("load_failed", e.message ?: e.toString(), null) }
            }
        }, "bh-load").start()
    }

    /** Fetch by code into the SDK's store and open the engine — expression-2. Off the platform thread. */
    private fun loadExpression2(code: String, secret: String?, t0: Long): AvatarEngine {
        val store = if (secret.isNullOrBlank()) Expression2ModelStore(context)
            else Expression2ModelStore(context, java.io.File(context.filesDir, "expression2"),
                3L * 1024 * 1024 * 1024, Expression2ModelStore.MeteredDoorResolver(secret))
        val model = store.fetch(code, false, null) { member, done, total ->
            if (total > 0 && done == total) Log.i(TAG, "fetched $member")
        }
        val avatar = Expression2Avatar.create(context, model)
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
    private fun loadEssence2(code: String, secret: String?, t0: Long): AvatarEngine {
        if (secret.isNullOrBlank()) throw IllegalArgumentException(
            "essence-2 on Android needs the app's credential: members are served through the metered door and every frame is metered")
        Essence2Metering.apiSecret = secret
        val store = Essence2ModelStore(context, java.io.File(context.filesDir, "essence2"),
            3L * 1024 * 1024 * 1024, Essence2ModelStore.MeteredDoorResolver(secret))
        val bundle = store.fetch(code, false, null) { member, done, total ->
            if (total > 0 && done == total) Log.i(TAG, "fetched $member")
        }
        val w2v = java.io.File(bundle.dir, Essence2Avatar.W2V_MEMBER)
        val avatar = Essence2Avatar.create(bundle.dir, w2v, 0)
        val e = Essence2Engine(avatar)
        Log.i(TAG, "avatar ready ${avatar.width}x${avatar.height} (essence-2, ${e.fps} fps, driver ${avatar.targetFrames} frames" +
            " in place) +${(System.nanoTime() - t0) / 1_000_000} ms")
        return e
    }

    private fun destroy(id: Long) {
        val s = sessions.remove(id) ?: return
        s.stopped.set(true)
        stopMic(s)
        runCatching { s.player?.stop() }
        runCatching { s.avatar.close() }
        runCatching { s.surface.release() }
        runCatching { s.entry.release() }
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
