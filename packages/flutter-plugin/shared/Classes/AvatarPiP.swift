// bithuman — iOS system Picture-in-Picture for the avatar bubble.
//
// Sample-buffer PiP (iOS 15+, the camera-app pattern): the AvatarTexture's
// CVPixelBuffer stream is teed into an AVSampleBufferDisplayLayer that backs
// an AVPictureInPictureController(contentSource:). "Minimize" on iOS then
// floats the avatar's head over the SYSTEM — home screen, other apps — not
// just inside our own window.
//
// PiP has no transparency, so the circular bubble mask is rendered INTO each
// buffer: the frame's center-square head region clipped to a circle on a
// dark backdrop (CoreImage, one GPU blend per 384x384 head frame at ≤25 fps).
// Elevate head mode feeds square head-only frames; a full-canvas / Essence
// stream degrades gracefully to a center-square circle crop.
//
// Requires the Runner's UIBackgroundModes=audio (Info.plist) for frames to
// keep flowing once the app backgrounds; on devices without PiP support the
// Dart side keeps its in-app overlay fallback.
//
// Apache-2.0; (c) bitHuman.

#if os(iOS)
import AVFoundation
import AVKit
import CoreImage
import CoreMedia
import UIKit

final class AvatarPiP: NSObject {
  private let displayLayer = AVSampleBufferDisplayLayer()
  // Host view for the layer — PiP requires the sample-buffer layer to live
  // in an installed view hierarchy. 1x1 pt behind the Flutter view: present
  // for UIKit, invisible to the user (the in-app canvas keeps rendering).
  private let container = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
  private var controller: AVPictureInPictureController?
  private weak var texture: AvatarTexture?
  /// Dart event bridge: "started" | "failed" | "stopped" | "restore".
  private let sendEvent: (String) -> Void

  // Circular-mask compositor (renderQueue): CoreImage blend of the head
  // frame over a dark backdrop through a circle mask, into pooled BGRA
  // buffers. Mask + pool are cached per head-frame side length.
  private let ciContext = CIContext(options: [.cacheIntermediates: false])
  private var maskImage: CIImage?
  private var outPool: CVPixelBufferPool?
  private var cachedSide: Int = 0
  private let backdrop = CIColor(red: 0.063, green: 0.063, blue: 0.078) // 0xFF101014

  private var framesFed = 0
  private var startAttempts = 0
  private var stopped = false
  // Set by the willStart delegate — the watchdog must not report "failed"
  // while an engagement is in flight (observed race: app backgrounds at
  // watchdog time, will-start fires, probe still reads active=0 for the
  // ~0.5 s until didStart — a spurious "failed" then bounces the engine
  // FULL→HEAD until the 'started' event heals it).
  private var sawWillStart = false

  init(texture: AvatarTexture, sendEvent: @escaping (String) -> Void) {
    self.texture = texture
    self.sendEvent = sendEvent
    super.init()
  }

