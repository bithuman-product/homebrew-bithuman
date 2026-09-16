import Foundation

/// DEV LEVERS — every environment variable that can steer this plugin, read in ONE place.
///
/// A RELEASE build reads none of them: `DevLevers.env(_:)` compiles to `nil` unless the
/// build defines `DEBUG`. The CocoaPods Pods project sets
/// `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG` on its Debug configuration only, so
/// `flutter run` / a Debug scheme keeps every lever and `flutter build ... --release`
/// (what ships) has no code path that reads the environment at all.
///
/// Why (2026-09-15/16): a persistent Android sysprop — our own A/V sync marker — painted
/// every 40th speech unit WHITE with a click on every build after it, release included,
/// and reached the owner's phone; the Android plugin now gates on FLAG_DEBUGGABLE (#41).
/// `EMBODY_MARKER_EVERY` below is that marker's Apple twin. `BITHUMAN_NO_VPIO` removes the
/// echo canceller, `EMBODY_TEST_AUDIO` feeds a buzz forever, `EMBODY_TEST_WAV` drives the
/// engine from a file, and two probe files were written to /tmp by every build. A dev lever
/// a release build honours is a customer defect.
///
/// `scripts/check_dev_levers.sh` refuses any `ProcessInfo.processInfo.environment[`,
/// `getenv(` or `NSHomeDirectory()` outside this file, so a new lever cannot bypass it.
enum DevLevers {
  /// True only in a DEBUG build. Release: false, and every lever below is nil / false / 0.
  static let enabled: Bool = {
    #if DEBUG
    return true
    #else
    return false
    #endif
  }()

  /// THE one read. Release builds return nil for every name, whatever the environment holds.
  static func env(_ name: String) -> String? {
    #if DEBUG
    return ProcessInfo.processInfo.environment[name]
    #else
    return nil
    #endif
  }

  /// "1" / "true" ⇒ on.
  static func flag(_ name: String) -> Bool {
    let v = env(name) ?? ""
    return v == "1" || v.lowercased() == "true"
  }

  /// A non-empty path, or nil. A relative path resolves against the app's home
  /// (a phone has no shared filesystem with the host).
  static func path(_ name: String) -> String? {
    guard let p = env(name), !p.isEmpty else { return nil }
    #if DEBUG
    return p.hasPrefix("/") ? p : NSHomeDirectory() + "/" + p
    #else
    return nil
    #endif
  }

  // ── the inventory: each name appears exactly once, here ────────────────────────────

  /// Verbose per-chunk audio logs (RMS, per-channel peak, mic event-channel traces).
  static let debugAudio = flag("BITHUMAN_DEBUG_AUDIO")
  /// Barge-calibration logs: post-AEC mic peak vs the effective threshold.
  static let debugBarge = flag("BITHUMAN_DEBUG_BARGE")
  /// Disable VP-IO ⇒ raw mic, NO echo cancellation (macOS 26 bring-up only).
  static let noVPIO = flag("BITHUMAN_NO_VPIO")
  /// Per-frame texture counter logs ("texture frames=N" every 100).
  static let avatarDebug = flag("BH_AVATAR_DEBUG")
  /// Dump the first published embody frames as BGR files.
  static let dumpFrames = env("EMBODY_DUMP_FRAMES") != nil
  /// Directory for every probe / dump file. nil ⇒ NO probe file is written anywhere
  /// (before 2026-09-16 two probes defaulted to /tmp and were written by every build).
  static let dumpDir: String? = path("EMBODY_DUMP_DIR")
  /// A/V sync marker: flash the frame WHITE and mix a click every N seconds of speech.
  static let markerEverySeconds: Double = Double(env("EMBODY_MARKER_EVERY") ?? "0") ?? 0
  /// Replace the warm-up speech clip (changes the context seed).
  static let warmWav: String? = path("EMBODY_WARM_WAV")
  /// Feed a synthetic 140 Hz buzz forever so the mouth moves with no conversation.
  static let testAudio = flag("EMBODY_TEST_AUDIO")
  /// Drive the engine from a wav file as bot speech (the conformance demo cell's hook).
  static let testWav: String? = path("EMBODY_TEST_WAV")
  /// Run `benchSync(20)` once after warm-up.
  static let bench = flag("EMBODY_BENCH")
}
