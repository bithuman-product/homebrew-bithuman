// Which engine a `load` names on Apple (shared/Classes/EngineSelection.swift, 2.6.36): an unknown name, or
// an engine the build does not carry, is refused by name instead of rendering Expression 2. Plain Swift, no
// Flutter, no engine: scripts/test_swift_unit.sh.
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
  if !ok { failures += 1; print("  FAIL (line \(line)) \(what)") } else { print("  PASS \(what)") }
}

// The same table as EngineRegistry.descriptors.
let ids = [
  EngineId(canonical: "expression2", aliases: ["embody", "expression-2"]),
  EngineId(canonical: "essence2", aliases: ["elevate", "essence-2", "essence-2-light", "essence-2-mobile"]),
]
let full: (String) -> Bool = { _ in true }
let noEssence2: (String) -> Bool = { $0 != "essence2" }

check(EngineSelection.resolve("expression2", among: ids, inBuild: full) == .engine("expression2"), "expression2")
check(EngineSelection.resolve("expression-2", among: ids, inBuild: full) == .engine("expression2"), "the public id expression-2")
check(EngineSelection.resolve("embody", among: ids, inBuild: full) == .engine("expression2"), "the old slug embody")
check(EngineSelection.resolve("essence2", among: ids, inBuild: full) == .engine("essence2"), "essence2")
check(EngineSelection.resolve("essence-2", among: ids, inBuild: full) == .engine("essence2"), "the public id essence-2")
check(EngineSelection.resolve("elevate", among: ids, inBuild: full) == .engine("essence2"), "the old slug elevate")
check(EngineSelection.resolve("essence2", among: ids, inBuild: full).errorMessage == nil, "a usable engine has no error")

// The Dart default until 2.6.36 ('essence') rendered Expression 2 on Apple without a word.
let unknown = EngineSelection.resolve("essence", among: ids, inBuild: full)
check(unknown == .unknown("essence") && unknown.canonical == nil, "'essence' names no engine: refused")
check(unknown.errorMessage?.contains("unknown engine 'essence'") == true
      && unknown.errorMessage?.contains("'expression2' or 'essence2'") == true, "its message names what to pass")
check(EngineSelection.resolve("", among: ids, inBuild: full) == .unknown(""), "an empty name: refused")

// A build where bootstrap did not stage Essence 2 rendered Expression 2 when asked for essence2.
let missing = EngineSelection.resolve("essence-2", among: ids, inBuild: noEssence2)
check(missing == .notInBuild("essence2") && missing.canonical == nil, "essence2 not in the build: refused")
check(missing.errorMessage?.contains("does not include the Essence 2 engine") == true
      && missing.errorMessage?.contains("scripts/bootstrap.sh") == true, "its message says how to fix the build")
check(EngineSelection.resolve("expression2", among: ids, inBuild: noEssence2) == .engine("expression2"),
      "expression2 still loads in that build")
check(EngineSelection.errorCode == "unsupported", "the code is Android's for an engine it cannot run")

if failures > 0 { print("engine_selection_test: \(failures) FAILED"); exit(1) }
print("engine_selection_test: all passed")
