// bithuman — Apple native plugin (v0.4, expression-2 default engine).
//
// ONE shared source compiled into both the iOS and macOS plugin pods
// (the per-platform Classes/BithumanAvatarPlugin.swift are symlinks to
// this file). The only platform deltas are guarded with #if os(iOS) /
// #if os(macOS): the framework + UI imports, the FlutterPluginRegistrar
// messenger()/textures() accessors (iOS = methods, macOS = properties),
// and the AppKit-vs-UIKit app-will-terminate notification.
//
// The default engine is the pure-Swift/CoreML EXPRESSION-2 runtime
// `Expression2Runtime` (this repo), and the only native binary the plugin links
// is `libconverse.xcframework` (the on-device conversation brain). The
// `essence` (libessence `be_*`) and `elevate` (libessence2 `be_essence2_*`)
// engines have been removed.
//
// Apache-2.0; (c) bitHuman.

#if os(iOS)
import Flutter
import UIKit
import AVFoundation   // AVAudioPCMBuffer for the WebRTC remote-audio lipsync tap
import AVKit          // AVPictureInPictureController — system PiP bubble
#elseif os(macOS)
import Cocoa
import FlutterMacOS
import AVFoundation   // AVCaptureDevice — mic-permission gate (authorizationStatus / requestAccess / Settings deep-link)
#endif
import Accelerate
import Expression2   // the published binary: Expression2Engine statics, Expression2Container
import CoreVideo
import Foundation

/// OFFLINE SELF-TEST: dump published embody frames so a headless run can be
/// encoded to mp4 + eyeballed. Off unless EMBODY_DUMP_FRAMES is set — inert in
/// the shipping app.
enum EmbodyAvatarDump {
  static let on = DevLevers.dumpFrames
  static let dir: String = {
    let base = DevLevers.dumpDir ?? "/tmp"
    let d = base + "/embody_frames"
    try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
  }()
  static let maxFrames = 600
  static var n = 0
  static let lock = NSLock()
  static func write(_ buf: [UInt8], count: Int) {
    lock.lock(); let i = n; if n < maxFrames { n += 1 }; lock.unlock()
    guard i < maxFrames else { return }
    let path = String(format: "%@/%05d.bgr", dir, i)
    buf.withUnsafeBufferPointer { p in
      try? Data(bytes: p.baseAddress!, count: count).write(to: URL(fileURLWithPath: path))
    }
  }
}

public class BithumanPlugin: NSObject, FlutterPlugin {
  private weak var registrar: FlutterPluginRegistrar?
  // Retained for native→Dart pushes (frameDimsChanged / pipEvent). Dart
  // installs a MethodCallHandler on the same channel name.
  var channel: FlutterMethodChannel?
  private var textures: [Int64: AvatarTexture] = [:]
  #if os(iOS)
  // System Picture-in-Picture session (the bubble floats over the SYSTEM,
  // not just in-app). One at a time; lifecycle via pipStart/pipStop.
  private var pip: AvatarPiP?
  #endif
  // One audio engine per texture (= per session). Holds the VP-IO graph
  // that owns mic + speaker for that conversation.
  private var audioIOs: [Int64: RealtimeAudioIO] = [:]
  // FlutterEventChannel MUST be retained for the lifetime of the
  // stream. Without this, the channel is deallocated when the
  // audioStart method handler returns and the mic stream never
  // delivers chunks to Dart even though the native VP-IO tap is firing.
  private var micChannels: [Int64: FlutterEventChannel] = [:]
  #if os(macOS) || os(iOS)
  // LOCAL mode (macOS/iOS): on-device converse brain per session + its UI
  // EventChannel. Type-erased to AnyObject so this 13.0/16.0-floored plugin
  // doesn't reference the OS-26-gated LocalConverseController as a stored-
  // property type; the entry path casts back under `#available(macOS 26, iOS 26, *)`.
  private var converseControllers: [Int64: AnyObject] = [:]
  private var converseChannels: [Int64: FlutterEventChannel] = [:]
  #endif

  // FlutterPluginRegistrar exposes the binary messenger + texture registry
  // as methods on iOS but as properties on macOS. Funnel the optional
  // call sites through these helpers so the method bodies stay identical.
  private var registrarMessenger: FlutterBinaryMessenger? {
    #if os(iOS)
    return registrar?.messenger()
    #elseif os(macOS)
    return registrar?.messenger
    #endif
  }
  private var registrarTextures: FlutterTextureRegistry? {
    #if os(iOS)
    return registrar?.textures()
    #elseif os(macOS)
    return registrar?.textures
    #endif
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
    let messenger = registrar.messenger()
    #elseif os(macOS)
    let messenger = registrar.messenger
    #endif
    let channel = FlutterMethodChannel(
      name: "ai.bithuman.avatar",
      binaryMessenger: messenger)
    let instance = BithumanPlugin()
    instance.registrar = registrar
    instance.channel = channel
    registrar.addMethodCallDelegate(instance, channel: channel)

    // Tear LOCAL converse sessions down BEFORE the process exits. Otherwise the
    // window-close → terminate: → exit() path runs ggml-metal's static
    // destructor against still-live Metal state and ggml_abort()s (the SIGABRT
    // the user saw on close). Stopping the session first frees the model +
    // joins the worker while Metal is still healthy.
    // macOS-only: NSApplication.willTerminate has no iOS equivalent on this path
    #if os(macOS)
    NotificationCenter.default.addObserver(
      instance, selector: #selector(bithumanWillTerminate(_:)),
      name: NSApplication.willTerminateNotification, object: nil)
    // The Runner's AppDelegate posts this FIRST thing in its
    // applicationWillTerminate, BEFORE _exit(0). Observer order on the system
    // willTerminate notification vs the delegate callback is undefined, so
    // this is the deterministic "stop producers NOW" signal for the quit
    // path. The handler is idempotent; both firing is fine.
    NotificationCenter.default.addObserver(
      instance, selector: #selector(bithumanWillTerminate(_:)),
      name: Notification.Name("ai.bithuman.appWillTerminate"), object: nil)
    // macOS-only: the borderless window chrome + the floating-circle companion
    // (macos/Classes/WindowChrome.swift); iOS has no window to shape.
    WindowChrome.register(with: registrar)
    #elseif os(iOS)
    NotificationCenter.default.addObserver(
      instance, selector: #selector(bithumanWillTerminate(_:)),
      name: UIApplication.willTerminateNotification, object: nil)
    #endif
  }

