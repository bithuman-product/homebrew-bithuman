import Cocoa
import FlutterMacOS

/// Borderless "liquid glass" window chrome for the macOS surface — ONE implementation in
/// the plugin, consumed by every app (moved down from bithuman-jarvis-app's Runner on
/// 2026-09-15 so the demo and jarvis share it instead of each carrying a copy).
///
/// Bound lazily to the Flutter view's window on the first `configure` call from Dart
/// (`WindowChrome.attach()` in ui_kit.dart), because at plugin registration the view
/// is not in a window yet.
///
/// What it does:
///   • Borderless look: full-size content view, transparent titlebar, hidden title — the
///     avatar canvas runs edge-to-edge under the (invisible) titlebar. The window stays
///     `.titled` so the traffic lights, edge resizing and `fitWindowToCanvas`'s
///     contentAspectRatio lock keep working.
///   • Rounded corners: transparent window + a Glass.rWindow (18 pt) continuous-curve
///     mask on the content view's layer; the system shadow follows the shape.
///   • Traffic lights on hover only.
///   • `ai.bithuman.window` MethodChannel:
///       configure   — bind + apply the chrome (idempotent).
///       startDrag   — drag-anywhere: Dart's pan-start forwards here and the whole
///                     window rides the mouse (no titlebar to grab).
///       enterBubble — collapse to a small always-on-top circle at the lower-right of
///                     the screen (frame, aspect lock and level saved). The Mac companion.
///       exitBubble  — restore the saved frame, aspect lock and level.
///       info        — mode / frame / level snapshot, for log-driven validation.
final class WindowChrome: NSResponder {
  static let normalRadius: CGFloat = 18 // == Glass.rWindow (glass_tokens.dart)

  private let channel: FlutterMethodChannel
  private weak var registrar: FlutterPluginRegistrar?
  private weak var window: NSWindow?
  private var configured = false

  // Bubble mode: saved normal-window state for the restore.
  private var bubble = false
  private var savedFrame: NSRect?
  private var savedAspect = NSSize.zero
  private var savedCollection: NSWindow.CollectionBehavior = []

  /// One per engine, retained for the process lifetime (the channel handler holds it).
  private static var instances: [WindowChrome] = []

  static func register(with registrar: FlutterPluginRegistrar) {
    let chrome = WindowChrome(registrar: registrar)
    instances.append(chrome)
    chrome.channel.setMethodCallHandler { [weak chrome] call, result in
      chrome?.handle(call, result: result)
    }
  }

