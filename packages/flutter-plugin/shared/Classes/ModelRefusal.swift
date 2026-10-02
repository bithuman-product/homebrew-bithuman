// ModelRefusal.swift — MODEL_REJECTED (2.6.29): the engine refused to create from the model file.
//
// Until 2.6.29 an Apple engine that refused its file was a SILENT still face: Essence 2's
// be_essence2_create -2 / -4 only reached NSLog, the texture painted the gray fallback, `isReady`
// never flipped and the app waited out its own timeout behind it. Now the refusal is ONE typed,
// terminal error in Dart (`BithumanModelRejected`, the code a realtime session reports on its
// errorStream, the paywall's teardown): Essence 2's comes back from `load` itself (the engine is
// created inside it), Expression 2's — whose warm-up runs after `load` returned — as the push
// `modelRejected`. Android answers the same code from its load (ModelRejection.kt).
//
// Foundation only, so scripts/test_swift_unit.sh compiles it with its test on any Mac.
import Foundation

public struct BithumanModelRefusal: Equatable {
  /// The Flutter error code / Dart `BithumanModelRejected.code`.
  public static let code = "MODEL_REJECTED"
  /// `essence2` or `expression2`.
  public let engine: String
  /// The engine's own number (be_essence2_create's return code), nil when it has none.
  public let nativeCode: Int?
  /// What refused, with the native code and the engine's sentence.
  public let message: String

  /// The error `details` / push arguments (Dart: `BithumanModelRejected.fromMap`).
  public var details: [String: Any] {
    var d: [String: Any] = ["engine": engine, "message": message]
    if let c = nativeCode { d["nativeCode"] = c }
    return d
  }

  /// be_essence2_create's answer for [path] as a model refusal, or nil when it is not one:
  /// 0 opened; -1 a bad argument (the caller's); -3 no authenticated session (the credential's
  /// problem, not the file's). -2 the engine could not open the file; -4 the file predates the
  /// engine's current format (published before the mouth-corner fix); any other negative
  /// code is a refusal this plugin does not know by number yet. [sentence] is
  /// be_essence2_last_refusal's text, when the engine gave one.
  public static func essence2(rc: Int32, sentence: String, path: String) -> BithumanModelRefusal? {
    if rc == 0 || rc == -1 || rc == -3 { return nil }
    let why: String
    switch rc {
    case -4: why = sentence.isEmpty ? "the avatar file predates this engine's format; download it again" : sentence
    case -2: why = sentence.isEmpty ? "the engine could not open the avatar file" : sentence
    default: why = sentence.isEmpty ? "the engine refused the avatar file" : sentence
    }
    let file = (path as NSString).lastPathComponent
    return BithumanModelRefusal(engine: "essence2", nativeCode: Int(rc),
                                message: "Essence 2 refused the model file (be_essence2_create \(rc)) \(file): \(why)")
  }

  /// Expression 2's warm-up as a model refusal, or nil. Its `warmUp` cannot throw: it returns
  /// without readiness when metering refused (`meteringRefusal`, the credential's) or when the
  /// identity's model files would not load (missing / unloadable members — the only other early
  /// returns). So: warmed, not ready, and no metering refusal = the files were refused.
  public static func expression2(warmed: Bool, isReady: Bool, meteringRefusal: String?,
                                 reason: String?) -> BithumanModelRefusal? {
    guard warmed, !isReady, meteringRefusal == nil else { return nil }
    let r = (reason?.isEmpty == false) ? reason! : "missing or unloadable model members"
    return BithumanModelRefusal(engine: "expression2", nativeCode: nil,
                                message: "Expression 2 refused the model files (warm-up did not finish): \(r)")
  }
}