  #if os(macOS) || os(iOS)
  @objc private func bithumanWillTerminate(_ note: Notification) {
    // Textures first: cancels the frame-pull timers so nothing calls
    // textureFrameAvailable into a dying FlutterEngine ("Invalid engine
    // handle" spam) and frees the embody runtime for each texture.
    for (textureId, tex) in textures {
      tex.shutdown()
      registrarTextures?.unregisterTexture(textureId)
    }
    textures.removeAll()
    #if CONVERSE_AVAILABLE
    if #available(macOS 26.0, iOS 26.0, *) {
      for (_, ctrl) in converseControllers { (ctrl as? LocalConverseController)?.stop() }
    }
    #endif
    converseControllers.removeAll()
    converseChannels.removeAll()
    for (_, io) in audioIOs { io.stop() }
    audioIOs.removeAll()
  }
  #endif

  /// A phone call (or Siri, an alarm) taking this session's sound, and giving it back, as
  /// `audioInterruption` on the avatar channel: {textureId, state: began|ended, reason:
  /// call|system, shouldResume}. RealtimeAudioIO calls on the main thread. Dart's
  /// BithumanRealtimeSession ends the call on `began` (2.6.25): until then the sound paused and
  /// the realtime session went on, billed, under the phone call.
  private func forwardInterruptions(of io: RealtimeAudioIO, textureId: Int64) {
    io.onInterruption = { [weak self] began, reason, shouldResume in
      self?.channel?.invokeMethod("audioInterruption", arguments: [
        "textureId": textureId, "state": began ? "began" : "ended",
        "reason": reason, "shouldResume": shouldResume,
      ])
    }
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "load":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String else {
        result(FlutterError(code: "BAD_ARGS", message: "load requires path", details: nil))
        return
      }
      // `apiSecret` rides the AvatarRef to the engine. expression-2 is pure
      // on-device and ignores it; essence-2 BILLS the session it serves and
      // refuses to create one without a credential (be_essence2_create -3,
      // "no authenticated session for this render") — which is exactly what an
      // iPhone did on 2026-09-16: the app held the secret in its Keychain, the
      // Android half fetches by code with it, and this handler dropped it on the
      // floor ("accepted for API compatibility but unused"). A macOS run only
      // ever worked because the lane exported BITHUMAN_API_SECRET into the
      // process environment, which no installed app has.
      guard let textureRegistry = registrarTextures else {
        result(FlutterError(code: "NO_REGISTRY",
                            message: "no FlutterTextureRegistry available",
                            details: nil))
        return
      }
      // Engine select — REGISTRY-DRIVEN (M3), no `engineKind == "essence2"` here.
      // The wire slug is dual-accept (expression2/embody, essence2/elevate;
      // unknown/missing → the required default expression2). EngineRegistry
      // resolves it to the canonical slug + the engine's capabilities; the actual
      // engine CREATION (incl. essence2's activeAgentDir/motionDir from the avatar
      // ref) happens later in EngineRegistry.make (loadFixtureAndRuntime), so this
      // handler pokes no concrete engine type.
      let engineArg = (args["engine"] as? String) ?? "embody"
      let texture = AvatarTexture(imxPath: path)
      texture.engineKind = EngineRegistry.canonical(for: engineArg)
      texture.capabilities = EngineRegistry.capabilities(for: engineArg)
      texture.motionDir = args["motionDir"] as? String
      texture.apiSecret = args["apiSecret"] as? String
      // Essence 2 skip-ahead (2.6.30 on Apple, with an engine that has the calls): the app's opt-in.
      texture.skipAhead = args["skipAhead"] as? Bool
      let textureId = textureRegistry.register(texture)
      texture.textureId = textureId
      texture.registry = textureRegistry
      textures[textureId] = texture
      // Native frame dims are reported once the embody runtime sizes its
      // texture (416x720) — push it to Dart so the canvas lays out with the
      // stream instead of a stale box. Installed BEFORE startRendering.
      texture.onFrameDimsChanged = { [weak self] w, h in
        DispatchQueue.main.async {
          self?.channel?.invokeMethod("frameDimsChanged", arguments: [
            "textureId": textureId, "width": w, "height": h,
          ])
        }
      }
      // MODEL_REJECTED after load returned (Expression 2: its warm-up could not load the files):
      // pushed to Dart, which ends the session on it (2.6.29). Installed BEFORE startRendering.
      texture.onModelRejected = { [weak self] r in
        DispatchQueue.main.async {
          var args = r.details
          args["textureId"] = textureId
          self?.channel?.invokeMethod("modelRejected", arguments: args)
        }
      }
      texture.startRendering()
      // ★MODEL_REJECTED (2.6.29): the engine refused its file while this load created it (Essence 2:
      // be_essence2_create -2 / -4). Until now the texture stayed up with a gray still face and the
      // app waited on a readiness that never came; now the load fails with the engine's code.
      if let refusal = texture.modelRefusal {
        NSLog("[BithumanAvatar] load id=%lld engine=%@ MODEL_REJECTED: %@", textureId, texture.engineKind, refusal.message)
        textures.removeValue(forKey: textureId)
        texture.shutdown()
        textureRegistry.unregisterTexture(textureId)
        result(FlutterError(code: BithumanModelRefusal.code, message: refusal.message, details: refusal.details))
        return
      }
      NSLog("[BithumanAvatar] load id=%lld engine=%@ path=%@", textureId, texture.engineKind, path)
      result(textureId)

    case "pushAudio":
      guard let args = call.arguments as? [String: Any],
            let textureId = args["textureId"] as? Int64,
            let pcm = args["pcm"] as? FlutterStandardTypedData else {
        result(FlutterError(code: "BAD_ARGS",
                            message: "pushAudio requires textureId + pcm",
                            details: nil))
        return
      }
      textures[textureId]?.enqueuePCM(pcm.data)
      result(nil)

    case "dispose":
      guard let args = call.arguments as? [String: Any],
            let textureId = args["textureId"] as? Int64 else {
        result(FlutterError(code: "BAD_ARGS",
                            message: "dispose requires textureId",
                            details: nil))
        return
      }
      // The audio unit first: once it is stopped nothing of it feeds or queries the engine,
      // then the texture lets the engine go (AvatarTexture.shutdown — safe at any moment).
      audioIOs[textureId]?.stop()
      audioIOs.removeValue(forKey: textureId)
      micChannels.removeValue(forKey: textureId)
      if let tex = textures.removeValue(forKey: textureId) {
        tex.shutdown()
        registrarTextures?.unregisterTexture(textureId)
      }
      result(nil)

    case "engineVersion":
      result("expression-2 (pure-Swift/CoreML)")

    case "isLocalModeSupported":
      // LOCAL mode (on-device converse brain) binds Apple's SpeechAnalyzer,
      // which is `@available(macOS 26.0, iOS 26.0)`. Probe the running OS so
      // the Dart side can DISABLE the toggle with a clear reason on older
      // systems instead of letting the user hit the UNSUPPORTED_OS error in
      // `localAudioStart` only at session start.
      if #available(macOS 26.0, iOS 26.0, *) {
        result(true)
      } else {
        result(false)
      }

    // dual-accept: "setExpression2AgentDir" is canonical; "setEmbodyAgentDir" stays
    // accepted forever (cross-boundary SDK↔app channel string contract).
    case "setExpression2AgentDir", "setEmbodyAgentDir":
      // Gallery: point the expression-2 runtime at a DOWNLOADED per-agent model —
      // a DIRECTORY of members, or the packed container the download
      // endpoint vends, which is expanded here (see bhResolveExpression2AgentDir).
      // Pass null/"" to revert to the bundled
      // default (A42). The shared w2v/taehv graphs always come from the app
      // bundle. Set BEFORE the next `load` (engine: expression2) so the new
      // Expression2Runtime warms from this dir. Both platforms: the expression-2
      // adapter is compiled for iOS and macOS alike, and a downloaded or pushed agent
      // is the ONLY way a phone can render anything but the bundled default.
      let dir = (call.arguments as? [String: Any])?["dir"] as? String
      // ★ OFF the platform thread. Expanding a ~200 MB container here blocked the
      // platform thread — which Flutter now merges with the UI thread — for 0.3-0.5 s on
      // an iPhone 15 on EVERY cold start and character switch: the first frame, the
      // placeholder and the countdown all waited behind it. One serial queue, so two
      // switches never expand into the same directory at once; the engine dir is set on
      // main before `result`, so the `load` Dart awaits next still sees it.
      bhExpandQueue.async {
        let resolved = bhResolveExpression2AgentDir(dir)
        DispatchQueue.main.async {
          Expression2Engine.activeAgentDir = resolved
          NSLog("[BithumanAvatar] setExpression2AgentDir → %@", resolved ?? "<bundled default>")
          result(nil)
        }
      }

    // The Dart half of this plugin is public source and carries NO reader for
    // bitHuman's container (owner ruling 2026-09-16: the format stays in private
    // repositories and compiled bytes). A downloaded `.avatar` that is not a zip
    // is expanded HERE, by the engine's own unpacker, into the directory the Dart
    // installer then verifies. Off the platform thread: a container is ~200 MB.
    case "unpackModelContainer":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String,
            let dir = args["dir"] as? String else {
        result(FlutterError(code: "BAD_ARGS", message: "unpackModelContainer requires path + dir", details: nil))
        return
      }
      let src = URL(fileURLWithPath: path)
      guard Expression2Container.isContainer(src) else {
        result(FlutterError(code: "NOT_A_CONTAINER",
                            message: "\(src.lastPathComponent) is not a bitHuman model container",
                            details: nil))
        return
      }
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          let t0 = CFAbsoluteTimeGetCurrent()
          let names = try Expression2Container.unpack(src, to: URL(fileURLWithPath: dir, isDirectory: true))
          NSLog("[BithumanAvatar] unpackModelContainer %@ -> %@ (%d members, %.2fs)",
                src.lastPathComponent, dir, names.count, CFAbsoluteTimeGetCurrent() - t0)
          DispatchQueue.main.async { result(names.count) }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(code: "UNPACK_FAILED", message: "\(error)", details: nil))
          }
        }
      }

    case "isModelContainer":
      guard let path = (call.arguments as? [String: Any])?["path"] as? String else {
        result(FlutterError(code: "BAD_ARGS", message: "isModelContainer requires path", details: nil))
        return
      }
      result(Expression2Container.isContainer(URL(fileURLWithPath: path)))

    case "micPermissionStatus":
      // "authorized" | "notDetermined" | "denied" — drives the status-chip color.
      switch AVCaptureDevice.authorizationStatus(for: .audio) {
      case .authorized:    result("authorized")
      case .notDetermined: result("notDetermined")
      default:             result("denied")
      }

    case "requestMicPermission":
      // notDetermined → OS prompt; denied → open the Microphone privacy pane.
      // Returns the resulting status so the chip can refresh.
      switch AVCaptureDevice.authorizationStatus(for: .audio) {
      case .authorized:
        result("authorized")
      case .notDetermined:
        AVCaptureDevice.requestAccess(for: .audio) { granted in
          DispatchQueue.main.async { result(granted ? "authorized" : "denied") }
        }
      default:
        // macOS-only: deep-links macOS System Settings; iOS uses its own Settings URL elsewhere
        #if os(macOS)
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
          NSWorkspace.shared.open(u)
        }
        #endif
        result("denied")
      }

    case "frameSize":
      // Native frame dimensions for the texture (embody: 416x720, known once
      // the runtime sizes the texture at load).
      guard let args = call.arguments as? [String: Any],
            let textureId = args["textureId"] as? Int64,
            let texture = textures[textureId] else {
        result(FlutterError(code: "BAD_ARGS", message: "frameSize requires textureId", details: nil))
        return
      }
      let (fw, fh) = texture.nativeFrameSize
      result(["width": fw, "height": fh])

    case "setDisplayMode":
      // Display mode: "full" or "head". Embody has no native head mode, so
      // this returns false and Dart keeps its center-crop bubble fallback.
      guard let args = call.arguments as? [String: Any],
            let textureId = args["textureId"] as? Int64,
            let modeStr = args["mode"] as? String,
            let texture = textures[textureId] else {
        result(FlutterError(code: "BAD_ARGS",
                            message: "setDisplayMode requires textureId + mode",
                            details: nil))
        return
      }
      result(texture.setDisplayMode(head: modeStr == "head"))

    case "setIdleHold":
      // Bubble battery saver (see AvatarTexture.setIdleHold): no-op for embody
      // (its idle is a zero-inference pre-rendered loop), kept for API parity.
      guard let args = call.arguments as? [String: Any],
            let textureId = args["textureId"] as? Int64,
            let hold = args["hold"] as? Bool,
            let texture = textures[textureId] else {
        result(FlutterError(code: "BAD_ARGS",
                            message: "setIdleHold requires textureId + hold",
                            details: nil))
        return
      }
      texture.setIdleHold(hold)
      result(nil)

    case "pipAvailable":
      // iOS system Picture-in-Picture (sample-buffer PiP, iOS 15+). False
      // everywhere PiP can't float (macOS, simulator without PiP support).
      #if os(iOS)
      result(AVPictureInPictureController.isPictureInPictureSupported())
      #else
      result(false)
      #endif

    case "pipStart":
      // iOS: float the avatar over the SYSTEM in Picture-in-Picture. Tees
      // the texture's CVPixelBuffer stream into an AVSampleBufferDisplayLayer
      // behind AVPictureInPictureController (the camera-app pattern), with
      // the circular bubble mask rendered INTO the buffers (PiP has no
      // transparency). Returns true when the controller was created and the
      // start was kicked off; the async outcome arrives as pipEvent
      // started/failed, so Dart keeps its in-app overlay fallback on false
      // OR on a later "failed".
      #if os(iOS)
      guard let args = call.arguments as? [String: Any],
            let textureId = args["textureId"] as? Int64,
            let texture = textures[textureId] else {
        result(FlutterError(code: "BAD_ARGS",
                            message: "pipStart requires textureId",
                            details: nil))
        return
      }
      guard AVPictureInPictureController.isPictureInPictureSupported() else {
        NSLog("[pip] not supported on this device — Dart falls back to the in-app overlay")
        result(false)
        return
      }
      pip?.stop()
      let session = AvatarPiP(texture: texture) { [weak self] event in
        DispatchQueue.main.async {
          self?.channel?.invokeMethod("pipEvent", arguments: [
            "textureId": textureId, "event": event,
          ])
        }
      }
      pip = session
      result(session.start())
      #else
      result(false)
      #endif

    case "pipStop":
      #if os(iOS)
      pip?.stop()
      pip = nil
      #endif
      result(nil)

    case "isReady":
      // Engine readiness for Dart's 500 ms poll (BithumanAvatar.ready).
      // Embody's create returns fast while its 4 CoreML graphs warm on a
      // background thread (first run on a machine pays a one-time ANE/CoreML
      // compile); isReady flips true once the speech path is live.
      guard let args = call.arguments as? [String: Any],
            let textureId = args["textureId"] as? Int64,
            let texture = textures[textureId] else {
        result(FlutterError(code: "BAD_ARGS", message: "isReady requires textureId", details: nil))
        return
      }
      result(texture.isEngineReady())

    case "fitWindowToCanvas":
      // macOS: adopt the canvas aspect for the window — portrait canvas ->
      // portrait window — sized to ~90% of the limiting screen dimension and
      // centered; aspect locked for user resizes. No-op elsewhere.
      guard let args = call.arguments as? [String: Any],
            let cw = args["width"] as? Int, let ch = args["height"] as? Int,
            cw > 0, ch > 0 else {
        result(FlutterError(code: "BAD_ARGS", message: "fitWindowToCanvas requires width+height", details: nil))
        return
      }
      // macOS-only: resizes the AppKit window; iOS has no resizable window
      #if os(macOS)
      DispatchQueue.main.async {
        guard let win = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }) else {
          result(nil); return
        }
        let vis = (win.screen ?? NSScreen.main)?.visibleFrame
                  ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Default window = 2× the native 1:1 size. Native 1:1 (sharpest) is the
        // frame PIXELS (cw×ch) in POINTS via the backing scale — on a 2× Retina
        // display a 416×720 video → 208×360 pt — but that's too small, so open at
        // 2× → 416×720 pt (light up-scale, still crisp on Retina). Shrink only if
        // 2× wouldn't fit 90% of the screen.
        let bs = win.backingScaleFactor > 0 ? win.backingScaleFactor : 2.0
        let zoom: CGFloat = 2.0
        let nativeW = CGFloat(cw) / bs * zoom, nativeH = CGFloat(ch) / bs * zoom
        let cap = min(vis.width * 0.9 / nativeW, vis.height * 0.9 / nativeH, 1.0)
        let size = NSSize(width: nativeW * cap, height: nativeH * cap)
        win.contentAspectRatio = NSSize(width: CGFloat(cw), height: CGFloat(ch))
        win.setContentSize(size)
        win.setFrameOrigin(NSPoint(x: vis.midX - win.frame.width / 2,
                                   y: vis.midY - win.frame.height / 2))
        NSLog("[BithumanAvatar] window fit to canvas %dx%d -> content %.0fx%.0f", cw, ch, size.width, size.height)
        result(nil)
      }
      #else
      result(nil)
      #endif

    case "audioStart":
      // Stand up the VP-IO audio engine for this texture's session.
      // Also installs a Flutter EventChannel at
      // ai.bithuman.avatar.mic/<textureId> for 24 kHz PCM16 mic chunks.
      // ★NO TEXTURE REQUIRED. `textureId` names the SESSION; a registered texture
      // is optional. It used to be bound in this guard and the handler refused
      // BAD_ARGS without one — which is what made RealtimeAudioIO's no-avatar
      // branch (speaker scheduled directly, no lipsync work) unreachable: there
      // was no way to construct the audio unit with a nil sink. Voice is now
      // standable with no render at all; with a texture registered under this id
      // the behaviour is byte-for-byte what it was.
      guard let args = call.arguments as? [String: Any],
            let textureId = args["textureId"] as? Int64 else {
        result(FlutterError(code: "BAD_ARGS",
                            message: "audioStart requires textureId",
                            details: nil))
        return
      }
      if audioIOs[textureId] == nil {
        let io = RealtimeAudioIO()
        io.lipsyncSink = textures[textureId]   // nil = headless voice session
        forwardInterruptions(of: io, textureId: textureId)
        audioIOs[textureId] = io
        if let messenger = registrarMessenger {
          // Unique per-session name (textureId/micGen) so the previous
          // session's in-flight EventChannel `cancel` can't null THIS session's
          // mic sink (the rapid-switch dead-mic race). Must match Dart exactly.
          let micGen = args["micGen"] as? Int ?? 0
          let micChan = FlutterEventChannel(
            name: "ai.bithuman.avatar.mic/\(textureId)/\(micGen)",
            binaryMessenger: messenger)
          micChan.setStreamHandler(io)
          // RETAIN the channel — without this, ARC frees it when this
          // method returns and the mic stream silently never delivers
          // chunks to Dart even though the native tap is firing.
          micChannels[textureId] = micChan
          NSLog("[BithumanAvatar] mic EventChannel registered: %@", micChan)
        }
      }
      // Captions (2.6.27): `speechPlayout` {textureId, micGen, played, fed} — how much of the
      // agent's audio handed to playSpeakerPCM since this audioStart has been heard. The counts
      // restart here; Dart drops a push carrying any other micGen.
      if let io = audioIOs[textureId] {
        let playoutGen = args["micGen"] as? Int ?? 0
        io.resetPlayout()
        io.onPlayout = { [weak self] played, fed in
          self?.channel?.invokeMethod("speechPlayout", arguments: [
            "textureId": textureId, "micGen": playoutGen, "played": played, "fed": fed,
          ])
        }
      }
      let enableMic = args["enableMic"] as? Bool ?? true
      let vadThreshold = args["vadThreshold"] as? Int
      // Uplink gain policy from the Dart echo table (EchoProfile.current.vpioAgc).
      let vpioAgc = args["vpioAgc"] as? Bool ?? true
      let doStart: () -> Void = { [weak self] in
        do {
          try self?.audioIOs[textureId]?.start(vadThreshold: vadThreshold.map { Int32($0) }, mic: enableMic, vpioAgc: vpioAgc)
          result(nil)
        } catch {
          result(FlutterError(code: "AUDIO_START_FAILED",
                              message: error.localizedDescription, details: nil))
        }
      }
      // Fallback when the mic isn't granted: start SPEAKER-ONLY (mic: false)
      // instead of starting the input node under denied permission — that is what
      // produced the "9-channel digital-silence mic" on macOS 26 (the OS hands a
      // denied app a live-looking but silent input bus, and VP-IO can't init on
      // it). The agent still speaks; the UI surfaces "Microphone is off". The
      // session is up, so result still succeeds.
      let doStartMicOff: () -> Void = { [weak self] in
        NSLog("[BithumanAvatar] mic not granted → starting speaker-only")
        do {
          try self?.audioIOs[textureId]?.start(vadThreshold: vadThreshold.map { Int32($0) }, mic: false, vpioAgc: vpioAgc)
          result(nil)
        } catch {
          result(FlutterError(code: "AUDIO_START_FAILED",
                              message: error.localizedDescription, details: nil))
        }
      }
      // Text-only session (enableMic=false): speaker-only, never touch the mic →
      // macOS never prompts for permission. Just start.
      if !enableMic {
        doStart()
        return
      }
      // Mic permission gate — runs every time the user taps the mic. Only start
      // the mic engine under GRANTED permission; otherwise start speaker-only and
      // (on a hard denial) open the Microphone privacy pane so the user can grant.
      switch AVCaptureDevice.authorizationStatus(for: .audio) {
      case .authorized:
        doStart()
      case .notDetermined:
        NSLog("[BithumanAvatar] mic permission undetermined → prompting")
        AVCaptureDevice.requestAccess(for: .audio) { granted in
          DispatchQueue.main.async {
            NSLog("[BithumanAvatar] mic permission %@", granted ? "granted" : "denied")
            granted ? doStart() : doStartMicOff()
          }
        }
      default:   // .denied / .restricted — can't re-prompt; send the user to Settings
        NSLog("[BithumanAvatar] mic permission denied → speaker-only + opening System Settings (Microphone)")
        // macOS-only: deep-links macOS System Settings; iOS uses its own Settings URL elsewhere
        #if os(macOS)
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
          NSWorkspace.shared.open(u)
        }
        #endif
        doStartMicOff()
      }

    case "audioStop":
      guard let args = call.arguments as? [String: Any],
            let textureId = args["textureId"] as? Int64 else {
        result(FlutterError(code: "BAD_ARGS",
                            message: "audioStop requires textureId",
                            details: nil))
        return
      }
      audioIOs[textureId]?.stop()
      audioIOs.removeValue(forKey: textureId)
      micChannels.removeValue(forKey: textureId)
      result(nil)

    case "interrupt":
      // Barge-in: kill the agent's in-flight playback + lipsync.
      // Called from Dart the moment input_audio_buffer.speech_started
      // arrives from OpenAI (well before silence_duration_ms detects
      // end-of-user-turn). `reason` names the caller on the CUT line.
      guard let args = call.arguments as? [String: Any],
            let textureId = args["textureId"] as? Int64 else {
        result(FlutterError(code: "BAD_ARGS",
                            message: "interrupt requires textureId",
                            details: nil))
        return
      }
      audioIOs[textureId]?.barge(reason: (args["reason"] as? String) ?? "app")
      result(nil)

    case "log":
      // The transport's instrument lines, into the same stream as the presenter's.
      // ★A release iOS build's Dart `print` reaches the unified log only, never the
      // console `devicectl` attaches; NSLog reaches both.
      if let args = call.arguments as? [String: Any], let line = args["line"] as? String {
        NSLog("%@", line)
      }
      result(nil)

    case "notifyTurnEnd":
      // Cloud turn-end (OpenAI response.done): flush the final partial lipsync
      // chunk so the last word isn't clipped. Driven by the explicit server
      // signal only (Dart defers it until the audio pacing queue drains +
      // gen-gates it for barge-safety — see bithuman_realtime.dart).
      guard let args = call.arguments as? [String: Any],
            let textureId = args["textureId"] as? Int64 else {
        result(FlutterError(code: "BAD_ARGS",
                            message: "notifyTurnEnd requires textureId",
                            details: nil))
        return
      }
      #if os(macOS) || os(iOS)
      textures[textureId]?.onTurnEnd()
      #endif
      result(nil)

    case "playSpeakerPCM":
      // Take a chunk of 24 kHz PCM16 bot audio from OpenAI Realtime,
      // schedule it for playback, AND push the same chunk (resampled
      // to 16 kHz) into the avatar's lipsync queue. Both happen
      // synchronously here so A/V stays paired chunk-by-chunk.
      guard let args = call.arguments as? [String: Any],
            let textureId = args["textureId"] as? Int64,
            let pcm = args["pcm"] as? FlutterStandardTypedData,
            let io = audioIOs[textureId] else {
        result(FlutterError(code: "BAD_ARGS",
                            message: "playSpeakerPCM requires audioStart + textureId + pcm",
                            details: nil))
        return
      }
      io.playSpeakerPCM24k(pcm.data)
      result(nil)

    #if os(macOS) || os(iOS)
    case "localAudioStart":
      #if !CONVERSE_AVAILABLE
      // Built without libconverse.xcframework. Refuse by NAME rather than crash or
      // return a silent nil: a developer who reaches this has a working cloud path
      // and needs to be told which component is absent, not left guessing.
      result(FlutterError(code: "CONVERSE_UNAVAILABLE",
                          message: "This build has no on-device conversation brain "
                                 + "(libconverse.xcframework was not staged). The CLOUD "
                                 + "realtime path, the avatar and both engines are "
                                 + "unaffected — use BithumanRealtimeSession instead.",
                          details: nil))
      return
      #else
      // LOCAL mode: the on-device brain (Apple ASR → Qwen → Supertonic via
      // converse) drives the SAME RealtimeAudioIO (mic/speaker/avatar) and the
      // SAME avatar Texture the cloud path uses — only the brain differs.
      // ★NO TEXTURE REQUIRED — same cut as `audioStart` above. The on-device
      // brain drives the same RealtimeAudioIO; the avatar is optional there too.
      guard let args = call.arguments as? [String: Any],
            let textureId = args["textureId"] as? Int64,
            let gguf = args["ggufPath"] as? String else {
        result(FlutterError(code: "BAD_ARGS",
                            message: "localAudioStart requires textureId + ggufPath", details: nil))
        return
      }
      guard #available(macOS 26.0, iOS 26.0, *) else {
        result(FlutterError(code: "UNSUPPORTED_OS",
                            message: "local mode requires macOS 26 / iOS 26 (SpeechAnalyzer)", details: nil))
        return
      }
      if audioIOs[textureId] == nil {
        let io = RealtimeAudioIO()
        io.lipsyncSink = textures[textureId]   // nil = headless local voice session
        forwardInterruptions(of: io, textureId: textureId)
        audioIOs[textureId] = io
      }
      guard let io = audioIOs[textureId] else {
        result(FlutterError(code: "NO_AUDIO_IO", message: "audio IO unavailable", details: nil)); return
      }
      // Register the UI EventChannel + handler SYNCHRONOUSLY first, so the Dart
      // side's `converseEvents.listen` (which fires the moment this method
      // returns) reaches a registered channel and its sink attaches before any
      // event is emitted. Subscribing before registration silently drops every
      // event — that was the "no captions" bug.
      let handler = ConverseEventStreamHandler()
      if let messenger = registrarMessenger {
        let ch = FlutterEventChannel(name: "ai.bithuman.avatar.converse/\(textureId)",
                                     binaryMessenger: messenger)
        ch.setStreamHandler(handler)
        converseChannels[textureId] = ch
      }
      // Barge-in for local mode is ENERGY-driven (the unified path): RealtimeAudioIO
      // fires the barge the moment the post-AEC mic energy crosses `vadThreshold`,
      // and LocalConverseController's onBarge cancels the brain turn. The Dart
      // default (DevConfig.defaultVadThreshold) ships > 0 so it's on; 0 disables it.
      let vad = (args["vadThreshold"] as? Int).map { Int32($0) } ?? 0
      let supertonicAssets = args["supertonicAssets"] as? String
      let voice = (args["voice"] as? String) ?? "M1"
      // Personality prompt for the on-device LLM. Persisted in the app's
      // config.json and forwarded straight into the converse cfg.system_prompt.
      let systemPrompt = args["systemPrompt"] as? String ?? ""
      // Return to Dart immediately, then load the GGUF + Supertonic ONNX models
      // OFF the main thread (multi-second) so the UI never freezes. Progress is
      // surfaced to the UI as loading/ready/error events on the channel above.
      result(nil)
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        let ctrl = LocalConverseController(io: io, gguf: gguf, supertonicAssets: supertonicAssets,
                                           voice: voice, systemPrompt: systemPrompt)
        DispatchQueue.main.async {
          guard let self = self, self.audioIOs[textureId] != nil else { return }  // disposed mid-load
          guard let ctrl = ctrl else {
            handler.emit(["kind": "error",
                          "message": "converse session failed (check gguf path + BITHUMAN_API_SECRET)"])
            return
          }
          ctrl.onEvent = { [weak handler] ev in handler?.emit(ev) }
          self.converseControllers[textureId] = ctrl
          do {
            try io.start(vadThreshold: vad)
            handler.emit(["kind": "ready"])
          } catch {
            handler.emit(["kind": "error", "message": error.localizedDescription])
          }
        }
      }

      #endif  // CONVERSE_AVAILABLE

    case "localAudioStop":
      guard let args = call.arguments as? [String: Any],
            let textureId = args["textureId"] as? Int64 else {
        result(FlutterError(code: "BAD_ARGS", message: "localAudioStop requires textureId", details: nil)); return
      }
      #if CONVERSE_AVAILABLE
      if #available(macOS 26.0, iOS 26.0, *) {
        (converseControllers[textureId] as? LocalConverseController)?.stop()
      }
      #endif
      converseControllers.removeValue(forKey: textureId)
      converseChannels.removeValue(forKey: textureId)
      audioIOs[textureId]?.stop()
      audioIOs.removeValue(forKey: textureId)
      result(nil)

    case "localPushText":
      // LOCAL mode: feed a typed user message to the on-device brain (same as a
      // spoken turn). No textureId is sent — forward to the active converse
      // session(s) (there is one local session at a time).
      guard let args = call.arguments as? [String: Any],
            let text = args["text"] as? String else {
        result(FlutterError(code: "BAD_ARGS", message: "localPushText requires text", details: nil)); return
      }
      #if CONVERSE_AVAILABLE
      if #available(macOS 26.0, iOS 26.0, *) {
        for (_, ctrl) in converseControllers {
          (ctrl as? LocalConverseController)?.pushText(text)
        }
      }
      #endif
      result(nil)

    case "localSetMuted":
      // LOCAL mode: mute/unmute the local mic. Sets RealtimeAudioIO.micMuted,
      // which gates ONLY the mic→brain (STT) forward — speaker + avatar are
      // untouched. No textureId is sent — apply to the active audio IO(s).
      guard let args = call.arguments as? [String: Any],
            let muted = args["muted"] as? Bool else {
        result(FlutterError(code: "BAD_ARGS", message: "localSetMuted requires muted", details: nil)); return
      }
      for (_, io) in audioIOs { io.micMuted = muted }
      result(nil)
    #endif

    case "attachWebrtcRemoteAudio":
      #if os(iOS)
      guard let args = call.arguments as? [String: Any],
            let textureId = args["textureId"] as? Int64,
            let trackId = args["trackId"] as? String,
            let texture = textures[textureId] else {
        result(FlutterError(code: "BAD_ARGS", message: "attachWebrtcRemoteAudio requires textureId + trackId", details: nil)); return
      }
      if let prev = texture.webrtcLipsyncRenderer { prev.detach(); texture.webrtcLipsyncRenderer = nil }
      let r = WebrtcLipsyncRenderer(texture: texture)
      if r.attach(trackId: trackId) {
        texture.webrtcLipsyncRenderer = r
        NSLog("[BithumanAvatar] WebRTC lipsync attached textureId=%lld track=%@", textureId, trackId)
        result(nil)
      } else {
        result(FlutterError(code: "WEBRTC_TAP_FAILED", message: "could not reach flutter_webrtc remote track \(trackId)", details: nil))
      }
      #else
      result(FlutterMethodNotImplemented)
      #endif
    case "detachWebrtcRemoteAudio":
      #if os(iOS)
      if let args = call.arguments as? [String: Any], let textureId = args["textureId"] as? Int64 {
        textures[textureId]?.webrtcLipsyncRenderer?.detach()
        textures[textureId]?.webrtcLipsyncRenderer = nil
        textures[textureId]?.clearAudioQueue()
      }
      result(nil)
      #else
      result(FlutterMethodNotImplemented)
      #endif

    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

