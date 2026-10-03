// EngineSelection.swift — which engine a `load` names, decided before anything is created (2.6.36).
//
// Until 2.6.35 a name the registry did not know (the Dart default `'essence'` among them), and
// `essence2` in a build that does not carry the Essence 2 engine, both rendered Expression 2 without a
// word: the app asked for one character and showed another. Now `load` fails with the code Android
// answers for an engine it cannot run (`unsupported`) and a message that says what to do.
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

  /// The FlutterError code, the same as Android's for an engine it cannot run.
  static let errorCode = "unsupported"

  /// Resolve [slug] against [ids] (canonical or alias); [inBuild] says whether a canonical slug's engine
  /// is linked into this build.
  static func resolve(_ slug: String, among ids: [EngineId], inBuild: (String) -> Bool) -> EngineSelection {
    guard let id = ids.first(where: { $0.matches(slug) }) else { return .unknown(slug) }
    return inBuild(id.canonical) ? .engine(id.canonical) : .notInBuild(id.canonical)
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
      let name = c == "essence2" ? "Essence 2" : c == "expression2" ? "Expression 2" : c
      return "this build does not include the \(name) engine: run the plugin's scripts/bootstrap.sh "
        + "(it stages the published engines), then build the app again"
    }
  }
}