  /// Build the controller + tee the frame stream, then kick off the start
  /// (retried briefly — isPictureInPicturePossible flips asynchronously
  /// after controller creation). Returns false only when no window exists
  /// to host the layer. Must be called on the main thread.
  func start() -> Bool {
    guard let window = UIApplication.shared.connectedScenes
      .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first
      ?? UIApplication.shared.connectedScenes
        .compactMap({ ($0 as? UIWindowScene)?.windows.first }).first else {
      NSLog("[pip] no key window to host the sample-buffer layer")
      return false
    }
    // PiP needs a playback-capable audio session to report "possible".
    // Don't touch a session RealtimeAudioIO already owns (playAndRecord +
    // VP-IO during live calls) — only lift the default .soloAmbient.
    // NO .mixWithOthers: mixable sessions are a known silent suppressor of
    // PiP engagement.
    let session = AVAudioSession.sharedInstance()
    if session.category != .playback && session.category != .playAndRecord {
      try? session.setCategory(.playback)
      try? session.setActive(true)
    }
    container.isUserInteractionEnabled = false
    container.frame = CGRect(x: 0, y: 0, width: 320, height: 320)
    displayLayer.frame = container.bounds
    displayLayer.videoGravity = .resizeAspect
    if displayLayer.superlayer == nil { container.layer.addSublayer(displayLayer) }
    window.insertSubview(container, at: 0)   // behind the Flutter view

    let source = AVPictureInPictureController.ContentSource(
      sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
    let pip = AVPictureInPictureController(contentSource: source)
    pip.delegate = self
    pip.requiresLinearPlayback = true   // live content — no skip controls
    // Sanctioned auto-start: when the app backgrounds while the bubble is
    // up (home / app switch), the system itself floats the PiP window —
    // no gesture-context requirement. This is the primary path on devices
    // where the FOREGROUND programmatic start below is silently ignored.
    pip.canStartPictureInPictureAutomaticallyFromInline = true
    controller = pip

    // Prime with the latest frame so the controller has content to measure,
    // then tee every published frame.
    if let pb = texture?.currentPixelBufferForPiP() { feed(pb) }
    texture?.setPiPFrameTap { [weak self] pb in self?.feed(pb) }

    NSLog("[pip] controller created — starting (supported=%d)",
          AVPictureInPictureController.isPictureInPictureSupported() ? 1 : 0)
    attemptStart()
    return true
  }

  /// Tear down: detach the tee, stop the system PiP window if it's up, drop
  /// the layer. Safe to call twice (pipStop + the didStop event round-trip).
  func stop() {
    guard !stopped else { return }
    stopped = true
    texture?.setPiPFrameTap(nil)
    if controller?.isPictureInPictureActive == true {
      controller?.stopPictureInPicture()
    }
    controller = nil
    displayLayer.flushAndRemoveImage()
    container.removeFromSuperview()
    NSLog("[pip] session torn down (frames fed: %d)", framesFed)
  }

  /// isPictureInPicturePossible flips true asynchronously once the layer has
  /// content and the controller settles — poll briefly, then start. ~3 s of
  /// retries covers cold starts; exhaustion reports "failed" so Dart falls
  /// back to the in-app overlay.
  private func attemptStart() {
    guard !stopped, let pip = controller else { return }
    if pip.isPictureInPictureActive { return }
    if pip.isPictureInPicturePossible {
      NSLog("[pip] isPictureInPicturePossible — startPictureInPicture()")
      pip.startPictureInPicture()
      // WATCHDOG: a foreground programmatic start can be SILENTLY ignored
      // (no didStart, no failedToStart — observed on iOS 26). If the
      // window isn't up in 4 s, report "failed" so Dart shows the in-app
      // overlay fallback. The controller + frame tee STAY alive: with
      // canStartPictureInPictureAutomaticallyFromInline the system still
      // floats the bubble itself when the app backgrounds.
      DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
        guard let self, !self.stopped, let p = self.controller else { return }
        NSLog("[pip] post-start probe: active=%d possible=%d willStart=%d",
              p.isPictureInPictureActive ? 1 : 0,
              p.isPictureInPicturePossible ? 1 : 0,
              self.sawWillStart ? 1 : 0)
        // sawWillStart: an engagement is in flight (e.g. the app just
        // backgrounded and the system is animating the window up) — didStart
        // /failedToStart will report the real outcome; a "failed" here would
        // spuriously bounce the engine out of head mode.
        if !p.isPictureInPictureActive && !self.sawWillStart {
          NSLog("[pip] foreground start silently ignored — overlay fallback; auto-PiP stays armed for backgrounding")
          self.sendEvent("failed")
        }
      }
      return
    }
    startAttempts += 1
    guard startAttempts < 20 else {
      NSLog("[pip] never became possible after %d attempts — falling back", startAttempts)
      sendEvent("failed")
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
      self?.attemptStart()
    }
  }

  // ── frame path (renderQueue) ──────────────────────────────────────────