/// Conforms to `LipsyncSink` (Protocol/LipsyncSink.swift) — the twelve members
/// the voice unit uses, and the ONLY surface `RealtimeAudioIO` may touch here.
/// Adding a member to this class does NOT widen that edge; widening it means
/// editing the protocol, in a file whose whole job is to be read.
final class AvatarTexture: NSObject, FlutterTexture, LipsyncSink {
  /// The avatar engine is selected at load time (see `engineKind`). The path
  /// arg is just a non-empty marker (e.g. "embody://A42CQW8788") — the embody
  /// runtime loads its CoreML graphs from the app bundle / dev dir, not from
  /// this path; the essence2 adapter reads the `.elevatedir` from a static set
  /// by the load handler.
  let imxPath: String
  /// Which engine this texture drives: "embody" (default/fallback, pure-Swift/
  /// CoreML) or "essence2" (on-device Essence2, ESSENCE2_AVAILABLE-gated). Set by
  /// the `load` handler before startRendering; anything unknown coerces to embody.
  var engineKind: String = "embody"
  /// Static behaviour of the live engine, resolved from the slug at load
  /// (EngineRegistry.capabilities) and reaffirmed from the created engine in
  /// loadFixtureAndRuntime. This REPLACES every `engineKind == "essence2"` policy
  /// branch (audioReleaseSeconds / cushion / the
  /// composeTick drive-model selection). Defaults to the expression2 profile so a
  /// read before load — and the iOS path, where no engine instantiates — matches
  /// the old `engineKind != "essence2"` default. Cross-platform (EngineCapabilities
  /// has zero native deps; the read must compile everywhere RealtimeAudioIO does).
  var capabilities: EngineCapabilities = .expression2
  /// essence2 actor `.bhx` dir from the load args (nil = engine default). Carried
  /// into the AvatarRef that EngineRegistry.make consumes.
  var motionDir: String?
  /// The host app's api-secret from the load args (nil = none given). Carried into
  /// the AvatarRef; essence-2's self-host meter bills the session to it.
  var apiSecret: String?
  /// Bot audio released per published SPEECH frame = 1/displayFps. embody runs at
  /// 20 fps (0.05 s); essence2 at 25 fps (0.04 s). A constant 0.05 over-demands at
  /// 25 fps (releases more audio than a frame carries → A/V drift). Read by
  /// RealtimeAudioIO.releaseEmbodyAudioFrame. Cross-platform (the read must compile
  /// everywhere RealtimeAudioIO does). Now keyed off capabilities, not the string.
  var audioReleaseSeconds: Double { capabilities.audioReleaseSeconds }
  var textureId: Int64 = 0
  weak var registry: FlutterTextureRegistry?

  #if os(iOS)
  // Holds the libwebrtc remote-audio → lipsync tap for this texture's
  // session, when the WebRTC transport is active (iOS only; macOS uses
  // the WebSocket / native VP-IO path). Detached + niled in shutdown().
  var webrtcLipsyncRenderer: WebrtcLipsyncRenderer?
  #endif

  init(imxPath: String) {
    self.imxPath = imxPath
    super.init()
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    pixelBufferLock.lock()
    let buf = latestPixelBuffer
    pixelBufferLock.unlock()
    guard let pb = buf else { return nil }
    return Unmanaged.passRetained(pb)
  }

  // ---- the conversation instrument (read by tools/conformance conversation_apple) ----
  // `bhfeed`: what reached the ENGINE and when. `bhttfa`: a reply's first speech frame
  // on the glass. `bhrun HOLD`: ticks in speech with no frame to show (the display is
  // the speaker's clock here, so a hold is silence). `bhfifo`, once a second in
  // speech: how much audio is waiting in front of the engine and behind it. `bhbarge`
  // RESET / IDLE-SHOWN / NEW-MOUTH / LEAK per cut, LEAK being an old-reply speech
  // frame that reached the glass after the cut — COUNTED here, not prevented.
  private var audioArrived = 0
  private var audioFed = 0
  private var bargeEpoch = 0
  private var bargeAt: CFTimeInterval = 0
  private var bargeIdlePending = false
  private var audioSinceBarge = true
  private var bargeLeaks = 0
  private var bargeFenced = 0
  private var replyFirstFramePending = false
  private var holdTicks = 0
  private var holdRuns = 0
  private var fifoLineAt: CFTimeInterval = 0
  private var ticksWithFrame1s = 0, ticksWithout1s = 0

  // ---- Essence 2: the voice on its own clock (2.6.30; VoiceClock.swift has the why) ----
  /// The open stream's voice (24 kHz) not yet handed to the speaker. Guarded by audioLock.
  private var voiceQueue: [Float] = []
  /// Where in voiceQueue a NEW stream's voice begins while the previous stream's unplayed voice is
  /// still in front of it (audio after >= idleResetSecs of none: the engine resets on the next tick,
  /// and the old stream's voice goes with its frames). Guarded by audioLock.
  private var voiceStreamCut: Int? = nil
  /// The voice unit hands this texture the voice (enqueueVoice). Without it (Dart's pushAudio, the iOS
  /// WebRTC tap) the speaker is not ours to clock, and frames are shown in turn as before. audioLock.
  private var voiceSeen = false
  /// The reply the arriving audio belongs to, when its first audio came, whether its turn ended, and
  /// which reply a barge-in cut. Guarded by audioLock.
  private var replySeq = 0
  private var replyFirstAudioAt: CFTimeInterval = 0
  private var turnEndedForReply = false
  private var bargedReply = -1
  /// Installed by the voice unit (RealtimeAudioIO.scheduleVoiceSlice).
  var scheduleVoice: (([Float]) -> CFTimeInterval?)? = nil
  /// The load option `skipAhead` (Dart BithumanAvatar.load); nil = the default.
  var skipAhead: Bool? = nil
  /// Skip-ahead's default on Apple: OFF, as on Android in 2.6.29 — the app opts in per load.
  static let skipAheadDefault = false
  // renderQueue only:
  private let voiceClock = VoiceClock()
  private var voiceOpen = false
  private var voiceFirstFrameAt: CFTimeInterval = 0
  private var voiceDrySince: CFTimeInterval = 0
  /// A pulled frame waiting for its voice; its pixels are in bgrBuffer (nothing else writes it meanwhile).
  private var heldFrame: (bytes: Int, speech: Bool, start16: Int64)? = nil
  /// The next speech frame's ordinal when the engine names none (an engine before skip-ahead).
  private var deliveredSpeech: Int64 = 0
  private var replyMeter: VoiceReplyMeter? = nil
  private var meterReply = -1
  private var skippedAtReplyStart: Int64 = 0
  private var replyLineAt: CFTimeInterval = 0
  /// The voice opens this long after a reply's first speech frame is ready.
  private static let voiceCushion: Double = DevLevers.e2CushionMs.map { $0 / 1000 } ?? VoiceClockPolicy.cushionSeconds
  private func noteHoldRunEnded() {
    holdRuns += 1
    NSLog("[bhrun] HOLD %d ticks (%d ms) ended at hostMs=%lld holds=%d", holdTicks, holdTicks * 40,
          Int64(Date().timeIntervalSince1970 * 1000), holdRuns)
    holdTicks = 0
  }
  private func noteSpeechFramePresented(_ now: CFTimeInterval) {
    audioLock.lock()
    let first = replyFirstFramePending; replyFirstFramePending = false
    let cut = bargeAt; if first { bargeAt = 0 }
    audioLock.unlock()
    if first {
      NSLog("[bhttfa] first speech frame hostMs=%lld", Int64(Date().timeIntervalSince1970 * 1000))
      if cut > 0 {
        NSLog("[bhbarge] NEW-MOUTH sinceCutMs=%.0f leaks=%d", (now - cut) * 1000, bargeLeaks)
      }
    }
  }
  private func noteIdleFramePresented() {
    audioLock.lock()
    let pending = bargeIdlePending; bargeIdlePending = false
    let cut = bargeAt
    audioLock.unlock()
    if pending, cut > 0 {
      NSLog("[bhbarge] IDLE-SHOWN sinceCutMs=%.0f hostMs=%lld", (CACurrentMediaTime() - cut) * 1000,
            Int64(Date().timeIntervalSince1970 * 1000))
    }
  }
  /// Once a second while in speech: the audio in front of the engine (this queue),
  /// the frames behind it, and how many of the last second's ticks had a frame.
  private func noteFifo(_ now: CFTimeInterval, queuedFrames: Int, hadFrame: Bool) {
    if hadFrame { ticksWithFrame1s += 1 } else { ticksWithout1s += 1 }
    if now - fifoLineAt >= 1.0 {
      audioLock.lock(); let ahead = audioQueue.count; audioLock.unlock()
      NSLog("[bhfifo] unfedMs=%d q=%d ticksWithFrame=%d ticksWithout=%d hostMs=%lld",
            ahead * 1000 / 16000, queuedFrames, ticksWithFrame1s, ticksWithout1s,
            Int64(Date().timeIntervalSince1970 * 1000))
      ticksWithFrame1s = 0; ticksWithout1s = 0; fifoLineAt = now
    }
  }

  /// Drop everything queued for lipsync and slide the avatar back to looping
  /// idle until the next bot chunk lands. Used by the barge-in path so the
  /// avatar stops animating the cancelled response.
  ///
  /// embody: reset the runtime stream NOW so the cancelled response's in-flight
  /// lip-frames are dropped immediately — the pre-rendered idle LOOP covers the
  /// gap (no frozen frame), so deferring the reset is unnecessary.
  func clearAudioQueue() {
    var qBefore = 0
    #if os(macOS) || os(iOS)
    qBefore = avatar?.queuedFrames ?? 0
    #endif
    audioLock.lock()
    let dropped = audioQueue.count
    audioQueue.removeAll(keepingCapacity: true)
    pendingUtteranceReset = true
    bargeEpoch &+= 1
    bargeAt = CACurrentMediaTime()
    bargeIdlePending = true
    audioSinceBarge = false
    replyFirstFramePending = false
    let voiceDropped = voiceQueue.count
    voiceQueue.removeAll(keepingCapacity: true); voiceStreamCut = nil   // the cut reply's voice is never heard
    bargedReply = replySeq
    audioLock.unlock()
    if voiceDropped > 0 { NSLog("[bhvoice] CUT: %d ms of the reply's voice not played", voiceDropped * 1000 / 24000) }
    NSLog("[bhbarge] RESET q=%d unfedSamples=%d hostMs=%lld", qBefore, dropped,
          Int64(Date().timeIntervalSince1970 * 1000))
    #if os(macOS) || os(iOS)
    // embody: drop the buffered speech frames + reset the stream NOW (not on the
    // next compose tick) so a hang-up / barge stops the avatar INSTANTLY — with
    // the deep feed-ahead queue, deferring even one tick lets it keep talking.
    avatar?.resetState()   // barge: full reset stops generation instantly + clean next utterance
    embodySpeaking = false
    embodyDrainWaitTicks = 0      // a fresh utterance starts the drain watchdog clean
    #endif
    #if os(macOS) || os(iOS)
    // Invalidate the speaker-clock stamp: the gated utterance it belonged to
    // was just cancelled, and a fast re-response must not pace against it.
    speechFrameLock.lock()
    _utteranceAudioStartAt = 0
    speechFrameLock.unlock()
    #endif
  }

  /// Brain turn-end (cloud OpenAI response.done / local BC_EVENT_BOT_TURN_END).
  /// Flush the final PARTIAL lipsync chunk so the last word isn't clipped. Driven
  /// SOLELY by the explicit turn-end signal — there is no timer in this path, so
  /// it can never fire mid-stream (the regression the reverted v1 caused). We
  /// first drain any bot audio still in audioQueue into the runtime, so the
  /// silence pad lands AFTER the real tail rather than ahead of un-fed audio;
  /// feed() and flushTail() serialize on Expression2Runtime.procQ, so ordering holds.
  func onTurnEnd() {
    #if os(macOS) || os(iOS)
    audioLock.lock()
    let remaining = audioQueue
    audioQueue.removeAll(keepingCapacity: true)
    turnEndedForReply = true
    audioLock.unlock()
    NSLog("[embody-av] onTurnEnd: feeding %d residual lipsync samples + flushTail", remaining.count)
    if !remaining.isEmpty { avatar?.feed(remaining) }
    avatar?.flushTail()
    #endif
  }