  private init(registrar: FlutterPluginRegistrar) {
    self.registrar = registrar
    self.channel = FlutterMethodChannel(name: "ai.bithuman.window", binaryMessenger: registrar.messenger)
    super.init()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  // ── Binding ──────────────────────────────────────────────────────────

  /// The window the Flutter view lives in, found when first asked for.
  private func bind() -> NSWindow? {
    if let w = window { return w }
    let w = registrar?.view?.window ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible })
    window = w
    return w
  }

  private func configure() {
    guard !configured, let window = bind() else { return }
    configured = true
    window.styleMask.insert(.fullSizeContentView)
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    // Transparent window + layer mask = our rounded shape; the system shadow follows
    // the rendered content automatically.
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = true
    // The Flutter view must not paint its own opaque background, or the corners (and
    // the bubble's circular cutout later) would stay black.
    (window.contentViewController as? FlutterViewController)?.backgroundColor = .clear
    if let cv = window.contentView {
      cv.wantsLayer = true
      cv.layer?.cornerRadius = Self.normalRadius
      cv.layer?.cornerCurve = .continuous
      cv.layer?.masksToBounds = true
      cv.addTrackingArea(NSTrackingArea(
        rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
        owner: self, userInfo: nil))
    }
    setTrafficLights(alpha: 0)
    logChrome("configured")
  }

  // ── Traffic lights on hover ─────────────────────────────────────────

  private var trafficLights: [NSButton] {
    guard let window = window else { return [] }
    return [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
      .compactMap { window.standardWindowButton($0) }
  }

  private func setTrafficLights(alpha: CGFloat, animated: Bool = false) {
    let apply = { (b: NSButton) in
      if animated { b.animator().alphaValue = alpha } else { b.alphaValue = alpha }
    }
    if animated {
      NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.18; trafficLights.forEach(apply) }
    } else {
      trafficLights.forEach(apply)
    }
  }

  private func setTrafficLights(hidden: Bool) {
    trafficLights.forEach { $0.isHidden = hidden }
    if hidden { setTrafficLights(alpha: 0) }
  }

  override func mouseEntered(with event: NSEvent) {
    if bubble { return } // the bubble has no native chrome — Flutter draws its own
    setTrafficLights(alpha: 1, animated: true)
  }

  override func mouseExited(with event: NSEvent) {
    setTrafficLights(alpha: 0, animated: true)
  }

  private func setCornerRadius(_ r: CGFloat) {
    window?.contentView?.layer?.cornerRadius = r
  }

  // ── Channel ─────────────────────────────────────────────────────────

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "configure":
      configure()
      result(configured)
    case "startDrag":
      configure()
      if let event = NSApp.currentEvent { window?.performDrag(with: event) }
      result(nil)
    case "enterBubble":
      configure()
      let size = CGFloat((call.arguments as? [String: Any])?["size"] as? Double ?? 140)
      enterBubble(size: size)
      result(nil)
    case "exitBubble":
      exitBubble()
      result(nil)
    case "info":
      result(chromeInfo())
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // ── The Mac companion: minimise to a floating circle ────────────────

  /// Collapse to a small always-on-top circular bubble at the lower-right of the current
  /// screen. The Flutter side has already swapped to its circular BubbleView (transparent
  /// outside the circle); this masks the window itself to the same circle, floats it above
  /// everything and follows the user across Spaces. Mouse events stay ON (drag +
  /// click-to-restore).
  private func enterBubble(size: CGFloat) {
    guard !bubble, let window = window else { return }
    bubble = true
    savedFrame = window.frame
    savedAspect = window.contentAspectRatio
    savedCollection = window.collectionBehavior
    // No user resizing in bubble mode; clearing resizeIncrements also clears the
    // fitWindowToCanvas aspect lock so the 1:1 frame isn't fought.
    window.styleMask.remove(.resizable)
    window.resizeIncrements = NSSize(width: 1, height: 1)
    setTrafficLights(hidden: true)
    let vis = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let margin: CGFloat = 24
    let target = NSRect(x: vis.maxX - size - margin, y: vis.minY + margin, width: size, height: size)
    setCornerRadius(size / 2)
    window.setFrame(target, display: true, animate: true)
    window.level = .floating
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.ignoresMouseEvents = false
    window.invalidateShadow()
    logChrome("enterBubble")
  }

  /// Restore the pre-bubble window: saved frame, aspect lock, normal level.
  private func exitBubble() {
    guard bubble, let window = window else { return }
    bubble = false
    window.styleMask.insert(.resizable)
    window.level = .normal
    window.collectionBehavior = savedCollection
    setCornerRadius(Self.normalRadius)
    if let f = savedFrame { window.setFrame(f, display: true, animate: true) }
    if savedAspect.width > 0, savedAspect.height > 0 { window.contentAspectRatio = savedAspect }
    setTrafficLights(hidden: false) // alpha stays hover-driven (starts 0)
    window.invalidateShadow()
    logChrome("exitBubble")
  }

  // ── Log-driven validation ───────────────────────────────────────────

  private func chromeInfo() -> [String: Any] {
    guard let window = window else { return ["mode": "unbound"] }
    return [
      "mode": bubble ? "bubble" : "normal",
      "styleMask": String(format: "0x%lx", window.styleMask.rawValue),
      "level": window.level.rawValue,
      "frame": NSStringFromRect(window.frame),
      "aspect": "\(window.contentAspectRatio.width)x\(window.contentAspectRatio.height)",
      "isOpaque": window.isOpaque,
    ]
  }

  private func logChrome(_ tag: String) {
    NSLog("[window-chrome] %@ %@", tag, String(describing: chromeInfo()))
  }
}