  private func feed(_ src: CVPixelBuffer) {
    guard !stopped else { return }
    guard let out = composeCircular(src) else { return }
    var fmtOut: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: out,
            formatDescriptionOut: &fmtOut) == noErr,
          let fmt = fmtOut else { return }
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 25),
      presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
      decodeTimeStamp: .invalid)
    var sampleOut: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: out,
            formatDescription: fmt, sampleTiming: &timing,
            sampleBufferOut: &sampleOut) == noErr,
          let sample = sampleOut else { return }
    if displayLayer.status == .failed { displayLayer.flush() }
    guard displayLayer.isReadyForMoreMediaData else { return }
    displayLayer.enqueue(sample)
    framesFed += 1
    if framesFed == 1 || framesFed % 250 == 0 {   // ~every 10 s at 25 fps
      NSLog("[pip] frames=%d (%dx%d circle)", framesFed,
            CVPixelBufferGetWidth(out), CVPixelBufferGetHeight(out))
    }
  }

  /// Head frame → circular bubble frame: center-square crop (head mode is
  /// already square; full-canvas frames crop to their top-center where the
  /// head lives), clipped to a circle over the dark backdrop.
  private func composeCircular(_ src: CVPixelBuffer) -> CVPixelBuffer? {
    let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
    guard w > 0, h > 0 else { return nil }
    let side = min(w, h)
    ensureMaskAndPool(side: side)
    guard let pool = outPool, let mask = maskImage else { return nil }

    var img = CIImage(cvPixelBuffer: src)
    if w != h {
      // CIImage origin is bottom-left → the portrait canvas's head band
      // (top of the frame) is the TOP-aligned square: y = h - side.
      let crop = CGRect(x: CGFloat((w - side) / 2),
                        y: CGFloat(h - side),
                        width: CGFloat(side), height: CGFloat(side))
      img = img.cropped(to: crop)
        .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
    }
    let extent = CGRect(x: 0, y: 0, width: side, height: side)
    let bg = CIImage(color: backdrop).cropped(to: extent)
    guard let blend = CIFilter(name: "CIBlendWithMask", parameters: [
      kCIInputImageKey: img,
      kCIInputBackgroundImageKey: bg,
      kCIInputMaskImageKey: mask,
    ])?.outputImage else { return nil }

    var dstOut: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &dstOut)
            == kCVReturnSuccess, let dst = dstOut else { return nil }
    ciContext.render(blend, to: dst, bounds: extent,
                     colorSpace: CGColorSpaceCreateDeviceRGB())
    return dst
  }

  private func ensureMaskAndPool(side: Int) {
    guard side != cachedSide else { return }
    cachedSide = side
    // Grayscale circle mask (CIBlendWithMask reads luminance): white disk,
    // 2 px soft edge, black outside.
    let r = CGFloat(side) / 2
    if let radial = CIFilter(name: "CIRadialGradient", parameters: [
      "inputCenter": CIVector(x: r, y: r),
      "inputRadius0": r - 2,
      "inputRadius1": r,
      "inputColor0": CIColor.white,
      "inputColor1": CIColor.black,
    ])?.outputImage {
      maskImage = radial.cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
    }
    let attrs: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: side,
      kCVPixelBufferHeightKey as String: side,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ]
    var pool: CVPixelBufferPool?
    CVPixelBufferPoolCreate(kCFAllocatorDefault,
                            [kCVPixelBufferPoolMinimumBufferCountKey as String: 3] as CFDictionary,
                            attrs as CFDictionary, &pool)
    outPool = pool
  }
}

// ── AVPictureInPictureControllerDelegate — lifecycle → log + Dart ────────

extension AvatarPiP: AVPictureInPictureControllerDelegate {
  func pictureInPictureControllerWillStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController) {
    sawWillStart = true
    NSLog("[pip] will start")
  }

  func pictureInPictureControllerDidStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController) {
    NSLog("[pip] DID START — avatar floating over the system")
    sendEvent("started")
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error) {
    NSLog("[pip] FAILED to start: %@", String(describing: error))
    sendEvent("failed")
  }

  func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController) {
    NSLog("[pip] did stop")
    sendEvent("stopped")
  }

  /// The user tapped the PiP "restore" button — Dart exits bubble mode
  /// (engine back to FULL, normal layout) while the system animates the
  /// PiP window back into the app.
  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler
      completionHandler: @escaping (Bool) -> Void) {
    NSLog("[pip] restore requested — handing the avatar back to the app UI")
    sendEvent("restore")
    completionHandler(true)
  }
}

// ── AVPictureInPictureSampleBufferPlaybackDelegate — live stream ─────────

extension AvatarPiP: AVPictureInPictureSampleBufferPlaybackDelegate {
  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    setPlaying playing: Bool) {
    // Live avatar — play/pause from the PiP chrome is a no-op.
  }

  func pictureInPictureControllerTimeRangeForPlayback(
    _ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
    // Infinite live range — PiP shows live-content chrome (no scrubber).
    CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
  }

  func pictureInPictureControllerIsPlaybackPaused(
    _ pictureInPictureController: AVPictureInPictureController) -> Bool {
    false
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
    NSLog("[pip] render size %dx%d", newRenderSize.width, newRenderSize.height)
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    skipByInterval skipInterval: CMTime,
    completion completionHandler: @escaping () -> Void) {
    completionHandler()   // live — skipping is meaningless
  }
}
#endif