  /// Pause/resume lipsync consumption WITHOUT dropping queued audio, so a bot
  /// turn resumes from the same point. Used by LOCAL-mode semantic barge: an
  /// energy onset pauses (bot goes quiet), a confirmed word-count interruption
  /// clears the queue, and a false alarm resumes from here.
  func setLipsyncPaused(_ paused: Bool) {
    audioLock.lock(); lipsyncPaused = paused; audioLock.unlock()
  }

  /// Bubble battery saver: arm/disarm the idle-time pull hold (see the
  /// idleHoldEnabled declaration for the full mechanism). Re-arming stamps
  /// `idleHoldSince` so the 30 s idle window starts from the bubble entry,
  /// never from a stale earlier idle stretch.
  func setIdleHold(_ on: Bool) {
    audioLock.lock()
    idleHoldEnabled = on
    idleHoldSince = CACurrentMediaTime()
    audioLock.unlock()
  }

  func enqueuePCM(_ data: Data) {
    let n = data.count / MemoryLayout<Int16>.size
    var floats = [Float](repeating: 0, count: n)
    data.withUnsafeBytes { raw in
      let int16s = raw.bindMemory(to: Int16.self)
      for i in 0..<n { floats[i] = Float(int16s[i]) / 32768.0 }
    }
    let now = CACurrentMediaTime()
    audioLock.lock()
    // If we've been idle ≥ idleResetSecs, treat this chunk as the start of a
    // fresh utterance: ask the compose loop to reset the runtime stream before
    // consuming this audio.
    if lastAudioArrivalTime > 0, (now - lastAudioArrivalTime) >= Self.idleResetSecs {
      pendingUtteranceReset = true
    }
    if !audioSinceBarge || lastAudioArrivalTime == 0 || turnEndedForReply
        || (now - lastAudioArrivalTime) >= Self.idleResetSecs {
      replyFirstFramePending = true     // this arrival begins a reply: its first mouth frame is TTFA's end
      replySeq += 1; replyFirstAudioAt = now; turnEndedForReply = false
    }
    audioQueue.append(contentsOf: floats)
    audioArrived += n
    audioSinceBarge = true
    lastAudioArrivalTime = now
    audioLock.unlock()
  }

  // ---- the voice on its own clock: the voice unit's side (LipsyncSink, 2.6.30) ----

  /// Essence 2 plays the voice on its own clock and shows frames against it (VoiceClock.swift).
  /// The pre-2.6.30 voice-gated presenter stays behind a dev lever, for an A/B.
  var voiceClocked: Bool {
    #if ESSENCE2_AVAILABLE
    return capabilities.driveModel == .atomicSlotClock && !DevLevers.e2VoiceGated
    #else
    return false
    #endif
  }

  /// The reply's voice (24 kHz), handed over just before the same chunk's enqueuePCM.
  func enqueueVoice(_ samples24k: [Float]) {
    guard !samples24k.isEmpty else { return }
    let now = CACurrentMediaTime()
    audioLock.lock()
    // enqueuePCM makes the same test for this chunk next: audio after idleResetSecs of none opens a
    // new stream (the engine resets on the next tick). Mark where its voice begins; that tick drops
    // whatever of the previous stream's voice is still in front of it, with its frames.
    if lastAudioArrivalTime > 0, (now - lastAudioArrivalTime) >= Self.idleResetSecs, !voiceQueue.isEmpty {
      voiceStreamCut = voiceQueue.count
    }
    voiceQueue.append(contentsOf: samples24k)
    voiceSeen = true
    audioLock.unlock()
  }

  var voiceQueued24k: Int {
    audioLock.lock(); defer { audioLock.unlock() }
    return voiceQueue.count
  }

  /// The per-frame release path scheduled a frame's voice (renderQueue: the tick that published the
  /// frame made the release). The frame is on the glass now and its audio is heard from [heardAt].
  func noteVoiceScheduled(samples24k: Int, heardAt: CFTimeInterval) {
    guard let m = replyMeter else { return }
    m.voice(count: samples24k, heardAt: heardAt, rate: VoiceClockPolicy.voiceRate)
    m.shown(avMs: (heardAt - CACurrentMediaTime()) * 1000)
  }

  /// The reply's line (`[bhvoice] REPLY ...`). renderQueue.
  private func closeReplyMeter(skipped: Int64) {
    guard let m = replyMeter else { return }
    replyMeter = nil
    m.skipped = skipped
    if m.hasContent { NSLog("%@", m.line()) }
  }

  private func closeReplyMeterAtExit() {
    closeReplyMeter(skipped: engineSkippedFrames - skippedAtReplyStart)
  }

  /// Speech frames the engine's skip-ahead skipped so far (0 without an Essence 2 engine that has it).
  private var engineSkippedFrames: Int64 {
    #if ESSENCE2_AVAILABLE
    return (avatar as? Essence2Engine)?.skippedFrames ?? 0
    #else
    return 0
    #endif
  }

  /// The per-reply meter follows the reply the arriving audio belongs to. renderQueue.
  private func followReply(_ reply: Int, firstAudioAt: CFTimeInterval, barged: Int, mode: String, engine rt: any BithumanEngine) {
    if let m = replyMeter, barged == m.reply { m.bargedIn = true }
    guard reply != meterReply else {
      // While a reply plays, its line so far every 2 s: a session that ends mid-reply keeps its numbers.
      let now = CACurrentMediaTime()
      if let m = replyMeter, m.hasContent, now - replyLineAt >= 2.0 {
        replyLineAt = now
        m.skipped = engineSkippedFrames - skippedAtReplyStart
        NSLog("%@ so-far", m.line())
      }
      return
    }
    closeReplyMeter(rt)
    meterReply = reply
    skippedAtReplyStart = engineSkippedFrames
    let m = VoiceReplyMeter(reply: reply, mode: mode, cushionMs: mode == "clock" ? Int((Self.voiceCushion * 1000).rounded()) : 0)
    m.firstAudioAt = firstAudioAt
    replyMeter = m
  }

  private func closeReplyMeter(_ rt: any BithumanEngine) {
    closeReplyMeter(skipped: engineSkippedFrames - skippedAtReplyStart)
  }


  #if os(iOS)
  /// Push an already-decoded 16 kHz mono Float32 chunk into the SAME
  /// lipsync queue enqueuePCM() feeds. Mirrors enqueuePCM's lock +
  /// idle-reset logic exactly (the WebRTC remote-audio tap delivers
  /// floats directly, so we skip the Int16→Float decode step).
  func enqueueFloatChunk(_ chunk: [Float]) {
    let now = CACurrentMediaTime()
    audioLock.lock()
    if lastAudioArrivalTime > 0, (now - lastAudioArrivalTime) >= Self.idleResetSecs {
      pendingUtteranceReset = true
    }
    audioQueue.append(contentsOf: chunk)
    lastAudioArrivalTime = now
    audioLock.unlock()
  }
  #endif

  func startRendering() {
    // Create the embody runtime synchronously here — we're already inside the
    // MethodChannel handler on the platform thread, so blocking briefly is OK.
    // It paints a placeholder immediately and warms its CoreML graphs on a bg
    // thread; the display + audio ticks then run on renderQueue.
    loadFixtureAndRuntime()
    var ready = false
    #if os(macOS) || os(iOS)
    // An engine that refused its file at create is not started (the load answers MODEL_REJECTED).
    ready = avatar != nil && avatar?.modelRefusal == nil
    #endif
    if ready {
      renderQueue.async { [weak self] in self?.startTimer() }
      // Hold the load() return until the first frame is actually on the texture
      // (or a safety timeout) so the avatar reveals already-painted, never as a
      // black canvas. The "preparing…" overlay keeps animating meanwhile because
      // the UI thread is un-merged from this (blocked) platform thread.
      _ = firstFrameSemaphore.wait(timeout: .now() + 6.0)
    }
  }

  func shutdown() {
    isShutdown = true
    #if os(iOS)
    setPiPFrameTap(nil)   // PiP tee dies with the texture
    if webrtcLipsyncRenderer != nil {
      webrtcLipsyncRenderer?.detach()
      webrtcLipsyncRenderer = nil
    }
    #endif
    // ★DISPOSE IS SAFE AT ANY MOMENT (2.6.23). The engine is used from two places: the
    // ticks on renderQueue (feed, pull, and the idle decoder's next frame) and, for
    // Expression 2, the warm-up thread (CoreML compile + the idle clip's decoder, seconds
    // long). The engine is let go only after both are done with it:
    //   1. on renderQueue, so a tick that is running has returned; both clocks are cancelled
    //      there (startTimer also runs there, so a timer can no longer start after a dispose);
    //   2. then once the warm-up thread has returned (warmGroup), then release.
    // ★`self` is held STRONGLY until the release has run. The block used to capture it weakly;
    // with the texture unregistered and removed from the map nothing else may hold it, and a
    // freed texture skipped releaseNativeResources entirely — the engine's shutdown (Essence 2's
    // be_essence2_destroy, the session meter's last beat) never ran.
    renderQueue.async {
      self.timer?.cancel()
      self.timer = nil
      self.closeReplyMeterAtExit()
      #if os(macOS) || os(iOS)
      self.embodyDisplayTimer?.cancel()
      self.embodyDisplayTimer = nil
      #endif
      self.warmGroup.notify(queue: self.renderQueue) { self.releaseNativeResources() }
    }
  }

  /// Entered while the warm-up thread (setupBufferedDisplayClock) is inside the engine;
  /// shutdown() releases the engine only after it has left.
  private let warmGroup = DispatchGroup()

  private let renderQueue = DispatchQueue(label: "ai.bithuman.avatar.render",
                                          qos: .userInteractive)
  private let audioLock = NSLock()
  private let pixelBufferLock = NSLock()

  // embody audio cadence: the 40 ms audio tick feeds bot PCM into Expression2Runtime
  // (it decodes 1.6 s chunks on its own bg queue); the display ticks at 20 fps.
  //   - On a new utterance (≥ idleResetSecs of silence) the runtime resetState()s.
  private static let samplesPerTick = 640           // 16 kHz, 40 ms/tick
  private static let idleResetSecs: Double = 1.0    // gap → new utterance
  // ★ NO CAP, NO DROP (2026-09-16). This queue was capped (96k samples expression-2,
  // 32k essence-2) and DROPPED ITS OLDEST on overflow — a silent lipsync loss the
  // transport's 1x pacer kept from ever happening. The pacer is gone: the whole
  // reply arrives in a burst and is fed to the engine in the same tick, where the
  // ENGINE is the bound (expression-2 parks its producer at maxQueuedFrames and
  // keeps the audio; essence-2's pcmIn is unbounded and its ring is 8 deep). This
  // queue then holds at most one tick's arrivals, and every sample the transport
  // delivered reaches the engine. Proven on essence-2's old 2 s cap: a 60 s reply's
  // lipsync now covers the whole reply (no drop). `audioFed` is the instrument.
  private var audioQueue: [Float] = []              // pending pushAudio samples
  private var lastAudioArrivalTime: CFTimeInterval = 0
  #if os(macOS) || os(iOS)
  // A/V surface shared with RealtimeAudioIO (cross-thread, guarded by
  // speechFrameLock):
  //   - speechFramesPublished: SPEECH lip-frames published to the texture.
  //   - onSpeechFramePublished: fired each time a SPEECH lip-frame is published,
  //     so RealtimeAudioIO releases exactly one frame of bot audio (50 ms) in
  //     lock-step — A/V paired by construction.
  //   - noteUtteranceAudioStarted(): stamped by the audio engine when speaker
  //     playback starts (used to invalidate the stamp on barge).
  private let speechFrameLock = NSLock()
  private var _speechFramesPublished = 0
  private var _utteranceAudioStartAt: CFTimeInterval = 0
  var speechFramesPublished: Int {
    speechFrameLock.lock(); defer { speechFrameLock.unlock() }
    return _speechFramesPublished
  }
  /// BOTH embody AND essence2 now use FRAME-PACED audio (audio-paced-by-video):
  /// the speaker is driven BY the published video frames via
  /// onSpeechFramePublished → releaseEmbodyAudioFrame (40 ms per GENERATED
  /// frame), so audio advances only per real mouth frame — index-locked to the
  /// pixels (server-mux model), no drift/deadband/onset-bias. The old essence2
  /// hold-then-flush start gate (host-clock speaker chase) is RETIRED: with the
  /// gate OFF, playSpeakerPCM24k routes the bot PCM into embodyPaced + installs
  /// the per-frame release. Always false now.
  var usesStartGate: Bool { false }
  /// Hook the audio engine installs (embody): fired on the render tick each time
  /// a SPEECH lip-frame is published, so exactly one frame of bot audio (50 ms)
  /// is released to the speaker in lock-step — A/V paired by construction.
  var onSpeechFramePublished: (() -> Void)? = nil
  /// Asked BEFORE publishing a speech frame: is this frame's 50 ms of audio ready?
  /// nil (no audio sink attached) means "do not gate" — the local/no-speaker paths.
  var canReleaseSpeechAudio: (() -> Bool)? = nil
  /// Gate-skip readiness (play ungated while the engine is still warming).
  var startGateEngineReady: Bool {
    #if os(macOS) || os(iOS)
    return avatar?.isReady ?? false
    #else
    return false
    #endif
  }
  func noteUtteranceAudioStarted() {
    speechFrameLock.lock()
    _utteranceAudioStartAt = CACurrentMediaTime()
    speechFrameLock.unlock()
  }
  #endif
  private var pendingUtteranceReset = false
  /// When true, the compose loop HOLDS the lipsync queue (renders idle instead
  /// of draining) so a paused bot turn resumes exactly where it left off — no
  /// audio is dropped. Guarded by audioLock; toggled by setLipsyncPaused(_:).
  private var lipsyncPaused = false
  // Bubble idle-hold (battery): kept as no-op state for API parity (embody's
  // idle is a zero-inference pre-rendered loop, so there is nothing to pause).
  private var idleHoldEnabled = false
  private var idleHoldSince: CFTimeInterval = 0
  private var latestPixelBuffer: CVPixelBuffer?
  private var timer: DispatchSourceTimer?
  private var isShutdown = false

  // First-frame gate. startRendering() (called inside the `load` MethodChannel
  // handler) blocks on this until the compose loop publishes the FIRST frame,
  // so Dart's `load()` — and therefore the "preparing…" overlay — doesn't end
  // while the Texture is still black (no frame yet). Without it there's a
  // ~1 s window after runtime-ready where the overlay has crossfaded out but
  // no frame has landed → a black-canvas flash. The platform thread is
  // un-merged from the UI thread (FLTEnableMergedPlatformUIThread=NO), so this
  // wait keeps the loading animation smooth instead of freezing it. Bounded by
  // a timeout so a stalled compose can never hang the load.
  private let firstFrameSemaphore = DispatchSemaphore(value: 0)
  private var firstFrameSignaled = false // renderQueue-only

  private var publishedFrameCount = 0               // texture-publish counter
  /// Verbose dev instrumentation gate (frame-counter logs). Off by default;
  /// enable with environment variable BH_AVATAR_DEBUG=1.
  private static let avatarDebugLogging = DevLevers.avatarDebug

