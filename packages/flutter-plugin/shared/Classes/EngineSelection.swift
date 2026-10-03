// EngineSelection.swift — which engine a `load` names, decided before anything is created (2.6.36).
//
// Until 2.6.35 a name the registry did not know (the Dart default `'essence'` among them), and
// `essence2` in a build that does not carry the Essence 2 engine, both rendered Expression 2 without a
// word: the app asked for one character and showed another. Now `load` fails with the code Android
// answers for an engine it cannot run (`unsupported`) and a message that says what to do.
//
// The same holds for an engine this build carries on an OS it does not run on (2.6.36): Essence 2
// renders on iOS 26 / macOS 26 and later. While the staged libessence2 is built for 26 the pod declares
// that floor and no older OS runs the app; a libessence2 rebuilt at the package floor (Swift package
// 2.20.2, bithuman-models #1826) lets the app run on iOS 16 again, and there `load(engine: 'essence2')`
// fails here, by name, instead of reaching the engine.
//
// Foundation and EngineId only, so test/swift/engine_selection_test.swift runs it with swiftc alone
// (scripts/test_swift_unit.sh). EngineRegistry.select(_:) applies it to the registered engines.
//
// Apache-2.0; (c) bitHuman.

import Foundation

enum EngineSelection: Equatable {
  /// A registered engine that this build carries: its canonical slug.
  case engine(String)
  /// No registered engine has this name.
  case unknown(String)
  /// A registered engine (canonical slug) that this build does not carry.
  case notInBuild(String)
  /// A registered engine this build carries (canonical slug) that needs a newer OS than this device runs:
  /// the requirement ("iOS 26") and the running OS ("iOS 17.5").
  case needsNewerOS(String, need: String, running: String)

  /// The FlutterError code, the same as Android's for an engine it cannot run.
  static let errorCode = "unsupported"

  /// Resolve [slug] against [ids] (canonical or alias); [inBuild] says whether a canonical slug's engine
  /// is linked into this build; [unmetOS] names the OS a canonical slug's engine needs when this device
  /// runs an older one (nil: it runs here) and the OS this device runs.
  static func resolve(_ slug: String, among ids: [EngineId], inBuild: (String) -> Bool,
                      unmetOS: (String) -> (need: String, running: String)? = { _ in nil }) -> EngineSelection {
    guard let id = ids.first(where: { $0.matches(slug) }) else { return .unknown(slug) }
    guard inBuild(id.canonical) else { return .notInBuild(id.canonical) }
    if let os = unmetOS(id.canonical) { return .needsNewerOS(id.canonical, need: os.need, running: os.running) }
    return .engine(id.canonical)
  }

  /// The engine names in messages.
  static func displayName(_ canonical: String) -> String {
    canonical == "essence2" ? "Essence 2" : canonical == "expression2" ? "Expression 2" : canonical
  }

  /// The canonical slug to load, or nil when the load must fail.
  var canonical: String? {
    if case .engine(let c) = self { return c }
    return nil
  }

  /// The FlutterError message when the load must fail; nil for a usable engine.
  var errorMessage: String? {
    switch self {
    case .engine:
      return nil
    case .unknown(let s):
      return "unknown engine '\(s)': pass engine: 'expression2' or 'essence2' (also accepted: 'expression-2', 'essence-2')"
    case .notInBuild(let c):
      return "this build does not include the \(Self.displayName(c)) engine: run the plugin's scripts/bootstrap.sh "
        + "(it stages the published engines), then build the app again"
    case .needsNewerOS(let c, let need, let running):
      return "\(Self.displayName(c)) needs \(need) or later; this device runs \(running). "
        + "Load an Expression 2 avatar (engine: 'expression2') on this device"
    }
  }
}
