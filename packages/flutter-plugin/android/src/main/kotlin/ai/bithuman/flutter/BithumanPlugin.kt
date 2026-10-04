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
// file, not re-implemented. The plugin's only contribution is a texture sink for its
// frames (a Flutter SurfaceProducer) and the channel glue around it.
//
// Audio: the realtime session (Dart, WebSocket) hands the agent's 24 kHz PCM16 in via
// playSpeakerPCM and takes the microphone's 24 kHz PCM16 out over the mic EventChannel;
// MicCapture keeps the microphone open on the platform's communication path (full duplex),
// on the person's headset when one is connected. From audioStart to audioStop the session
// holds audio focus, and a phone call or another app taking the sound is pushed to Dart as
// `audioInterruption` (AudioInterruptions.kt).

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
/** `speechPlayout` pushes at most this often while the voice plays (plus at its end and on a cut). */
private const val PLAYOUT_PUSH_MS = 100L

class BithumanPlugin : FlutterPlugin, MethodCallHandler, ActivityAware,
    PluginRegistry.RequestPermissionsResultListener {

    private lateinit var channel: MethodChannel
    /** Load progress out and `cancel` in, on their own channel (LoadEvents.kt). */
    private lateinit var loadEvents: LoadEvents
    private lateinit var messenger: BinaryMessenger
    private lateinit var textureRegistry: TextureRegistry
    private lateinit var context: Context
    /** The owner's 24 h offline window over the SDK stores' entitlement marks (2.6.36; EntitlementWindow.kt). */
    private val entitlement by lazy { EntitlementWindow(java.io.File(context.filesDir, "bithuman/door-auth")) }
    /** Whose credential an engine is created with; sign-out cancels the loads still running (LoadCredentials.kt). */
    private val credentials = LoadCredentials()
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private val main = Handler(Looper.getMainLooper())
    private val sessions = HashMap<Long, AvatarSession>()
    /**
     * The textures of loads still in flight, and the order of the engine's detach (TextureGate.kt).
     * [TextureGates.detached]: the Flutter engine let go of this plugin (platform thread). A load
     * that finishes after that closes what it made instead of registering it: until 2.6.25 such a
     * session was added to [sessions] after the detach had emptied it, and its player ran with
     * nobody to stop it.
     */
    private val textures = TextureGates()
    private val detached: Boolean get() = textures.detached
    /** Callers waiting on a RECORD_AUDIO answer: Dart results and deferred mic starts. */
    private val permissionWaiters = ArrayList<(Boolean) -> Unit>()

    /** One loaded identity: engine + player + the texture its frames land on. */
    private inner class AvatarSession(
        val code: String,
        val avatar: AvatarEngine,
        val entry: TextureRegistry.SurfaceProducer,
        /** [entry]'s release, once, on the platform thread (TextureGate.kt); made with the texture at load. */
        val texture: TextureGate,
    ) {
        /** The texture was released: nothing is drawn into it again (see [releaseTexture]). */
        val textureReleased: Boolean get() = texture.released
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
        /** A mic still opening on the bh-audio-mode thread (not yet adopted into [mic]). */
        var pendingMic: MicCapture? = null
        /** audioStart → audioStop: the audio focus held and the call watched (AudioInterruptions.kt). */
        var interruptions: AudioInterruptions? = null
        var micSink: EventChannel.EventSink? = null
        var micChannel: EventChannel? = null
        var framesDrawn = 0L

        // Captions (2.6.27): `speechPlayout` {played, fed}, 24 kHz samples since audioStart.
        // Platform thread only.
        /** audioStart → audioStop: playout is reported. */
        var playoutOn = false
        /** The micGen of the audioStart these counts belong to (Dart drops any other). */
        var playMicGen = 0
        /** Samples received by playSpeakerPCM since audioStart, counted before anything else. */
        var fedSamples = 0L
        /** Heard or discarded; monotonic, never above [fedSamples]. */
        var playedSamples = 0L
        var pushedPlayed = -1L
        var pushedFed = -1L
        var pushedAtMs = 0L
        /** pushAudio's 16 kHz speech, converted to the player's 24 kHz (2.6.36). Platform thread. */
        val upsampler = Pcm16kTo24k()
        private val hwCanvas = avatar.hardwareFrames

        /**
         * Called on the player's presenter thread; the copy into the texture happens here — or,
         * with zero-copy delivery, a GPU draw of the engine's own buffer: a hardware Bitmap needs
         * a hardware canvas (a software one refuses it). One kind per surface, for its whole life:
         * a Surface connects to one producer API, CPU or GPU.
         */
        fun draw(bmp: Bitmap) {
            if (stopped.get()) return
            // Released (the engine detached, or a dispose ran) or the producer has no surface just
            // now (onSurfaceCleanup): no draw, since a frame posted then would reach a producer
            // nobody can show.
            texture.draw { blit(bmp) }
        }

        private fun blit(bmp: Bitmap) {
            // The producer's CURRENT surface, every frame (cheap): a producer may hand out a new
            // one over its life, so a Surface kept from load is not assumed to stay valid.
            val surface = entry.surface
            if (!surface.isValid) return
            val canvas = try { if (hwCanvas) surface.lockHardwareCanvas() else surface.lockCanvas(null) } catch (e: Exception) {
                if (!stopped.get()) Log.w(TAG, "lock${if (hwCanvas) "Hardware" else ""}Canvas: ${e.message}"); return
            }
            var posted = false
            try { canvas.drawBitmap(bmp, 0f, 0f, null) } finally {
                // Its own catch: a surface the producer let go of between the lock and here throws
                // IllegalStateException, and on the main thread that would end the app.
                posted = try { surface.unlockCanvasAndPost(canvas); true } catch (e: IllegalStateException) {
                    if (!stopped.get() && !texture.surfaceGone) Log.w(TAG, "unlockCanvasAndPost: ${e.message}")
                    false
                }
            }
            if (!posted) return
            framesDrawn++
            if (!ready.getAndSet(true)) Log.i(TAG, "first frame on the texture")
            if (framesDrawn % 200 == 0L) Log.i(TAG, "texture frames=$framesDrawn ${player?.census() ?: ""}")
        }

        /**
         * Platform thread; idempotent. The texture goes back to Flutter now, and every later draw is
         * a no-op. Called by the engine's detach (synchronously, while FlutterJNI is still attached),
         * and at the end of a dispose, where it does nothing if the detach already ran.
         */
        fun releaseTexture() {
            if (texture.release()) Log.i(TAG, "texture of $code released (frames drawn=$framesDrawn)")
        }
    }

    /**
     * A texture for a load: the producer, its once-only release, and the producer's surface
     * callbacks. Platform thread.
     */
    private fun newTexture(): Pair<TextureRegistry.SurfaceProducer, TextureGate> {
        val entry = textureRegistry.createSurfaceProducer()
        val gate = TextureGate {
            runCatching { entry.release() }.onFailure { Log.w(TAG, "texture release: $it") }
        }
        // The producer may take its surface away (the app went to the background and Flutter
        // trimmed it) and hand out a new one later: no draws in between.
        entry.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
            override fun onSurfaceAvailable() {
                if (gate.surfaceGone) Log.i(TAG, "texture surface available again")
                gate.surfaceGone = false
            }
            override fun onSurfaceCleanup() {
                gate.surfaceGone = true
                Log.i(TAG, "texture surface cleaned up: no draws until it is available again")
            }
        })
        return entry to gate
    }

    // ---------------------------------------------------------------- lifecycle

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        textures.attach()
        context = binding.applicationContext
        messenger = binding.binaryMessenger
        textureRegistry = binding.textureRegistry
        channel = MethodChannel(messenger, "ai.bithuman.avatar")
        channel.setMethodCallHandler(this)
        loadEvents = LoadEvents(messenger, main)
    }

    /**
     * ★The engine is going away, and FlutterJNI lets go of native right after this returns (same
     * main-thread message). So every texture is released HERE, synchronously, before any session's
     * asynchronous close starts (TextureGate.kt): each live session is stopped and its texture
     * released, then each in-flight load's texture, and only then does [destroy] hand the engines
     * to their bh-dispose threads. Until 2.6.27 the texture was released at the end of that thread,
     * after the detach, and a frame still queued on the producer crashed the app in
     * ImageReaderSurfaceProducer.onImage ("FlutterJNI is not attached to native").
     */
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        loadEvents.close()
        val loads = textures.inFlight
        textures.detach(sessions.keys.toList(),
            quiesce = { id ->
                sessions[id]?.let { s ->
                    s.stopped.set(true)
                    s.player?.let { runCatching { it.stop() } }
                    s.releaseTexture()
                }
            },
            closeAsync = { id -> destroy(id) })
        if (loads > 0) Log.i(TAG, "engine detached: released the texture of $loads load(s) in flight")
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
                speak(s, call.argument<ByteArray>("pcm"))
                result.success(null)
            }
            // ★2.6.36: 16 kHz speech in (the Dart `pushAudio`), played and lip-synced like playSpeakerPCM.
            // Until now Android had no such branch and the call threw MissingPluginException.
            "pushAudio" -> {
                val s = session(call) ?: return result.error("no_session", "unknown textureId", null)
                val pcm = call.argument<ByteArray>("pcm")
                if (pcm != null && pcm.isNotEmpty()) speak(s, s.upsampler.process(pcm))
                result.success(null)
            }
            "notifyTurnEnd" -> {
                val s = session(call)
                // The last pushAudio samples the converter still holds (at most two), then the end of the reply.
                if (s != null) speak(s, s.upsampler.flush())
                s?.player?.endOfReply(); result.success(null)
            }
            "interrupt" -> {
                val s = session(call)
                s?.upsampler?.reset()
                s?.player?.bargeIn(call.argument<String>("reason") ?: "app")
                // Everything handed over is discarded: captions end on what was heard before the cut.
                if (s != null) { notePlayed(s, s.fedSamples); pushPlayout(s, force = true) }
                result.success(null)
            }
            // The transport's instrument lines, into logcat beside the player's own.
            "log" -> { Log.i("bhdart", call.argument<String>("line") ?: ""); result.success(null) }
            // The mouth is driven by the real audio here; nothing to gate.
            "setSpeaking" -> result.success(true)

            // --- the microphone out ---
            "audioStart" -> audioStart(call, result)
            "audioStop" -> { session(call)?.let { it.playoutOn = false; stopMic(it) }; result.success(null) }
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

            // The on-device brain (local mode) runs on iOS and macOS only; isLocalModeSupported says
            // false here. Answered by name (2.6.36) instead of notImplemented: a start is refused,
            // and a stop or a mute has nothing to act on.
            "localAudioStart", "localPushText" -> result.error("unsupported",
                "local mode runs on iOS and macOS only (BithumanAvatar.isLocalModeSupported() is false on Android)", null)
            "localAudioStop", "localSetMuted" -> result.success(null)

            // A container FILE is not expanded on Android: the SDK fetches an identity's
            // members by code through the download door (see load). `isModelContainer`
            // answers null, which the Dart side reads as "cannot tell".
            "isModelContainer" -> result.success(null)

            // Sign-out (2.6.36, security): the process-wide credentials the engines and the stores' doors
            // fall back to are cleared, so nothing after this runs as the account that signed out; every load
            // still running is cancelled (`load_cancelled`), and none begun before this creates an engine with
            // its credential (LoadCredentials.kt). Never waits for an engine being created.
            "clearCredentials" -> {
                credentials.clear(
                    cancelLoads = { loadEvents.cancelAll() },
                    clearGlobals = {
                        ai.bithuman.expression2.Expression2Credential.set(null)
                        Essence2Credential.set(null)
                    })
                result.success(null)
            }
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
        val engine = call.argument<String>("engine") ?: EngineIds.EXPRESSION2
        val secret = call.argument<String>("apiSecret")
        val skipAhead = call.argument<Boolean>("skipAhead")
        // 2.6.36: the public model ids (`essence-2`, `expression-2`) too, as on iOS and macOS.
        val canonical = EngineIds.canonical(engine)
            ?: return result.error("unsupported", EngineIds.unknownMessage(engine), null)
        val essence2 = canonical == EngineIds.ESSENCE2
        if (code.isNullOrBlank()) {
            return result.error("unsupported",
                "Android runs engine='expression2' or 'essence2'; 'path' is the agent code (e.g. A23WJF0199)", null)
        }
        // Texture registration must happen on the platform thread; the fetch and the
        // engine warm-up must not (a first run downloads ~158 MB).
        // ★ A SurfaceProducer, not a SurfaceTexture. Under Impeller (Vulkan, the
        // default on Android 10+) a SurfaceTexture reaches the raster thread through a GLES
        // interop — Flutter logs "migrate … to the new surface producer API" — and every
        // avatar frame paid for it there: 10.4 ms p50 of raster per frame on a Galaxy Z Flip5
        // (idle, 120 Hz: 90% of frames over the 8.3 ms budget), where the placeholder video
        // beside it (video_player, already a producer) costs 2.5 ms. The producer is an
        // ImageReader whose buffers Impeller imports as they are. The draw is unchanged: the
        // same canvas blit (a hardware canvas for zero-copy hardware-buffer frames), into its surface.
        val (entry, texture) = newTexture()
        textures.loadStarted(texture)
        val handle = loadEvents.begin(code)
        val t0 = handle.t0
        // In call order with clearCredentials (both on this thread): a sign-out after this cancels this load.
        val gen = credentials.begin()
        Thread({
            try {
                val avatar: AvatarEngine = if (essence2) loadEssence2(code, secret, t0, handle, gen, skipAhead) else loadExpression2(code, secret, t0, handle, gen)
                // A cancel that came while the engine was being created: close it, start no player.
                if (!handle.finish()) {
                    runCatching { avatar.close() }
                    handle.throwIfCancelled()
                }
                entry.setSize(avatar.width, avatar.height)
                val s = AvatarSession(code, avatar, entry, texture)
                val p = newPlayer(s)
                s.player = p
                main.post {
                    if (!textures.loadFinished(texture)) {
                        // The engine detached while this load ran: nobody can show or stop this
                        // session. Its texture is already released (by the detach, or just now by
                        // loadFinished); close the rest (threads, engine) instead of registering it.
                        Log.i(TAG, "load of $code finished after the engine detached: closing it")
                        s.stopped.set(true)
                        closeSession(s, null)
                        runCatching { result.error("detached", "the Flutter engine detached during load", null) }
                        return@post
                    }
                    sessions[entry.id()] = s
                    p.start()
                    result.success(entry.id().toInt())
                }
            } catch (e: Throwable) {
                // Asked for (BithumanAvatar.cancelLoad, or clearCredentials): its own error code, and not an
                // error in the log.
                val cancelled = handle.cancelled || e is LoadCredentials.Cleared
                // The exception's own words in the line itself: android.util.Log prints NO stack
                // trace when the cause chain holds an UnknownHostException, so a bare "load failed"
                // was all a failed fetch ever logged.
                if (cancelled) Log.i(TAG, "load of $code cancelled +${(System.nanoTime() - t0) / 1_000_000} ms: $e")
                else Log.e(TAG, "load failed: $e${e.cause?.let { " (cause: $it)" } ?: ""}", e)
                // ★MODEL_REJECTED (2.6.29): the engine refused the model file. Its own code, with the
                // engine's native code and sentence — a terminal error the app can name, where
                // `load_failed` read as a network failure worth retrying.
                val rejected = (e as? ModelRejectedException)?.rejection
                // ★The entitlement window (2.6.36): its own codes, which the Dart side maps to
                // BithumanEntitlementException (refused, or could not be confirmed).
                val entitlementRefused = e as? EntitlementWindow.Refused
                main.post {
                    textures.loadFailed(texture)
                    runCatching {
                        if (rejected != null && !cancelled) result.error(ModelRejection.CODE, rejected.message, rejected.details())
                        else if (entitlementRefused != null && !cancelled) result.error(entitlementRefused.channelCode, entitlementRefused.message, entitlementRefused.status)
                        else result.error(if (cancelled) "load_cancelled" else "load_failed", e.message ?: e.toString(), null)
                    }
                }
            } finally {
                loadEvents.end(handle)
            }
        }, "bh-load").start()
    }

    /** Fetch by code into the SDK's store and open the engine — expression-2. Off the platform thread. */
    private fun loadExpression2(code: String, secret: String?, t0: Long, handle: LoadHandle, gen: Long): AvatarEngine {
        // ★2.6.36 (security): THIS load's credential, never an earlier one. Through 2.6.35 a load with no
        // secret built `Expression2ModelStore(context)`, whose door resolver falls back to the process-wide
        // Expression2Credential, which only a load WITH a secret ever set and nothing cleared: after
        // account A loaded, a credential-less load in the same process (a Dart hot restart included)
        // asked the door as A and got A's private avatar, metered to A. The engine refuses a session
        // without a credential anyway (0.4.9+), so a load without one is refused here, by name, as the
        // essence-2 path does. ★Round 3: the store asks with this load's own resolver, and the process-wide
        // value (which arms the meter at create) is set only right before create, under LoadCredentials,
        // after the door's yes: a load cancelled by clearCredentials never creates an engine with its key.
        val avatar = loadInOrder(code, "expression-2", secret, gen, credentials,
            admit = { c, m, s -> entitlement.admit(c, m, s) },   // the owner's offline window (EntitlementWindow)
            fetch = { s ->
                val store = Expression2ModelStore(context, java.io.File(context.filesDir, "expression2"),
                    3L * 1024 * 1024 * 1024, Expression2ModelStore.MeteredDoorResolver(s))
                val model = store.fetch(code, false, handle.storeCancel) { member, done, total ->
                    if (total > 0 && done == total) Log.i(TAG, "fetched $member")
                    loadEvents.fetchProgress(handle, done, total)
                }
                loadEvents.fetched(handle)
                handle.throwIfCancelled()
                loadEvents.stage(handle, LoadHandle.STAGE_PREPARE)
                model
            },
            // From expression2-android 0.4.9 the engine meters the session it serves and refuses to create
            // one without an API secret: 0.4.10's one setter arms it.
            setCredential = { s -> ai.bithuman.expression2.Expression2Credential.set(s) },
            create = { model ->
                try { Expression2Avatar.create(context, model) } catch (e: Exception) {
                    throw ModelRejection.expression2(e)?.let { ModelRejectedException(it, e) } ?: e
                }
            },
            close = { a -> a.close() },
            blankMessage = "expression-2 on Android needs the app's credential (apiSecret): the door is asked as that account and every session is metered")
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
    private fun loadEssence2(code: String, secret: String?, t0: Long, handle: LoadHandle, gen: Long, skipAhead: Boolean? = null): AvatarEngine {
        // ★Round 3 (security): as Expression 2. The store asks with this load's own resolver; the process-wide
        // Essence2Credential (0.5.15: the one setter for the door and the meter, which arms at create) is set
        // only right before create, under LoadCredentials, after the door's yes.
        var store: Essence2ModelStore? = null
        var hit: Essence2ModelStore.Bundle? = null
        val avatar = loadInOrder(code, "essence-2", secret, gen, credentials,
            admit = { c, m, s -> entitlement.admit(c, m, s) },   // the owner's offline window (EntitlementWindow)
            fetch = { s ->
                val st = Essence2ModelStore(context, java.io.File(context.filesDir, "essence2"),
                    3L * 1024 * 1024 * 1024, Essence2ModelStore.MeteredDoorResolver(s))
                store = st
                // ★THE CACHED COPY OPENS FIRST; THE DOOR IS ASKED AFTER (2.6.28). Since essence2-android
                // 0.5.6 a cache hit in `fetch` asks the door whether a member changed before it returns
                // (one short attempt, up to 8 s), so every cold open of a character already on the phone
                // waited on the network: 1.5-5.8 s, median ~3 s, of Sofia's ~8 s launch on a Galaxy Z
                // Fold5 / Flip5 (2026-10-01). `cached` is the same verified bundle with no request
                // (member lengths and recorded digests checked on disk); the engine opens on it now,
                // and the door's answer is applied in the background once the engine is up — a changed
                // member is downloaded, verified and swapped in under the store's journal, so the NEXT
                // open uses it. Nothing on the phone (or a swap left half-done): the full fetch as before.
                hit = runCatching { st.cached(code) }.getOrNull()
                val bundle = hit ?: st.fetch(code, false, handle.storeCancel) { member, done, total ->
                    if (total > 0 && done == total) Log.i(TAG, "fetched $member")
                    loadEvents.fetchProgress(handle, done, total)
                }
                if (hit != null) Log.i(TAG, "$code: the cached copy opens now (+${(System.nanoTime() - t0) / 1_000_000} ms); the door is asked after the load")
                loadEvents.fetched(handle)
                handle.throwIfCancelled()
                loadEvents.stage(handle, LoadHandle.STAGE_PREPARE)
                bundle
            },
            setCredential = { s -> Essence2Credential.set(s) },
            create = { bundle -> createEssence2(store!!, code, bundle, handle) },
            close = { a -> a.close() },
            blankMessage = "essence-2 on Android needs the app's credential: members are served through the metered door and every frame is metered")
        loadEvents.stage(handle, LoadHandle.STAGE_PREPARED)
        // Zero-copy delivery by default (2.6.19). `debug.bh.e2.copy=1` keeps the copy path for a
        // same-bytes A/B, and only a DEBUGGABLE host app honours it (see AvatarPlayer.debuggable).
        val debuggable = (context.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0
        val forceCopy = debuggable && AvatarPlayer.devInt("debug.bh.e2.copy") == 1
        // Skip-ahead (2.6.29): the player's clock reaches the engine unless switched off — a debug lever
        // first (debug.bh.e2.clock 1/2, debuggable hosts only), then the app's load option, then the default.
        val clockLever = if (debuggable) AvatarPlayer.devInt("debug.bh.e2.clock") else 0
        val clockOn = PlayoutClock.enabled(clockLever, skipAhead, Essence2Engine.SKIP_AHEAD_DEFAULT)
        val e = Essence2Engine(avatar, zeroCopy = !forceCopy, playoutClock = clockOn)
        Log.i(TAG, "avatar ready ${avatar.width}x${avatar.height} (essence-2, ${e.fps} fps, driver ${avatar.targetFrames} frames" +
            " in place, delivery ${if (e.hardwareFrames) "zero-copy (${Essence2Engine.HW_SLOTS} hardware buffers)" else "copy"}" +
            "${if (forceCopy) ", debug.bh.e2.copy=1" else ""}, skip-ahead clock ${if (clockOn) "on" else "off"}" +
            " (${when { clockLever == 1 || clockLever == 2 -> "debug.bh.e2.clock=$clockLever"; skipAhead != null -> "load option"; else -> "default" }})" +
            ") +${(System.nanoTime() - t0) / 1_000_000} ms")
        if (hit != null) store?.let { revalidateLater(it, code) }
        return e
    }

    /**
     * Creates the Essence 2 engine on [bundle] (inside [LoadCredentials.create]: the process-wide credential is
     * this load's). ★AN INSTALL PUBLISHED BEFORE THE MOUTH-CORNER FIX IS FETCHED AGAIN, ONCE (2026-10-02). The
     * engine refuses it ("... REFUSED for identity '<code>'"); the door serves every live identity's current
     * bundle. essence2-android's store already skips such an install in `cached`, so this is the belt for a
     * check that passed and an engine that still refused: a forced fetch (only the changed members, with this
     * load's own resolver) and one more open. A second refusal is MODEL_REJECTED (2.6.29), as is any other
     * refusal the engine names.
     */
    private fun createEssence2(store: Essence2ModelStore, code: String, bundle: Essence2ModelStore.Bundle, handle: LoadHandle): Essence2Avatar =
        try {
            Essence2Avatar.create(bundle.dir, java.io.File(bundle.dir, Essence2Avatar.W2V_MEMBER), 0)
        } catch (e: IllegalStateException) {
            if (e.message?.contains("REFUSED for identity '") != true) {
                throw ModelRejection.essence2(e)?.let { ModelRejectedException(it, e) } ?: e
            }
            Log.i(TAG, "$code: the installed bundle is out of date; fetching it again (once)")
            val fresh = store.fetch(code, true, handle.storeCancel) { _, done, total ->
                loadEvents.fetchProgress(handle, done, total)
            }
            handle.throwIfCancelled()
            // The door served a file this engine cannot open: the app or the engine is out of date.
            try {
                Essence2Avatar.create(fresh.dir, java.io.File(fresh.dir, Essence2Avatar.W2V_MEMBER), 0)
            } catch (e2: Exception) {
                throw ModelRejection.essence2(e2)?.let { ModelRejectedException(it, e2) } ?: e2
            }
        } catch (e: RuntimeException) {
            // The store's audio-frontend refusal (not an IllegalStateException).
            throw ModelRejection.essence2(e)?.let { ModelRejectedException(it, e) } ?: e
        }

    /**
     * The door check a cached open skipped, off every thread that matters: `fetch` on a cache
     * hit asks the door once and, if it changed a member, downloads, verifies and swaps it in
     * (under the store's per-identity lock and swap journal) — for the next open. Started only
     * once the engine is open, so a swap never lands while the engine reads the bundle; the
     * open engine keeps the files it opened. Never throws, never fails the load.
     */
    private fun revalidateLater(store: Essence2ModelStore, code: String) {
        Thread({
            val t = System.nanoTime()
            val r = runCatching { store.fetch(code, false, null, null) }
            Log.i(TAG, "$code: door check after a cached open ${if (r.isSuccess) "done" else "failed (${r.exceptionOrNull()?.message})"} " +
                "in ${(System.nanoTime() - t) / 1_000_000} ms (a changed member is used from the next open)")
        }, "bh-revalidate").apply { isDaemon = true; priority = Thread.MIN_PRIORITY }.start()
    }

    /** A player on [s]'s engine; its threads are registered with [AvatarSession.users]. */
    private fun newPlayer(s: AvatarSession): AvatarPlayer {
        val debuggable = (context.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0
        val workers = s.users.newWorkers { name, e -> Log.e(TAG, "$name stopped on an exception: $e", e) }
        return AvatarPlayer(s.avatar, workers, debuggable = debuggable, capturable = false,
            onPlayout = { played -> notePlayed(s, played) }) { bmp -> s.draw(bmp) }
    }

    // ---------------------------------------------------------------- speech playout (captions)

    /**
     * 24 kHz mono PCM16 of the agent's voice into the player: it plays it and lip-syncs from the
     * same chunk (playSpeakerPCM, and pushAudio after its 16 -> 24 kHz conversion). Platform thread.
     */
    private fun speak(s: AvatarSession, pcm: ByteArray?) {
        if (pcm == null || pcm.isEmpty()) return
        // `fed` first, before anything can drop the chunk (captions count what Dart handed over).
        val fedStart = s.fedSamples
        s.fedSamples += pcm.size / 2
        val p = s.player
        if (p != null) { p.noteFirstByte(); p.offer(pcm, fedStart) }
        else notePlayed(s, s.fedSamples)        // no player (held): this audio is never heard
        if (fedStart == 0L) pushPlayout(s, force = true)   // the first chunk: a playout source exists
    }

    /** The player says [played] (fed coordinate) has been heard. Platform thread. */
    private fun notePlayed(s: AvatarSession, played: Long) {
        val p = minOf(played, s.fedSamples)
        if (p > s.playedSamples) s.playedSamples = p
        pushPlayout(s)
    }

    /**
     * `speechPlayout` to Dart: at most every 100 ms while the position moves, at once when it
     * reaches everything fed (the reply has been heard to its end) and when [force]d (the first
     * chunk of an audio unit, a barge-in). Platform thread.
     */
    private fun pushPlayout(s: AvatarSession, force: Boolean = false) {
        if (!s.playoutOn || s.stopped.get() || detached) return
        val played = s.playedSamples
        val fed = s.fedSamples
        if (played == s.pushedPlayed && fed == s.pushedFed) return
        val now = android.os.SystemClock.uptimeMillis()
        val caughtUp = played >= fed && s.pushedPlayed < fed
        if (!force && !caughtUp && (played == s.pushedPlayed || now - s.pushedAtMs < PLAYOUT_PUSH_MS)) return
        s.pushedPlayed = played; s.pushedFed = fed; s.pushedAtMs = now
        runCatching {
            channel.invokeMethod("speechPlayout", mapOf(
                "textureId" to s.entry.id(), "micGen" to s.playMicGen, "played" to played, "fed" to fed))
        }
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
        closeSession(s, done)
    }

    /**
     * Stop [s]'s player, then (off the platform thread) wait for its threads, close the engine and
     * release the texture (a no-op when the engine's detach released it already); [done] runs on the
     * platform thread at the end. [s] is already out of [sessions] (or was never in it: a load that
     * finished after the engine detached).
     */
    private fun closeSession(s: AvatarSession, done: (() -> Unit)?) {
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
                    s.releaseTexture()
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
        // A new audio unit: the playout counts restart at zero (captions, `speechPlayout`).
        s.playMicGen = gen; s.fedSamples = 0L; s.playedSamples = 0L
        s.pushedPlayed = -1L; s.pushedFed = -1L; s.pushedAtMs = 0L; s.playoutOn = true
        s.upsampler.reset()
        s.player?.resetPlayout()
        // The call's audio focus and the phone-call watch, for speaker-only sessions too: a call
        // answered from its notification leaves the app on screen and would otherwise go on.
        val watch = AudioInterruptions(context, main) { began, reason, shouldResume ->
            if (!s.stopped.get() && !detached) runCatching {
                channel.invokeMethod("audioInterruption", mapOf(
                    "textureId" to s.entry.id(), "state" to if (began) "began" else "ended",
                    "reason" to reason, "shouldResume" to shouldResume))
            }
        }
        s.interruptions = watch
        val clear = watch.start()
        if (!enableMic) return result.success(null)
        // A call already holds the audio: no microphone (it would change the audio mode under the
        // call); Dart has been told, and the session ends.
        if (!clear) { Log.w(TAG, "a call holds the audio: the microphone stays closed"); return result.success(null) }
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
            // Opened on the bh-audio-mode thread, never here: it held the platform thread ~0.9 s at
            // every dial (MicCapture.start). The session adopts it back on the platform thread,
            // unless it was stopped or restarted meanwhile (then the fresh mic is closed at once).
            s.pendingMic = mic
            MicCapture.onModeThread {
                val ok = mic.start()
                main.post {
                    if (s.pendingMic === mic) s.pendingMic = null
                    if (!ok) { Log.w(TAG, "mic not started (stopped before it opened, or it did not open)"); return@post }
                    if (s.stopped.get() || s.micChannel !== ch || detached || s.interruptions?.isInterrupted == true) {
                        mic.stop(); return@post
                    }
                    s.mic = mic
                }
            }
        }
        // Reply now so the session opens; the mic joins the moment the permission is answered.
        result.success(null)
        if (micGranted()) startCapture() else requestMic { granted ->
            if (granted && !s.stopped.get() && s.micChannel === ch && !detached && s.interruptions?.isInterrupted != true) startCapture()
            else Log.w(TAG, "microphone permission denied — speaker-only session")
        }
    }

    private fun stopMic(s: AvatarSession) {
        s.mic?.stop(); s.mic = null
        // Still opening: its stop is queued now, before any next start on the same thread.
        s.pendingMic?.stop(); s.pendingMic = null
        s.interruptions?.stop(); s.interruptions = null
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