  private var bgrBuffer = [UInt8](repeating: 0, count: 1920 * 1080 * 3)
  private var frameW: Int = 0
  private var frameH: Int = 0
  var nativeFrameSize: (Int, Int) { (frameW, frameH) }
  /// Fires when the embody runtime sizes its texture (once, at load). The
  /// plugin forwards it to Dart ("frameDimsChanged") so the canvas lays out
  /// with the stream. Called on renderQueue; the plugin hops to main itself.
  var onFrameDimsChanged: ((Int, Int) -> Void)?
  /// The engine refused its model after load returned (Expression 2's warm-up): MODEL_REJECTED.
  var onModelRejected: ((BithumanModelRefusal) -> Void)?
  /// The engine's refusal of its model file, known at create (Essence 2) — see ModelRefusal.swift.
  var modelRefusal: BithumanModelRefusal? {
    #if os(macOS) || os(iOS)
    return avatar?.modelRefusal
    #else
    return nil
    #endif
  }
  #if os(iOS)
  /// System-PiP tee: when set (AvatarPiP active), every published pixel
  /// buffer is also handed here (on renderQueue) for the sample-buffer
  /// layer. Guarded by pixelBufferLock (set from main, read per publish).
  private var pipFrameTap: ((CVPixelBuffer) -> Void)?
  func setPiPFrameTap(_ tap: ((CVPixelBuffer) -> Void)?) {
    pixelBufferLock.lock(); pipFrameTap = tap; pixelBufferLock.unlock()
  }
  /// Latest published buffer — primes the PiP layer before the next tick.
  func currentPixelBufferForPiP() -> CVPixelBuffer? {
    pixelBufferLock.lock(); defer { pixelBufferLock.unlock() }
    return latestPixelBuffer
  }
  #endif
  #if os(macOS) || os(iOS)
  // The active avatar engine, held engine-agnostically. CREATED by
  // EngineRegistry.make(slug, ref) in loadFixtureAndRuntime (no loadEmbody/
  // loadEssence2 hard-coding), then driven purely through the protocol +
  // capabilities.driveModel: .bufferedDisplayClock (expression2 / pure-Swift+CoreML,
  // warms its 4 CoreML graphs on a bg thread) → setupBufferedDisplayClock; or
  // .atomicSlotClock (essence2 / on-device Essence2) → setupAtomicSlotClock. The
  // shared drive loop below touches only the
  // BithumanEngine protocol surface, so both engines run identically.
  private var avatar: (any BithumanEngine)? = nil
  private var embodyDisplayTimer: DispatchSourceTimer? = nil  // even 20 fps display clock
  private var embodySpeaking = false         // true = playing live model frames; false = idle loop
  private var embodyIdleCount = 0            // idle-loop frames published (for logging)
  private var embodyFrameCount: Int = 0
  private var embodyFpsT0: Double = 0
  private var embodyLastPublish: Double = 0  // for stutter detection
  // End-of-turn tail-hold watchdog: counts display ticks spent holding speech
  // while a final partial chunk's flush is pending/in-flight. 50 ms/tick; 60
  // ticks = 3 s — far longer than the cloud turn-end defer + a flushTail
  // processChunk — so it only trips if the turn-end signal was lost, and
  // GUARANTEES the avatar can never freeze in speech.
  private var embodyDrainWaitTicks = 0
  /// Speech-tagged frames published WITHOUT an audio slice because there was none to
  /// pair with: the engine's padded last chunk. Counted apart from skips on purpose.
  private var embodyPadFrames = 0
  /// ★SYNC MARKER (adopted from the visual-proof lane's presenter). DEV: EMBODY_MARKER_EVERY=<s>
  /// — every that many seconds of PUBLISHED speech, one speech frame is painted full white and
  /// its own 50 ms audio slice carries a 12 ms 2 kHz click. Both go through the ORDINARY paths:
  /// the flash is the normal frame publish, the click is mixed into the slice the normal release
  /// takes for that frame. Filmed from outside, the flash-to-click gap IS the A/V offset at the
  /// ear; a marker that took a shortcut would measure the shortcut. 0 = off.
  private static let markerEverySpeechFrames: Int = {
    let s = DevLevers.markerEverySeconds
    return s > 0 ? max(1, Int(s * 20)) : 0
  }()
  private var embodyMarkers = 0
  /// Set on the frame that flashes; read (and cleared) by the audio side when it releases
  /// that frame's slice, so the click lands in the same unit.
  var markerOnNextRelease = false
  private static let maxDrainWaitTicks = 60
  // --- essence2 (Essence2) drive constants — verbatim from the proven canonical
  // composeTickElevate. Only composeTickEssence2 reads these; embody is untouched.
  // (idleResetSecs already exists above.)
  private static let maxComposesPerTick: Int = 5    // catch-up frame budget/tick
  // Max video lag behind the speaker clock before catch-up dropping: 3 frames = 120 ms.
  private static let elevateMaxLagFrames: Int = 3
  // Clockless-feed fallback: cap raw queue depth above the dispatch-burst
  // oscillation (~5-6) but far below the old 20 (which parked a permanent lag).
  private static let elevateMaxBacklog: Int = 8
  // renderQueue-only utterance pacing (mirrors canonical): >= idleResetSecs
  // without a speech-frame pull = new utterance; audioStartSnapshot is the
  // speaker-clock anchor the pull loop paces against.
  private var lastSpeechPullAt: CFTimeInterval = 0
  private var utteranceFirstPullAt: CFTimeInterval = 0
  private var utterancePulled = 0          // content cursor (incl. dropped)
  private var utteranceDropped = 0
  private var audioStartSnapshot: CFTimeInterval = 0  // 0 = no speaker clock yet
  private var elevateReadyLogged = false
  #endif

  /// Display mode ("head"/"full"). Embody has no native head mode, so this is
  /// always false and Dart keeps its center-crop bubble fallback.
  func setDisplayMode(head: Bool) -> Bool { false }

  /// Engine readiness for the `isReady` MethodChannel poll. Embody's create
  /// returns fast while its CoreML graphs warm on a background thread; isReady
  /// flips true once the speech path is live.
  func isEngineReady() -> Bool {
    #if os(macOS) || os(iOS)
    return avatar?.isReady ?? false   // true once warmUp finishes
    #else
    return false
    #endif
  }
  private var pixelBufferPool: CVPixelBufferPool? = nil


