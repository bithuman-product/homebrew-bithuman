// MODEL_REJECTED on Apple (shared/Classes/ModelRefusal.swift): which be_essence2_create answers and
// which Expression 2 warm-ups are the engine refusing its model file, and the message / details the
// plugin hands to Dart. Plain Swift, no Flutter, no engine: scripts/test_swift_unit.sh.
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
  if !ok { failures += 1; print("  FAIL (line \(line)) \(what)") } else { print("  PASS \(what)") }
}

// Essence 2: be_essence2_create's codes.
let sentence = "Renderer: REFUSED for identity 'A52DHS2219' (b1_fp32): published before the mouth-corner fix; download it again"
let out = BithumanModelRefusal.essence2(rc: -4, sentence: sentence, path: "/x/Caches/A52DHS2219.imx")
check(out != nil, "-4 (an out-of-date avatar file) is MODEL_REJECTED")
check(out?.engine == "essence2" && out?.nativeCode == -4, "engine + native code -4")
check(out?.message == "Essence 2 refused the model file (be_essence2_create -4) A52DHS2219.imx: \(sentence)",
      "the message carries the native code, the file and the engine's sentence")
check((out?.details["nativeCode"] as? Int) == -4 && (out?.details["engine"] as? String) == "essence2"
      && (out?.details["message"] as? String) == out?.message, "details = {engine, nativeCode, message}")
let unreadable = BithumanModelRefusal.essence2(rc: -2, sentence: "", path: "/x/a.imx")
check(unreadable?.nativeCode == -2 && unreadable?.message.contains("could not open") == true,
      "-2 (could not open the file) is MODEL_REJECTED, with a sentence when the engine gave none")
check(BithumanModelRefusal.essence2(rc: -7, sentence: "", path: "/x/a.imx")?.nativeCode == -7,
      "an unknown refusal code still reaches Dart with its number")
check(BithumanModelRefusal.essence2(rc: 0, sentence: "", path: "/x/a.imx") == nil, "0 opened: no refusal")
check(BithumanModelRefusal.essence2(rc: -3, sentence: "refusing to serve: no credits (402)", path: "/x/a.imx") == nil,
      "-3 (no authenticated session) is the credential's, not the model's")
check(BithumanModelRefusal.essence2(rc: -1, sentence: "", path: "") == nil, "-1 (a bad argument) is the caller's")

// Expression 2: a warm-up that returned without readiness, and no metering refusal.
let x2 = BithumanModelRefusal.expression2(warmed: true, isReady: false, meteringRefusal: nil, reason: nil)
check(x2?.engine == "expression2" && x2?.nativeCode == nil && x2?.details["nativeCode"] == nil,
      "a warm-up that could not load the files is MODEL_REJECTED (no native number)")
check(x2?.message.hasPrefix("Expression 2 refused the model files (warm-up did not finish): ") == true, "its message")
check(BithumanModelRefusal.expression2(warmed: false, isReady: false, meteringRefusal: nil, reason: nil) == nil,
      "still warming: not (yet) a refusal")
check(BithumanModelRefusal.expression2(warmed: true, isReady: true, meteringRefusal: nil, reason: nil) == nil,
      "ready: no refusal")
check(BithumanModelRefusal.expression2(warmed: true, isReady: false, meteringRefusal: "refusing to serve: 402", reason: nil) == nil,
      "metering refused: the credential's, not the model's")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