  #if os(macOS) || os(iOS)
  /// embody (pure-Swift/CoreML): create the runtime, size the texture to 416x720,
  /// paint a placeholder so load() returns with a painted canvas, and warm the 4
  /// CoreML graphs on a bg thread (first ANE compile ~5-10 s). composeTickEmbody
  /// goes live once isReady; idle frame painted when warm completes.
  /// Load a short 16 kHz mono speech clip used to SPEECH-WARM the embody ctx at
  /// warm-up (so the per-utterance reset seed is the sharp speaking state, not the
  /// soft silence-rest state). Dev: EMBODY_WARM_WAV; prod: bundled embody/warm.wav.
  /// Looped to ~20 s so the ctx fully converges. Nil → warm-up uses silence (old).
  private func loadWarmSpeech() -> [Float]? {
    var url: URL?
    if let p = DevLevers.warmWav {
      url = URL(fileURLWithPath: p)
    } else if let eng = Expression2Engine.engineDir,
              FileManager.default.fileExists(atPath: "\(eng)/warm.wav") {
      url = URL(fileURLWithPath: "\(eng)/warm.wav")   // from the extracted embody.model
    } else {
      url = Bundle(for: Expression2Engine.self).url(forResource: "warm", withExtension: "wav", subdirectory: "embody")
          ?? Bundle.main.url(forResource: "warm", withExtension: "wav", subdirectory: "embody")
    }
    guard let u = url, let file = try? AVAudioFile(forReading: u),
          let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                     frameCapacity: AVAudioFrameCount(file.length)),
          (try? file.read(into: pcm)) != nil, let ch = pcm.floatChannelData,
          pcm.frameLength > 0 else { return nil }
    let clip = Array(UnsafeBufferPointer(start: ch[0], count: Int(pcm.frameLength)))
    let target = 16000 * 20   // ~20 s ≈ 12 chunks → full convergence
    var out = [Float](); out.reserveCapacity(target)
    while out.count < target { out.append(contentsOf: clip) }
    return Array(out.prefix(target))
  }

  /// Extract the bundled SHARED engine `embody.model` (zip: w2v + taehv + warm.wav)
  /// once into Application Support/.../engine/, and point `Expression2Runtime.engineDir`
  /// at it so the shared graphs load from the versioned `.model`. Idempotent
  /// (skips if already extracted). No-op (leaves engineDir nil → the loose
  /// app-bundle copies are used) when no `.model` is bundled or extraction fails —
  /// so this can never break loading.
  /// macOS-only: it extracts the `embody.model` bundled inside the macOS app; on iOS
  /// the engine members come from the downloaded agent dir, so there is nothing to
  /// extract. (The old reason here — "the embody runtime is macOS" — stopped being
  /// true when expression-2 shipped on iPhone.)
  private func ensureEngineExtracted() {
    // macOS-only: see the note above — the bundled embody.model exists only in the
    // macOS app; on iOS the engine members come from the downloaded agent dir.
    #if os(macOS)
    let fm = FileManager.default
    guard let model = Bundle(for: Expression2Engine.self).url(forResource: "embody", withExtension: "model", subdirectory: "embody")
        ?? Bundle.main.url(forResource: "embody", withExtension: "model", subdirectory: "embody") else {
      return
    }
    let base = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first
             ?? NSTemporaryDirectory()
    let engineDir = "\(base)/ai.bithuman.app/engine"
    let marker = "\(engineDir)/w2v_frontend_cpuAndNE.mlpackage"
    if fm.fileExists(atPath: marker) { Expression2Engine.engineDir = engineDir; return }
    let stage = engineDir + ".tmp"
    try? fm.removeItem(atPath: stage)
    do {
      try fm.createDirectory(atPath: stage, withIntermediateDirectories: true)
      let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
      p.arguments = ["-qq", model.path, "-d", stage]
      try p.run(); p.waitUntilExit()
      guard p.terminationStatus == 0, fm.fileExists(atPath: "\(stage)/w2v_frontend_cpuAndNE.mlpackage") else {
        NSLog("[embody] engine extract failed (rc=%d) — using loose bundle", p.terminationStatus)
        try? fm.removeItem(atPath: stage); return
      }
      try? fm.removeItem(atPath: engineDir)
      try fm.moveItem(atPath: stage, toPath: engineDir)
      Expression2Engine.engineDir = engineDir
      NSLog("[embody] engine ready from embody.model → %@", engineDir)
    } catch {
      NSLog("[embody] engine extract error: %@ — using loose bundle", "\(error)")
      try? fm.removeItem(atPath: stage)
    }
    #endif
  }

  /// Set up the `.bufferedDisplayClock` drive (expression2 / embody). The engine
  /// is ALREADY created by EngineRegistry.make (loadFixtureAndRuntime); this is
  /// VERBATIM the old loadEmbody body MINUS the concrete `Expression2Runtime()`
  /// creation — selected by capabilities.driveModel, not the engineKind string.
  /// `rt` is `any BithumanEngine`; warmUp/idle/benchSync are all protocol members
  /// (benchSync is a defaulted no-op the expression2 adapter implements).
  private func setupBufferedDisplayClock() {
    ensureEngineExtracted()
    guard let rt = avatar else { return }
    frameW = rt.width; frameH = rt.height
    let cap = frameW * frameH * 3
    if bgrBuffer.count < cap { bgrBuffer = [UInt8](repeating: 0, count: cap) }
    createPixelBufferPool(width: frameW, height: frameH)
    for i in 0..<cap { bgrBuffer[i] = 24 }            // dark placeholder (no black flash)
    publishBGRToTexture()
    onFrameDimsChanged?(frameW, frameH)
    // Even-rate 20 fps display clock, decoupled from the 40 ms audio tick. This
    // is the SINGLE publisher of frames — a steady 50 ms cadence eliminates the
    // 40 ms-grid judder, and it paints the neutral idle pose between utterances
    // (so the avatar settles instead of freezing on a mid-word frame).
    let disp = DispatchSource.makeTimerSource(flags: .strict, queue: renderQueue)
    disp.schedule(deadline: .now() + 0.05, repeating: 0.05, leeway: .milliseconds(3))
    disp.setEventHandler { [weak self] in self?.embodyDisplayTick() }
    disp.resume()
    embodyDisplayTimer = disp
    NSLog("[embody] load %dx%d — warming 4 CoreML graphs in background", frameW, frameH)
    let warmSpeech = loadWarmSpeech()
    warmGroup.enter()
    DispatchQueue.global(qos: .userInitiated).async { [weak self, warmGroup] in
      rt.warmUp(warmSpeech: warmSpeech)
      let idleFrame = rt.idle
      let refusal = rt.modelRefusal   // read before the engine may be released (below)
      // Out of the engine: a dispose that came during the warm-up releases it now (shutdown()).
      // Nothing below touches the engine except the dev levers.
      warmGroup.leave()
      guard let self = self, !self.isShutdown else { return }   // disposed while warming
      if let r = refusal {
        // MODEL_REJECTED (2.6.29): the files would not load. Dart ends the session on it.
        NSLog("[embody] MODEL_REJECTED — %@", r.message)
        self.onModelRejected?(r)
      }
      guard let idle = idleFrame else {
        NSLog("[embody] warmUp produced no idle frame"); return
      }
      self.renderQueue.async {
        let n = min(idle.count, self.bgrBuffer.count)
        idle.withUnsafeBufferPointer { s in
          self.bgrBuffer.withUnsafeMutableBufferPointer { d in d.baseAddress!.update(from: s.baseAddress!, count: n) }
        }
        self.publishBGRToTexture()
        NSLog("[embody] idle painted — engine live")
        // DEV headless verification: dump the in-app idle frame (BGR) so a
        // remote/CI run can confirm the avatar actually renders without a screen.
        // Only when EMBODY_DUMP_DIR names a directory (debug builds) — a release
        // build writes no probe file.
        if let dumpDir = DevLevers.dumpDir {
          let url = URL(fileURLWithPath: dumpDir).appendingPathComponent("embody_app_idle.bgr")
          try? Data(self.bgrBuffer.prefix(self.frameW * self.frameH * 3)).write(to: url)
          NSLog("[embody] dumped in-app idle frame -> %@", url.path)
        }
      }
      // DEV: with EMBODY_TEST_AUDIO=1, feed continuous real-time synthetic audio
      // so frames flow WITHOUT a live conversation — to measure display
      // smoothness headlessly. 640 samples / 40 ms = 16 kHz real-time.
      if DevLevers.testAudio {
        NSLog("[embody] TEST_AUDIO on — feeding synthetic 16k speech")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
          var ph: Float = 0
          while let self = self, self.avatar != nil {
            var chunk = [Float](repeating: 0, count: 768)   // 1.2x realtime so the paced feed gets its full 640/tick
            // crude voiced buzz (~140 Hz) so w2v sees energy and the mouth moves
            for i in 0..<768 { chunk[i] = 0.25 * sin(ph); ph += 0.055 }
            self.audioLock.lock(); self.audioQueue.append(contentsOf: chunk); self.audioLock.unlock()
            usleep(40000)
          }
        }
      }
      // DEV: EMBODY_TEST_WAV=<path to a 16k mono wav> → feed REAL speech through
      // the same audioQueue path the live TTS uses, so a headless run reproduces
      // real-speech rendering (the synthetic buzz above can't — a steady tone
      // hides identity-specific onset/decode issues). Off unless the var is set.
      if let wav = DevLevers.testWav {
        // A phone has no shared filesystem with the host, so a drive has to be copied
        // into the app's own container and named relative to it (DevLevers.path
        // resolves a relative name against the app home).
        NSLog("[embody] TEST_WAV on — feeding %@", wav)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
          guard let self = self,
                let file = try? AVAudioFile(forReading: URL(fileURLWithPath: wav)),
                let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                          frameCapacity: AVAudioFrameCount(file.length)),
                (try? file.read(into: pcm)) != nil,
                let ch = pcm.floatChannelData else {
            NSLog("[embody] TEST_WAV read failed"); return
          }
          let samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(pcm.frameLength)))
          NSLog("[embody] TEST_WAV %d samples @ %.0f Hz", samples.count, file.processingFormat.sampleRate)
          var i = 0
          while i < samples.count, self.avatar != nil {
            let end = min(i + 768, samples.count)
            let chunk = Array(samples[i..<end])
            self.audioLock.lock(); self.audioQueue.append(contentsOf: chunk); self.audioLock.unlock()
            i = end
            usleep(40000)
          }
          NSLog("[embody] TEST_WAV done")
        }
      }
      // DEV: EMBODY_BENCH=1 → measure peak on-device GENERATION throughput
      // (back-to-back, unpaced) once, after warm-up.
      if DevLevers.bench {
        DispatchQueue.global(qos: .userInitiated).async { rt.benchSync(20) }
      }
    }
  }

  #if ESSENCE2_AVAILABLE
  /// Set up the `.atomicSlotClock` drive (essence2 / on-device Essence2). The
  /// adapter is ALREADY created by EngineRegistry.make (which set its
  /// activeAgentDir/motionDir from the avatar ref, and which self-warms on its own
  /// thread); this sizes the texture to the engine's landscape geometry
  /// (1248×704), paints Essence2's synchronously-ready target frame 0, and runs NO
  /// second display timer — the single composeTick drives feed+pull ATOMICALLY via
  /// composeTickEssence2. VERBATIM the old loadEssence2 body MINUS the concrete
  /// `Essence2Runtime()` creation — selected by capabilities.driveModel.
  private func setupAtomicSlotClock() {
    guard let rt = avatar else { return }
    frameW = rt.width; frameH = rt.height            // 1248x704 landscape
    let cap = frameW * frameH * 3
    if bgrBuffer.count < cap { bgrBuffer = [UInt8](repeating: 0, count: cap) }
    createPixelBufferPool(width: frameW, height: frameH)
    for i in 0..<cap { bgrBuffer[i] = 24 }           // dark placeholder (no black flash)
    publishBGRToTexture()
    onFrameDimsChanged?(frameW, frameH)
    // Essence2's target frame 0 (idle) is ready synchronously (bundle parse) —
    // paint it immediately so the canvas reveals the identity, not a gray box.
    // Painted BEFORE the render tick runs so the renderQueue tick is the SOLE
    // caller of the adapter's idle/pull scratch thereafter (no data race).
    if let idle = rt.idle {
      let n = min(idle.count, bgrBuffer.count)
      idle.withUnsafeBufferPointer { s in bgrBuffer.withUnsafeMutableBufferPointer { d in
        d.baseAddress!.update(from: s.baseAddress!, count: n) } }
      publishBGRToTexture()
    }
    // NO second display timer for essence2: the single composeTick timer
    // (started by startRendering → startTimer) drives feed+pull ATOMICALLY via
    // composeTickEssence2, mirroring the proven canonical drive. (A second
    // free-running pull timer is what de-synced feed from pull.)
    NSLog("[essence2] load %dx%d — Essence2 warming on its own thread", frameW, frameH)
  }
  #endif

  /// 40 ms audio tick for embody: feed real-time-paced audio into the runtime
  /// (it decodes 1.6 s chunks on its own bg queue). Display is driven SEPARATELY
  /// by embodyDisplayTick at an even 20 fps, so audio cadence never jitters video.
  private func composeTickEmbody() {
    guard let rt = avatar, rt.isReady else { return }
    let q = rt.queuedFrames
    audioLock.lock()
    let paused = lipsyncPaused
    let needsReset = paused ? false : pendingUtteranceReset
    if !paused { pendingUtteranceReset = false }
    // Feed-ahead: when the frame queue is low, drain up to a whole chunk of
    // already-arrived bot audio per tick so the model races ahead on the
    // faster-than-realtime OpenAI stream and builds a cushion. This bridges the
    // ci=0 startup deficit (~21 frames for a 1.6 s chunk) that otherwise drains
    // ~1 s into speech before ci=1 is ready — the brief freeze. Healthy queue →
    // realtime feed so the frame-queue cap never overflows. Display + audio still
    // pace at 20 fps, so output stays realtime + A/V-paired; only buffer depth grows.
    // embody-only feed-ahead burst: this loop (composeTickEmbody) runs ONLY for
    // the .bufferedDisplayClock drive, so the old `engineKind != "essence2"` guard
    // is always true here and is dropped. essence2's continuous slot clock (the
    // separate composeTickEssence2 loop) feeds realtime (samplesPerTick) instead.
    // ★ EVERYTHING THAT ARRIVED GOES TO THE ENGINE NOW. feed() never blocks (it
    // appends; a chunk renders on procQ) and the producer parks at maxQueuedFrames,
    // so this cannot outrun the engine — the engine is the bound.
    let take = paused ? 0 : audioQueue.count
    let samples = take > 0 ? audioQueue : []
    if take > 0 { audioQueue.removeAll(keepingCapacity: true); audioFed += take }
    let fedTotal = audioFed
    audioLock.unlock()
    if take > 0 {
      NSLog("[bhfeed] +%d fed=%d q=%d hostMs=%lld", take, fedTotal, q, Int64(Date().timeIntervalSince1970 * 1000))
    }
    // New utterance → full reset of the engine stream (buf/ci/prev/ctx) so the new
    // response starts CLEAN at ci=0: lip-frames map 1:1 to the new audio (correct A/V,
    // no prior-tail content, no accumulating lag). The continuous-stream variant
    // (keep buf, realign ci) could not realign cleanly to a new response mid-stream
    // (it desynced video from audio); the per-utterance reset is the stable behavior.
    // Trade-off: a brief cold-w2v onset "snowflake" — acceptable vs a desynced reply.
    if needsReset { rt.resetState() }
    // Feed ONLY real bot audio — the model runs during SPEECH only. With no audio
    // the model goes quiet and embodyDisplayTick plays the pre-rendered idle LOOP
    // (zero inference) instead of generating idle motion from injected silence.
    if !samples.isEmpty { rt.feed(samples) }
  }

  #if ESSENCE2_AVAILABLE
  /// One render tick for essence2 (on-device Essence2) — a verbatim port of the
  /// PROVEN canonical composeTickElevate. M3: driven through `any BithumanEngine`
  /// (the widened protocol surface — isReady/idle(into:)/resetState/pushAudio/
  /// framesAvailable/pull(into:)) instead of an `avatar as? Essence2Runtime`
  /// downcast onto concrete passthroughs; the underlying be_essence2_* calls (and
  /// thus the a2x render output) are BYTE-IDENTICAL. Reset → push → pull happen
  /// ATOMICALLY in this single tick (no second free-running display timer), and
  /// pulls pace against the SPEAKER clock so the photoreal video locks to audio.
  /// embody is untouched (composeTickEmbody + embodyDisplayTick own that path).
  private func composeTickEssence2() {
    guard let rt = avatar else { return }
    // Engine still warming: the speech path is down, so any queued lipsync audio
    // would be STALE by ready time — drop it — and keep the bundle idle frame
    // cycling as the live placeholder regardless of audio arrivals.
    if !rt.isReady {
      audioLock.lock(); audioQueue.removeAll(keepingCapacity: true); pendingUtteranceReset = false; audioLock.unlock()
      let cap = frameW * frameH * 3; guard cap > 0 else { return }
      if bgrBuffer.count < cap { bgrBuffer = [UInt8](repeating: 0, count: cap) }
      if rt.idle(into: &bgrBuffer) > 0 { publishBGRToTexture() }
      return
    }
    if !elevateReadyLogged {
      elevateReadyLogged = true
      // The start-gate's hold-skip reads startGateEngineReady (→ avatar?.isReady
      // → be_essence2_is_ready), so no separate ready flag is needed here.
      NSLog("[essence2-av] engine ready — speech path live")
      logSkipAhead(rt)
    }
    if voiceClocked { composeTickEssence2Voice(rt); return }
    // The pre-2.6.30 presenter (a dev lever, for an A/B): the same per-reply voice meter.
    audioLock.lock(); let gReply = replySeq, gFirst = replyFirstAudioAt, gEnded = turnEndedForReply, gBarged = bargedReply
    let gQuiet = audioQueue.isEmpty; audioLock.unlock()
    followReply(gReply, firstAudioAt: gFirst, barged: gBarged, mode: "gated", engine: rt)
    if gEnded, gQuiet, lastSpeechPullAt > 0, CACurrentMediaTime() - lastSpeechPullAt > 1.0 { closeReplyMeter(rt) }

    audioLock.lock()
    let paused = lipsyncPaused
    let needsReset = paused ? false : pendingUtteranceReset
    if !paused { pendingUtteranceReset = false }
    // Everything that arrived goes to the engine now (le_utt_push_audio appends to an
    // unbounded pcmIn; its worker parks on the 8-deep ring). See composeTickEmbody.
    let epochAtTop = bargeEpoch
    let take = paused ? 0 : audioQueue.count   // hold queue while paused
    let pending = take > 0 ? audioQueue : []
    if take > 0 { audioQueue.removeAll(keepingCapacity: true); audioFed += take }
    let fedTotal = audioFed
    let lastAudio = lastAudioArrivalTime
    audioLock.unlock()
    if take > 0 {
      NSLog("[bhfeed] +%d fed=%d q=%d hostMs=%lld", take, fedTotal, rt.framesAvailable, Int64(Date().timeIntervalSince1970 * 1000))
    }

    if needsReset { rt.resetState() }            // → be_essence2_reset (essence2 witness)
    if !pending.isEmpty { rt.pushAudio(pending) }   // → pushI16 (exact ×32768 int16 conv, byte-frozen)

    let cap = frameW * frameH * 3
    if cap > 0, bgrBuffer.count < cap { bgrBuffer = [UInt8](repeating: 0, count: cap) }

    // AUDIO-PACED-BY-VIDEO (server-mux / embody model — replaces the old
    // host-clock speaker chase). Pull AT MOST ONE frame per tick and publish it
    // UNCONDITIONALLY (never drop). The SPEAKER is driven BY the published video:
    // usesStartGate=false routes the bot PCM into embodyPaced and installs
    // onSpeechFramePublished = releaseEmbodyAudioFrame (RealtimeAudioIO
    // playSpeakerPCM24k). Each GENERATED (real lip-motion) frame released here
    // emits exactly its 40 ms (audioReleaseSeconds=0.04) of audio, so audio
    // advances ONLY per published mouth frame — index-locked to the pixels, D=0,
    // cannot drift, no [1,3]-frame deadband, no onset-stamp bias. Idle/warmup
    // passthrough frames (pulledSpeechFrames delta==0) advance NO audio, so the
    // speaker holds until the first real mouth frame (onset bound automatically;
    // le_a2x lookahead is pure TTFB, NOT an offset → no DA_AV_AUDIO_DELAY). The
    // speaker can never lead the displayed frames → there is never a reason to
    // drop, so every generated frame shows (full motion).
    let backlog = rt.framesAvailable
    if backlog > 0 {
      // pull(into:) returns `speech` = the be_essence2_pulled_speech_frames DELTA:
      // true for a GENERATED (real lip-motion) frame, false for an onset-warmup /
      // idle passthrough — collapsing the former pulledSpeechFrames() before/after
      // pair into one call (byte-identical: same be_essence2_pull_frame).
      let (got, isSpeech) = rt.pull(into: &bgrBuffer)
      if got > 0 {
        // ★ THE FENCE: a cut moved the epoch between the read at the top and this
        // pull, OR no reply audio has arrived since the cut → the frame is the
        // cancelled reply's. Not shown, not paired. (Android's guard, Apple side.)
        audioLock.lock(); let epochNow = bargeEpoch; let stale = !audioSinceBarge; audioLock.unlock()
        if epochNow != epochAtTop {
          bargeFenced += 1
          NSLog("[bhbarge] FENCED a frame pulled across the cut (epoch %d -> %d) fenced=%d", epochAtTop, epochNow, bargeFenced)
          return
        }
        if isSpeech && stale {
          bargeLeaks += 1
          NSLog("[bhbarge] LEAK old-reply speech frame after the cut (+%.0f ms) leaks=%d",
                (CACurrentMediaTime() - bargeAt) * 1000, bargeLeaks)
          return
        }
        publishBGRToTexture()                       // every frame shown — never dropped
        if isSpeech {                               // a GENERATED frame → release its paired 40 ms + mark speech
          lastSpeechPullAt = CACurrentMediaTime()
          speechFrameLock.lock(); _speechFramesPublished += 1; speechFrameLock.unlock()
          onSpeechFramePublished?()                  // releaseEmbodyAudioFrame: emit THIS frame's audio slice
          noteSpeechFramePresented(CACurrentMediaTime())
        } else {
          noteIdleFramePresented()
        }
        noteFifo(CACurrentMediaTime(), queuedFrames: backlog, hadFrame: true)
      }
      return
    }
    if !pending.isEmpty || lastSpeechPullAt > 0 && CACurrentMediaTime() - lastSpeechPullAt < 1.0 {
      noteFifo(CACurrentMediaTime(), queuedFrames: 0, hadFrame: false)
    }

    // Idle: no speech frames ready and we've been quiet a moment → keep the
    // driver video cycling so the avatar never freezes. Suppressed while audio
    // is actively arriving so it doesn't flicker against speech frames.
    let quietFor = lastAudio > 0 ? (CACurrentMediaTime() - lastAudio)
                                 : Double.greatestFiniteMagnitude
    if pending.isEmpty, quietFor > 0.2, cap > 0 {
      if rt.idle(into: &bgrBuffer) > 0 { publishBGRToTexture(); noteIdleFramePresented() }   // → be_essence2_idle_frame
    }
  }

  private var e2Engine: Essence2Engine? { avatar as? Essence2Engine }

  /// Skip-ahead for this session: the dev lever (BH_E2_CLOCK 1 on / 2 off), then the app's load option,
  /// then the default — and only with an engine that has the calls (essence2-apple v1.15.3+).
  private var skipAheadOn: Bool {
    guard Essence2Engine.supportsSkipAhead else { return false }
    switch DevLevers.e2Clock {
    case 1: return true
    case 2: return false
    default: return skipAhead ?? Self.skipAheadDefault
    }
  }

  private func logSkipAhead(_ rt: any BithumanEngine) {
    let src = DevLevers.e2Clock == 1 || DevLevers.e2Clock == 2 ? "BH_E2_CLOCK=\(DevLevers.e2Clock)"
      : skipAhead != nil ? "load option" : "default"
    NSLog("[essence2] presenter=%@ cushionMs=%.0f skip-ahead=%@ (%@; the engine %@)",
          voiceClocked ? "voice-clock" : "voice-gated", Self.voiceCushion * 1000, skipAheadOn ? "on" : "off", src,
          Essence2Engine.supportsSkipAhead ? "has the calls" : "has no skip-ahead calls")
  }

  /// One render tick of Essence 2 with the voice on its OWN clock (2.6.30; VoiceClock.swift has the
  /// why). The voice is scheduled a short lead ahead of the speaker from a reply's first frame (plus the
  /// cushion) on, whatever the picture does; each tick shows the frame whose audio is being heard,
  /// drops the frames whose audio has gone by while a newer one is ready, and holds one that is early.
  private func composeTickEssence2Voice(_ rt: any BithumanEngine) {
    let now = CACurrentMediaTime()
    audioLock.lock()
    let paused = lipsyncPaused
    let needsReset = paused ? false : pendingUtteranceReset
    if !paused { pendingUtteranceReset = false }
    let epochAtTop = bargeEpoch
    let take = paused ? 0 : audioQueue.count   // hold queue while paused
    let pending = take > 0 ? audioQueue : []
    if take > 0 { audioQueue.removeAll(keepingCapacity: true); audioFed += take }
    var oldVoice = 0
    if needsReset, let cut = voiceStreamCut {
      oldVoice = min(cut, voiceQueue.count); voiceQueue.removeFirst(oldVoice); voiceStreamCut = nil
    }
    let fedTotal = audioFed, lastAudio = lastAudioArrivalTime, hasVoice = voiceSeen
    let reply = replySeq, firstAudioAt = replyFirstAudioAt, turnEnded = turnEndedForReply, barged = bargedReply
    audioLock.unlock()
    if take > 0 {
      NSLog("[bhfeed] +%d fed=%d q=%d hostMs=%lld", take, fedTotal, rt.framesAvailable, Int64(Date().timeIntervalSince1970 * 1000))
    }
    if needsReset {
      rt.resetState()                              // → be_essence2_reset: a new stream, coordinate 0
      voiceClock.reset(); voiceOpen = false; voiceFirstFrameAt = 0; voiceDrySince = 0
      heldFrame = nil; deliveredSpeech = 0
      if oldVoice > 0 {
        NSLog("[bhvoice] NEW-STREAM: %d ms of the previous stream's voice dropped with its frames", oldVoice * 1000 / 24000)
      }
    }
    if !pending.isEmpty { rt.pushAudio(pending) }
    followReply(reply, firstAudioAt: firstAudioAt, barged: barged, mode: "clock", engine: rt)

    let cap = frameW * frameH * 3
    if cap > 0, bgrBuffer.count < cap { bgrBuffer = [UInt8](repeating: 0, count: cap) }
    let e2 = e2Engine
    let skipOn = skipAheadOn

    // 1. The voice: a short lead on the speaker while it is open. It closes once dry at a reply's end
    //    (or after a long dry spell), and the next reply waits for its own first frame + the cushion.
    if voiceOpen {
      if !paused { pumpVoice(now) }
      if voiceQueuedForStream() == 0 && now >= voiceClock.heardEnd {
        if voiceDrySince == 0 { voiceDrySince = now }
        if turnEnded || now - voiceDrySince >= VoiceClockPolicy.closeAfterDrySeconds {
          closeVoice(e2, skipOn)
          if turnEnded { closeReplyMeter(rt) }   // the reply is over and heard: its line now
        }
      } else {
        voiceDrySince = 0
      }
    }
    // 2. Skip-ahead: the engine hears where the voice is (negative before the reply's first sample).
    //    ★Under audioLock, and only if no cut moved the epoch since the top of this tick: a barge-in
    //    bumps the epoch under this lock BEFORE it resets the engine, so a position of the cut reply can
    //    never reach the engine after its reset (it would skip the new reply's frames as already heard;
    //    on the M4 one barge-in in eight, before this guard, held the new reply's face for 1.9 s).
    if skipOn, voiceOpen, let h = voiceClock.heard16(at: now) {
      audioLock.lock()
      if bargeEpoch == epochAtTop { e2?.setPlayoutPosition(h < 0 ? -1 : Int64(h)) }
      audioLock.unlock()
    }

    // 3. The picture.
    var h16 = voiceOpen ? voiceClock.heard16(at: now) : nil
    var shown = false
    var pulls = 0
    frames: while true {
      if heldFrame == nil {
        guard pulls < 12, rt.framesAvailable > 0 else { break frames }
        let (got, isSpeech) = rt.pull(into: &bgrBuffer)
        pulls += 1
        guard got > 0 else { break frames }
        // ★ THE FENCE (as in the voice-gated tick): a frame pulled across a cut is not shown.
        audioLock.lock(); let epochNow = bargeEpoch; let stale = !audioSinceBarge; audioLock.unlock()
        if epochNow != epochAtTop {
          bargeFenced += 1
          NSLog("[bhbarge] FENCED a frame pulled across the cut (epoch %d -> %d) fenced=%d", epochAtTop, epochNow, bargeFenced)
          return
        }
        if isSpeech && stale {
          bargeLeaks += 1
          NSLog("[bhbarge] LEAK old-reply speech frame after the cut (+%.0f ms) leaks=%d",
                (now - bargeAt) * 1000, bargeLeaks)
          continue frames
        }
        var start16: Int64 = -1
        if isSpeech {
          let idx = e2?.lastFrameIndex ?? -1
          if idx >= 0 {
            start16 = idx * VoiceClockPolicy.hop16      // the engine's own ordinal: skipped frames are missing
            deliveredSpeech = idx + 1
          } else {
            // An engine without ordinals: count, re-anchored at a reply's first frame on the voice not
            // yet played (the engine pads a reply's last block, so counting alone runs ahead).
            if !voiceOpen && voiceFirstFrameAt == 0 {
              deliveredSpeech = max(deliveredSpeech, (Int64(voiceClock.scheduled16) + VoiceClockPolicy.hop16 / 2) / VoiceClockPolicy.hop16)
            }
            start16 = deliveredSpeech * VoiceClockPolicy.hop16
            deliveredSpeech += 1
          }
        }
        heldFrame = (got, isSpeech, start16)
      }
      guard let f = heldFrame else { break frames }
      if !f.speech || !hasVoice {
        // An idle / ramp frame, or a stream whose voice is not ours (no voice unit): shown in turn.
        publishBGRToTexture(); heldFrame = nil; shown = true
        if f.speech { noteSpeechShown(now) } else { noteIdleFramePresented() }
        break frames
      }
      if !voiceOpen {
        if voiceFirstFrameAt == 0 {
          voiceFirstFrameAt = now
          if let m = replyMeter, m.firstFrameAt == 0 { m.firstFrameAt = now }
        }
        // The cushion: the engine renders ahead while the reply's first frame (and its voice) waits.
        guard now - voiceFirstFrameAt + 0.001 >= Self.voiceCushion else { break frames }
        voiceOpen = true; voiceDrySince = 0
        pumpVoice(now)
        h16 = voiceClock.heard16(at: now)
      }
      let voiceEnd16 = voiceClock.scheduled16
        + Double(voiceQueuedForStream()) * VoiceClockPolicy.engineRate / VoiceClockPolicy.voiceRate
      let av = h16.map { VoiceClockedPresenter.avMs(heard16: $0, start16: f.start16) } ?? 0
      let v = VoiceClockedPresenter.verdict(avMs: av, newerReady: rt.framesAvailable > 0,
                                             beyondVoice: h16 == nil || Double(f.start16) >= voiceEnd16)
      if DevLevers.e2Trace {
        NSLog("[bhvtrace] start16=%lld heard16=%.0f av=%.0f verdict=%@ q=%d sched16=%.0f end16=%.0f idx=%lld",
              f.start16, h16 ?? -1, av, "\(v)", rt.framesAvailable, voiceClock.scheduled16, voiceEnd16, e2?.lastFrameIndex ?? -2)
      }
      switch v {
      case .dropLate:
        heldFrame = nil
        replyMeter?.dropped += 1
        continue frames
      case .hold:
        break frames
      case .show, .showLate, .showBeyondVoice:
        publishBGRToTexture(); heldFrame = nil; shown = true
        noteSpeechShown(now)
        if v == .showBeyondVoice {
          replyMeter?.beyond += 1
        } else {
          replyMeter?.shown(avMs: av)
          if v == .showLate { replyMeter?.lateShown += 1 }
        }
        break frames
      }
    }
    if shown { noteFifo(now, queuedFrames: rt.framesAvailable, hadFrame: true); return }
    if heldFrame != nil || voiceOpen || !pending.isEmpty || (lastSpeechPullAt > 0 && now - lastSpeechPullAt < 1.0) {
      noteFifo(now, queuedFrames: rt.framesAvailable, hadFrame: false)
    }
    // Idle: nothing to show, nothing held, no voice open, quiet a moment → the engine's idle frame.
    let quietFor = lastAudio > 0 ? (now - lastAudio) : Double.greatestFiniteMagnitude
    if heldFrame == nil, !voiceOpen, pending.isEmpty, quietFor > 0.2, cap > 0 {
      if rt.idle(into: &bgrBuffer) > 0 { publishBGRToTexture(); noteIdleFramePresented() }   // → be_essence2_idle_frame
    }
  }

  /// Keep VoiceClockPolicy.leadSeconds of the voice scheduled on the speaker. renderQueue.
  private func pumpVoice(_ now: CFTimeInterval) {
    guard let schedule = scheduleVoice else { return }
    audioLock.lock()
    let avail = voiceStreamCut ?? voiceQueue.count
    let n = VoiceClockedPresenter.pumpCount(now: now, heardEnd: voiceClock.heardEnd, queued: avail)
    guard n > 0 else { audioLock.unlock(); return }
    // Scheduled UNDER audioLock: a barge-in (clearAudioQueue takes this lock before the voice unit
    // flushes the player) can never fall between taking the slice and scheduling it, so no voice of a
    // cut reply reaches the speaker after the cut.
    guard let at = schedule(Array(voiceQueue.prefix(n))) else { audioLock.unlock(); return }
    voiceQueue.removeFirst(n)
    if let c = voiceStreamCut { voiceStreamCut = c - n }
    audioLock.unlock()
    let dry = voiceClock.add(Int64(n), heardAt: at)
    replyMeter?.voice(count: n, heardAt: at, rate: VoiceClockPolicy.voiceRate)
    if dry >= 0.04 { NSLog("[bhvoice] GAP %.0f ms: the voice ran dry (its audio had not arrived)", dry * 1000) }
  }

  /// The voice of the open stream not yet scheduled (up to a new stream's cut).
  private func voiceQueuedForStream() -> Int {
    audioLock.lock(); defer { audioLock.unlock() }
    return voiceStreamCut ?? voiceQueue.count
  }

  private func closeVoice(_ e2: Essence2Engine?, _ skipOn: Bool) {
    voiceOpen = false; voiceFirstFrameAt = 0; voiceDrySince = 0
    if skipOn { e2?.setPlayoutPosition(-1) }   // the next reply's voice has not started: nothing skips until it has
  }

  private func noteSpeechShown(_ now: CFTimeInterval) {
    lastSpeechPullAt = now
    speechFrameLock.lock(); _speechFramesPublished += 1; speechFrameLock.unlock()
    noteSpeechFramePresented(now)
  }
  #endif

  /// 50 ms display tick = even 20 fps (the avatar's trained rate). SPEECH plays
  /// live model frames; IDLE plays the pre-rendered loop (zero inference). We
  /// enter speech once the model has built an 8-frame (~0.4 s) cushion, and fall
  /// back to the idle loop when it drains with no more audio queued — so the
  /// avatar always moves (no frozen frame), including across barge/utterance gaps.
  private func embodyDisplayTick() {
    guard let rt = avatar else { return }
    // Engine still warming → play the pre-decoded idle CLIP as the backdrop so
    // there's no black canvas during the (multi-second, first-run) CoreML load.
    // publishIdleLoopFrame no-ops until the clip is decoded (first ~1 s).
    if !rt.isReady {
      publishIdleLoopFrame(rt)
      return
    }
    let now = CACurrentMediaTime()
    audioLock.lock(); let epochAtTop = bargeEpoch
    let xReply = replySeq, xFirst = replyFirstAudioAt, xEnded = turnEndedForReply, xBarged = bargedReply
    let xQuiet = audioQueue.isEmpty
    audioLock.unlock()
    // The per-reply voice line (`[bhvoice] REPLY ... mode=x2-gated`, 2.6.31): Expression 2's voice is released
    // per shown frame, so its gaps and A/V offset are measured the same way as Essence 2's.
    followReply(xReply, firstAudioAt: xFirst, barged: xBarged, mode: "x2-gated", engine: rt)
    if xEnded, xQuiet, !embodySpeaking, replyMeter != nil { closeReplyMeter(rt) }
    if !embodySpeaking {
      // Wait for ci=0 + ci=1 (~32+ frames) before starting speech. ci=0 only
      // yields ~21 frames for a 1.6 s chunk, and ci=1 lands ~1.5 s later at
      // realtime stream rate — so starting at ci=0 drains ~1 s in and freezes.
      // The idle loop covers this short wait (no freeze; costs ~1.5 s on the
      // first reply). After ci=1 the queue stays ahead, so it's smooth.
      if rt.queuedFrames >= rt.speechCushion {
        embodySpeaking = true   // cushion ready → live speech
        if holdTicks > 0 { noteHoldRunEnded() }
      } else { publishIdleLoopFrame(rt); return }
    }
    guard let pulled = rt.pull() else {
      holdTicks += 1   // in speech with no frame to show: the display is the speaker's clock, so this is silence
      noteFifo(now, queuedFrames: rt.queuedFrames, hadFrame: false)
      // No lip-frame this tick. Two reasons to HOLD (keep embodySpeaking=true and
      // hold the current frame — audio is paired, so it pauses too, no drift)
      // rather than flip to idle:
      //   • moreAudio: bot audio still queued to feed → utterance not over
      //     (original behavior; no watchdog).
      //   • hasPendingTail: a final PARTIAL chunk is still unprocessed — either we
      //     are inside the cloud turn-end defer window, or flushTail() is mid-flight
      //     on procQ. Its frames are coming; flipping to idle now would strand them
      //     (the clipped last word). Watchdog-bounded so a LOST turn-end signal
      //     (flushTail never called) can't freeze us in speech > ~3 s.
      // NOT gated on embodyPaced draining: ci=0 emits fewer frames (21) than its
      // chunk's audio duration, so the FIFO carries a STRUCTURAL excess that can
      // never be released by frame-publishing — gating on it always hit the
      // watchdog and froze the last frame for 3 s (the bug this replaces).
      // A real barge bypasses all this: clearAudioQueue() resets the runtime (buf
      // empty → hasPendingTail false) + clears the queue, so the next tick idles.
      audioLock.lock(); let moreAudio = !audioQueue.isEmpty; audioLock.unlock()
      if moreAudio { embodyDrainWaitTicks = 0; return }        // still feeding → not over
      if rt.hasPendingTail && embodyDrainWaitTicks < Self.maxDrainWaitTicks {
        embodyDrainWaitTicks += 1
        return                                                 // tail flush in flight → frames coming
      }
      if embodyDrainWaitTicks >= Self.maxDrainWaitTicks {
        NSLog("[embody-av] tail-hold watchdog fired (pendingTail=%@) → idle",
              rt.hasPendingTail ? "y" : "n")
      }
      embodyDrainWaitTicks = 0
      holdTicks = 0              // the reply ended; not a hold
      embodySpeaking = false; publishIdleLoopFrame(rt)
      return
    }
    embodyDrainWaitTicks = 0   // got a frame → disarm watchdog
    if holdTicks > 0 { noteHoldRunEnded() }
    noteFifo(now, queuedFrames: rt.queuedFrames, hadFrame: true)
    // ★ THE FENCE: a cut moved the epoch between the read at the top and this pull,
    // OR no reply audio has arrived since the cut → the frame is the cancelled
    // reply's. Not shown, not paired (Android's guard, Apple side).
    audioLock.lock(); let epochNow = bargeEpoch; let stale = !audioSinceBarge; audioLock.unlock()
    if epochNow != epochAtTop {
      bargeFenced += 1
      NSLog("[bhbarge] FENCED a frame pulled across the cut (epoch %d -> %d) fenced=%d", epochAtTop, epochNow, bargeFenced)
      return
    }
    if pulled.speech && stale {
      bargeLeaks += 1
      NSLog("[bhbarge] LEAK old-reply speech frame after the cut (+%.0f ms) leaks=%d",
            (now - bargeAt) * 1000, bargeLeaks)
      return
    }
    // ★INTERIM — REMOVE WHEN THE PLUGIN CONSUMES AN ENGINE CARRYING #693 (TAIL 0): the
    // engine then trims each utterance to F = round(seconds × fps) and never emits the
    // padded last chunk (the serve path already does), this case cannot occur, and this
    // block is deleted in the SAME change that repoints the plugin at that engine — the
    // two must never coexist. An interim that outlives its cause is a second implementation.
    //
    // A speech frame is rendered FROM its audio slice, and that slice was pushed to the
    // speaker FIFO in the same call that fed the engine — so a speech frame whose slice is
    // not in the FIFO is a frame the engine rendered from audio that was never pushed:
    // the silence it appended to complete its last chunk. Measured (macOS, scripted turns,
    // 2026-09-15): every such moment had no audio queued or pending and none arrived within
    // 500 ms; the sound was absent, not late. Such a frame is published (the mouth settles
    // on silence), releases nothing, and is counted as a PAD frame, not a skip. If audio IS
    // queued or pending the case is not this one, and it stays visible below as a SKIP.
    if pulled.speech, let can = canReleaseSpeechAudio, !can() {
      audioLock.lock(); let queued = !audioQueue.isEmpty; audioLock.unlock()
      if !queued && !rt.hasPendingTail {
        embodyPadFrames += 1
        if embodyPadFrames % 10 == 1 {
          NSLog("[embody-av] pad frame: speech-tagged, no slice, nothing queued or pending — published without audio; total pad=%d", embodyPadFrames)
        }
        publishEmbodyFrame(pulled.frame, dump: false)
        embodyFrameCount += 1
        embodyLastPublish = now
        return
      }
    }
    var frame = pulled.frame
    if pulled.speech, Self.markerEverySpeechFrames > 0,
       (speechFramesPublished + 1) % Self.markerEverySpeechFrames == 0 {
      // The marker: THIS frame is the flash, and the slice released for it carries the click.
      for i in 0..<frame.count { frame[i] = 0xFF }
      markerOnNextRelease = true
      embodyMarkers += 1
      NSLog("[embody-marker] #%d flash on speech frame %d at host %.3f s", embodyMarkers, speechFramesPublished + 1, CACurrentMediaTime())
    }
    publishEmbodyFrame(frame, dump: pulled.speech)
    embodyFrameCount += 1
    // Release this frame's 50 ms of bot audio (speech frames carry audio; the idle
    // loop is silent) → A/V paired 1:1.
    if pulled.speech {
      speechFrameLock.lock(); _speechFramesPublished += 1; speechFrameLock.unlock()
      onSpeechFramePublished?()
      noteSpeechFramePresented(now)
    }
    if embodyLastPublish > 0 {
      let gap = (now - embodyLastPublish) * 1000
      if gap > 75 { NSLog("[embody-stutter] %.0fms gap (queue=%d)", gap, rt.queuedFrames) }
    }
    embodyLastPublish = now
    if embodyFpsT0 == 0 { embodyFpsT0 = now }
    if embodyFrameCount % 40 == 0 {
      let dt = now - embodyFpsT0
      NSLog("[embody-fps] %.1f fps speech (40 frames / %.2fs), queue=%d", dt > 0 ? 40.0 / dt : 0, dt, rt.queuedFrames)
      embodyFpsT0 = now
    }
  }

  /// Publish the next frame of the pre-rendered idle loop (zero inference). Falls
  /// back to the single idle frame until the loop is built (first ~2 s of warm-up).
  /// One idle tick: the engine's NEXT idle frame, from its cursor over the clip
  /// (forward only, the wrap where the file ends — the engine logs each wrap with
  /// the index it happened at). The decoder's own IOSurface buffer goes to the
  /// texture untouched; only an engine without that surface (no clip, or an
  /// engine that serves idle as bytes) takes the BGR copy path.
  private func publishIdleLoopFrame(_ rt: any BithumanEngine) {
    noteIdleFramePresented()
    if let pb = rt.idleNextPixelBuffer() {
      publishPixelBufferToTexture(pb)
    } else if rt.idle(into: &bgrBuffer) > 0 {
      publishBGRToTexture()
    } else {
      return
    }
    embodyIdleCount += 1
    if embodyIdleCount % 100 == 0 { NSLog("[embody-idle] loop playing (%d frames, 0 inference)", embodyIdleCount) }
  }

  private func publishEmbodyFrame(_ fr: [UInt8], dump: Bool = false) {
    let n = min(fr.count, bgrBuffer.count)
    fr.withUnsafeBufferPointer { s in
      bgrBuffer.withUnsafeMutableBufferPointer { d in d.baseAddress!.update(from: s.baseAddress!, count: n) }
    }
    publishBGRToTexture()
    if dump && EmbodyAvatarDump.on { EmbodyAvatarDump.write(bgrBuffer, count: n) }
  }
  #endif

  /// REGISTRY-DRIVEN engine creation + capability-selected drive setup (M3). The
  /// engine is created by EngineRegistry.make(slug, ref) — no loadEmbody()/
  /// loadEssence2() hard-coding — then the drive is selected by the created
  /// engine's `capabilities.driveModel`, keeping BOTH proven setups verbatim. An
  /// essence2 request on an embody-only (ESSENCE2_AVAILABLE-unset) build is made as
  /// the expression2 default by the registry, so its driveModel is
  /// .bufferedDisplayClock — exactly the old embody fallback.
  private func loadFixtureAndRuntime() {
    #if os(macOS) || os(iOS)
    let ref = AvatarRef(path: imxPath, motionDir: motionDir, apiSecret: apiSecret)
    let engine = EngineRegistry.make(engineKind, ref)
    avatar = engine
    capabilities = engine.capabilities   // authoritative (handles the essence2→embody fallback)
    switch engine.capabilities.driveModel {
    case .bufferedDisplayClock:
      setupBufferedDisplayClock()
    case .atomicSlotClock:
      #if ESSENCE2_AVAILABLE
      setupAtomicSlotClock()
      #else
      // Unreachable: essence2 isn't registered on an embody-only build, so the
      // registry never yields an .atomicSlotClock engine. Kept for switch
      // exhaustiveness; degrade to the embody setup if it somehow occurs.
      setupBufferedDisplayClock()
      #endif
    }
    #endif
  }

  private func startTimer() {
    let t = DispatchSource.makeTimerSource(flags: .strict, queue: renderQueue)
    t.schedule(deadline: .now() + 0.040, repeating: 0.040, leeway: .milliseconds(2))
    t.setEventHandler { [weak self] in self?.composeTick() }
    timer = t
    t.resume()
    NSLog("[BithumanAvatar] timer started")
  }

  /// 40 ms render tick — drive selected by capabilities.driveModel (M3), not the
  /// engineKind string. .bufferedDisplayClock (embody): feed bot PCM here, display
  /// driven SEPARATELY by embodyDisplayTick at 20 fps. .atomicSlotClock (essence2):
  /// the SINGLE atomic feed+pull drive (composeTickEssence2), no second timer.
  private func composeTick() {
    guard !isShutdown else { return }
    #if os(macOS) || os(iOS)
    switch capabilities.driveModel {
    case .atomicSlotClock:
      #if ESSENCE2_AVAILABLE
      composeTickEssence2()
      #else
      composeTickEmbody()   // unreachable on an embody-only build (essence2 unregistered)
      #endif
    case .bufferedDisplayClock:
      composeTickEmbody()
    }
    #endif
  }

  /// Copy bgrBuffer into a CVPixelBuffer (BGRA on the Metal side) and
  /// publish it to the Flutter texture. Reused by both the active
  /// per-tick path and the one-shot static paint at startup.
  private func publishBGRToTexture() {
    let w = frameW, h = frameH
    guard w > 0, h > 0 else { return }
    if pixelBufferPool == nil { createPixelBufferPool(width: w, height: h) }
    guard let pool = pixelBufferPool else { return }
    var pb: CVPixelBuffer?
    let pbStatus = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb)
    guard pbStatus == kCVReturnSuccess, let pixelBuffer = pb else { return }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    if let dest = CVPixelBufferGetBaseAddress(pixelBuffer) {
      let destStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
      bgrBuffer.withUnsafeBytes { srcRaw in
        guard let src = srcRaw.baseAddress else { return }
        var srcBuf = vImage_Buffer(
          data: UnsafeMutableRawPointer(mutating: src),
          height: vImagePixelCount(h),
          width: vImagePixelCount(w),
          rowBytes: w * 3)
        var dstBuf = vImage_Buffer(
          data: dest,
          height: vImagePixelCount(h),
          width: vImagePixelCount(w),
          rowBytes: destStride)
        vImageConvert_RGB888toRGBA8888(&srcBuf, nil, 0xFF, &dstBuf, false,
                                       vImage_Flags(kvImageNoFlags))
      }
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    publishPixelBufferToTexture(pixelBuffer)
  }

  /// Publish an already-filled BGRA pixel buffer to the Flutter texture. The
  /// engine's idle frames arrive here straight from its hardware decoder
  /// (IOSurface-backed, the same format the pool above makes), so an idle tick
  /// costs no pixel copy at all; speech frames arrive via publishBGRToTexture.
  private func publishPixelBufferToTexture(_ pixelBuffer: CVPixelBuffer) {
    pixelBufferLock.lock()
    latestPixelBuffer = pixelBuffer
    #if os(iOS)
    let pipTap = pipFrameTap
    #endif
    pixelBufferLock.unlock()
    registry?.textureFrameAvailable(textureId)
    #if os(iOS)
    // System-PiP tee: same buffer, second consumer (AvatarPiP masks it
    // into the circular sample-buffer frame). Nil when PiP is inactive.
    pipTap?(pixelBuffer)
    #endif
    // Debug-only frame counter (set env BH_AVATAR_DEBUG=1 to enable): total
    // frames published to the Flutter texture (idle + speech), every 100.
    publishedFrameCount += 1
    if Self.avatarDebugLogging, publishedFrameCount % 100 == 0 {
      NSLog("[BithumanAvatar] texture frames=%d", publishedFrameCount)
    }
    // First published frame → release startRendering()'s gate so load() returns
    // with a painted texture (no black-canvas flash). Once-only; renderQueue-local.
    if !firstFrameSignaled {
      firstFrameSignaled = true
      firstFrameSemaphore.signal()
    }
  }

  private func createPixelBufferPool(width: Int, height: Int) {
    let attrs: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey  as String: width,
      kCVPixelBufferHeightKey as String: height,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ]
    let poolAttrs: [String: Any] = [
      // 2 is enough: the render loop publishes one buffer/tick at 25 fps and
      // the texture retains only the latest. 3 pinned 1248×704 BGRA buffers was
      // ~10.5 MB; 2 trims ~3.5 MB with no frame starvation at this cadence.
      kCVPixelBufferPoolMinimumBufferCountKey as String: 2
    ]
    var pool: CVPixelBufferPool?
    if CVPixelBufferPoolCreate(kCFAllocatorDefault,
                               poolAttrs as CFDictionary,
                               attrs as CFDictionary,
                               &pool) == kCVReturnSuccess {
      pixelBufferPool = pool
    }
  }

  private func releaseNativeResources() {
    #if os(macOS) || os(iOS)
    embodyDisplayTimer?.cancel(); embodyDisplayTimer = nil
    let t0 = CACurrentMediaTime()
    avatar?.shutdown()   // Expression 2: the meter's last beat; Essence 2: be_essence2_destroy + quiesce
    avatar = nil   // pure-Swift; ARC frees models/procQ
    NSLog("[BithumanAvatar] engine released (%.0f ms) — no tick or warm-up thread was inside it",
          (CACurrentMediaTime() - t0) * 1000)
    #endif
    pixelBufferLock.lock()
    latestPixelBuffer = nil
    pixelBufferLock.unlock()
    pixelBufferPool = nil
  }
}

// ------- ADOPTION: expand a PACKED agent container (2026-09-17) -------
// `Expression2Container.unpack` shipped in THIS pod and nothing on the plugin path
// called it. A downloaded expression-2 agent arrives as a packed container
// (`<CODE>.imx`), while `Expression2Engine.modelURL` / `resURL` only ever join a NAME
// onto `activeAgentDir` -- so a packed FILE resolved every per-identity member to a
// path that cannot exist. Measured on an iMac M4 (macOS 26.6.2) 2026-09-16, with the
// shared graphs supplied by hand so the refusal could not be blamed on them:
//     [embody] decp2 members missing/unloadable -- REFUSING
//     [embody] warmUp produced no idle frame
// while dec_p2_v3_all.mlpackage, canon.f32 and idle.mp4 were all sitting inside the
// container the app had been handed. essence-2 already expands its own container
// (~/Library/Caches/essence2-unpacked/<sha>); expression-2 on Apple did not, and that
// asymmetry -- not a missing member -- is why the macOS app rendered nothing.
//
// A DIRECTORY passes through untouched. Only a FILE is expanded. The unpacker does not
// cache, and a caller wanting a cache must own the staleness question with the container
// bytes in hand — so this one does: an expansion is REUSED only when its record
// (`.bh-expanded`, written last) names this very file — path, size, modification time
// (ns) and inode, which a re-download or an app update (a new bundle path) all change —
// and every member it lists is still there at its recorded size (a member directory: the
// bytes of every file under it; iOS may purge Caches).
// Anything else expands fresh, as before. Before: every cold start and every switch
// deleted and rewrote ~200 MB of Caches (0.32-0.54 s on an iPhone 15, on the platform
// thread). An expansion that fails returns the path UNCHANGED and says so, so the engine
// still refuses loudly by name rather than silently rendering a neighbouring identity.
private let bhExpandQueue = DispatchQueue(label: "ai.bithuman.avatar.expand", qos: .userInitiated)
private let bhExpandedRecord = ".bh-expanded"

/// What identifies the container's bytes without reading them (hashing ~200 MB would
/// cost what the expansion costs).
fileprivate func bhContainerStamp(_ url: URL) -> String? {
  guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
  let size = (a[.size] as? NSNumber)?.int64Value ?? -1
  let mtime = ((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1e9
  let inode = (a[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
  return "bh-expanded v1 \(url.path) size=\(size) mtime=\(Int64(mtime)) inode=\(inode)"
}

/// True when `dest` holds a complete expansion of exactly these container bytes.
fileprivate func bhExpansionIsCurrent(_ dest: URL, stamp: String) -> Bool {
  guard let rec = try? String(contentsOf: dest.appendingPathComponent(bhExpandedRecord), encoding: .utf8) else {
    return false
  }
  let lines = rec.split(separator: "\n", omittingEmptySubsequences: true)
  guard lines.count > 1, lines[0] == stamp else { return false }
  let fm = FileManager.default
  for line in lines.dropFirst() {
    guard let tab = line.lastIndex(of: "\t"), let want = Int64(line[line.index(after: tab)...]) else { return false }
    let member = dest.appendingPathComponent(String(line[..<tab]))
    guard fm.fileExists(atPath: member.path), bhMemberSize(member) == want else { return false }
  }
  return true
}

/// A member's size: a file's bytes, or — a member directory (an .mlpackage) — the bytes of
/// every file under it, so a partly purged package is not reused.
fileprivate func bhMemberSize(_ url: URL) -> Int64 {
  let fm = FileManager.default
  var isDir: ObjCBool = false
  guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return -1 }
  if !isDir.boolValue {
    return ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? -1
  }
  var total: Int64 = 0
  if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
    for case let f as URL in e {
      let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
      if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0) }
    }
  }
  return total
}

fileprivate func bhResolveExpression2AgentDir(_ path: String?) -> String? {
  guard let p = path, !p.isEmpty else { return nil }
  var isDir: ObjCBool = false
  guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir) else { return p }
  if isDir.boolValue { return p }
  let url = URL(fileURLWithPath: p)
  guard Expression2Container.isContainer(url) else {
    NSLog("[embody] agent path %@ is a FILE but not an IMX container - passed through unchanged", p)
    return p
  }
  let caches = URL(fileURLWithPath: NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first
           ?? NSTemporaryDirectory())
  // An app outside the sandbox shares ~/Library/Caches with every other one: under its own
  // bundle id, so two apps on this plugin never expand into (or delete) each other's copy.
  // macOS-only: an iOS app's Caches is its own container already
  #if os(macOS)
  let base = Bundle.main.bundleIdentifier.map { caches.appendingPathComponent($0) } ?? caches
  #else
  let base = caches
  #endif
  let dest = base
    .appendingPathComponent("expression2-unpacked")
    .appendingPathComponent(url.deletingPathExtension().lastPathComponent)
  let t0 = CFAbsoluteTimeGetCurrent()
  let stamp = bhContainerStamp(url)
  if let stamp = stamp, bhExpansionIsCurrent(dest, stamp: stamp) {
    NSLog("[embody] container expansion reused %@ -> %@ (%.3fs)",
          url.lastPathComponent, dest.path, CFAbsoluteTimeGetCurrent() - t0)
    return dest.path
  }
  do {
    // The record goes FIRST: a delete cut short must not leave a matching record over a
    // half-deleted tree.
    try? FileManager.default.removeItem(at: dest.appendingPathComponent(bhExpandedRecord))
    try? FileManager.default.removeItem(at: dest)
    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
    let names = try Expression2Container.unpack(url, to: dest)
    NSLog("[embody] container expanded %@ -> %@ (%d members, %.2fs)",
          url.lastPathComponent, dest.path, names.count, CFAbsoluteTimeGetCurrent() - t0)
    // The record goes in LAST, atomically: an expansion cut short leaves none, and the
    // next open expands fresh.
    if let stamp = stamp {
      var rec = stamp + "\n"
      for n in names {
        rec += "\(n)\t\(bhMemberSize(dest.appendingPathComponent(n)))\n"
      }
      try? rec.write(to: dest.appendingPathComponent(bhExpandedRecord), atomically: true, encoding: .utf8)
    }
    return dest.path
  } catch {
    NSLog("[embody] container expand FAILED for %@: %@ - path passed through unchanged; the engine refuses by name", p, "\(error)")
    return p
  }
}

#if os(iOS)
// iOS WebRTC remote-audio → avatar-lipsync tap. Mirrors the Android side
// (which uses Java reflection against flutter_webrtc's FlutterWebRTCPlugin
// + org.webrtc.AudioTrack). Here we reach flutter_webrtc's ObjC
// `FlutterWebRTCPlugin` via ObjC-runtime reflection so the bithuman plugin
// never has to declare a WebRTC pod dependency. RTCAudioTrack calls our
// `renderPCMBuffer:` selector by duck typing — formal RTCAudioRenderer
// protocol conformance is NOT required. macOS stays on the WebSocket path
// and never compiles this class.
@objc final class WebrtcLipsyncRenderer: NSObject {
  private weak var texture: AvatarTexture?
  private var track: NSObject?          // retained remote RTCAudioTrack (for removeRenderer on detach)
  private var carry: [Float] = []
  private var firedCount: Int64 = 0

  init(texture: AvatarTexture) { self.texture = texture; super.init() }

  /// Reflectively: FlutterWebRTCPlugin.sharedSingleton -> remoteTrackForId: -> track.addRenderer:self
  func attach(trackId: String) -> Bool {
    guard let pluginCls = NSClassFromString("FlutterWebRTCPlugin") as? NSObject.Type else { return false }
    let sharedSel = NSSelectorFromString("sharedSingleton")
    guard pluginCls.responds(to: sharedSel),
          let plugin = pluginCls.perform(sharedSel)?.takeUnretainedValue() as? NSObject else { return false }
    let trackSel = NSSelectorFromString("remoteTrackForId:")
    guard plugin.responds(to: trackSel),
          let t = plugin.perform(trackSel, with: trackId)?.takeUnretainedValue() as? NSObject else { return false }
    let addSel = NSSelectorFromString("addRenderer:")
    guard t.responds(to: addSel) else { return false }
    t.perform(addSel, with: self)
    self.track = t
    return true
  }

  func detach() {
    guard let t = track else { return }
    let rmSel = NSSelectorFromString("removeRenderer:")
    if t.responds(to: rmSel) { t.perform(rmSel, with: self) }
    track = nil
  }

  /// RTCAudioRenderer. ObjC selector renderPCMBuffer: (NS_SWIFT_NAME render(pcmBuffer:)).
  /// Called on libwebrtc's ADM render thread. Buffer is Int16 (sometimes Float32),
  /// non-interleaved, at the remote rate (typically 48 kHz). Convert -> mono Float32,
  /// box-filter resample to 16 kHz (integer ratio; linear for non-integer), emit 640-sample chunks.
  @objc(renderPCMBuffer:) func render(pcmBuffer: AVAudioPCMBuffer) {
    firedCount += 1
    let frames = Int(pcmBuffer.frameLength); if frames == 0 { return }
    let fmt = pcmBuffer.format
    let ch = Int(fmt.channelCount); let rate = fmt.sampleRate
    if firedCount == 1 { NSLog("[BithumanAvatar] WebrtcLipsyncRenderer firing rate=%.0f ch=%d frames=%d", rate, ch, frames) }
    var mono = [Float](repeating: 0, count: frames)
    if fmt.commonFormat == .pcmFormatInt16, let cd = pcmBuffer.int16ChannelData {
      let inv = 1.0 / (Float(max(ch,1)) * 32768.0)
      for c in 0..<ch { let p = cd[c]; for i in 0..<frames { mono[i] += Float(p[i]) * inv } }
    } else if fmt.commonFormat == .pcmFormatFloat32, let cd = pcmBuffer.floatChannelData {
      let inv = 1.0 / Float(max(ch,1))
      for c in 0..<ch { let p = cd[c]; for i in 0..<frames { mono[i] += p[i] * inv } }
    } else { return }
    let res = resampleTo16k(mono, inRate: rate); if res.isEmpty { return }
    var combined = carry + res; carry = []
    var off = 0; let per = 640
    while off + per <= combined.count { texture?.enqueueFloatChunk(Array(combined[off..<off+per])); off += per }
    if off < combined.count { carry = Array(combined[off...]) }
  }

  private func resampleTo16k(_ input: [Float], inRate: Double) -> [Float] {
    if inRate == 16000 || input.isEmpty { return input }
    let ratio = inRate / 16000.0; let ir = Int(ratio)
    if Double(ir) == ratio && ir >= 2 {
      let outLen = input.count / ir; var out = [Float](repeating: 0, count: outLen); let inv = 1.0/Float(ir)
      for i in 0..<outLen { var s: Float = 0; for j in 0..<ir { s += input[i*ir+j] }; out[i] = s*inv }
      return out
    }
    let outLen = Int(Double(input.count)/ratio); if outLen <= 0 { return [] }
    var out = [Float](repeating: 0, count: outLen)
    for i in 0..<outLen { let sp = Double(i)*ratio; let idx = Int(sp); let f = Float(sp-Double(idx)); out[i] = idx+1 < input.count ? input[idx]*(1-f)+input[idx+1]*f : input[idx] }
    return out
  }
}
#endif
