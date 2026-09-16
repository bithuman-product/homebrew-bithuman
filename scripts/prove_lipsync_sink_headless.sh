#!/bin/bash
# prove_lipsync_sink_headless.sh — THE VOICE↔RENDER EDGE COMPILES WITH NO RENDER IN IT.
#
# Builds Protocol/LipsyncSink.swift together with a conformer that is not the avatar
# texture and holds nothing of render at all, plus the shape RealtimeAudioIO holds it
# in (`weak var lipsyncSink: LipsyncSink?`), and RUNS it: nil must be a working state,
# a push with no sink must be a no-op, and a non-render type must satisfy the whole
# protocol. If `weak` stops compiling the protocol lost `: AnyObject`; if the conformer
# stops compiling the edge grew a member only the texture can supply.
#
# ★This is the ONLY compiled arm on packages/flutter-plugin's Swift. Nothing else in
# this repository's CI builds those sources (measured 2026-09-16) — swift-package.yml
# builds a different package, and prove_dev_levers_release.sh compiles DevLevers.swift
# alone. RealtimeAudioIO.swift and BithumanAvatarPlugin.swift cannot be compiled here:
# they need the Flutter / FlutterMacOS modules, which arrive only with a real pod build
# on a Mac. Whoever next opens this on a Mac: `flutter build macos` in the app is what
# grades the other half.
set -euo pipefail
cd "$(dirname "$0")/.."
P=packages/flutter-plugin/shared/Classes/Protocol/LipsyncSink.swift
[ -f "$P" ] || { echo "::error::$P is missing — the protocol is the subject of this arm"; exit 1; }
command -v swiftc >/dev/null || { echo "::error::no swiftc — this arm cannot look, and must not report green"; exit 1; }
T=$(mktemp -d "${TMPDIR:-/tmp}/lipsync.XXXXXX"); trap 'rm -rf "$T"' EXIT HUP INT TERM
cat > "$T/main.swift" <<'SWIFT'
import Foundation

/// A sink with NO render in it: the proof that `LipsyncSink` is satisfiable by
/// something that is not the avatar texture. Voice can therefore be stood up,
/// driven and tested with no engine, no texture and no pixels.
final class HeadlessSink: LipsyncSink {
  var usesStartGate: Bool { false }
  var startGateEngineReady: Bool { false }
  var speechFramesPublished: Int { 0 }
  var audioReleaseSeconds: Double { 0.05 }
  var onSpeechFramePublished: (() -> Void)?
  var canReleaseSpeechAudio: (() -> Bool)?
  var markerOnNextRelease = false
  private(set) var bytes = 0
  private(set) var paused = false
  private(set) var cleared = 0
  func setLipsyncPaused(_ p: Bool) { paused = p }
  func clearAudioQueue() { cleared += 1 }
  func noteUtteranceAudioStarted() {}
  func enqueuePCM(_ data: Data) { bytes += data.count }
  func onTurnEnd() {}
}

/// The shape `RealtimeAudioIO` holds the sink in. `weak` is what requires the
/// protocol to be class-bound; `nil` is a voice session with no avatar.
final class VoiceUnitShape {
  weak var lipsyncSink: LipsyncSink?
  var headless: Bool { lipsyncSink == nil }
  func pushLipsync(_ d: Data) { lipsyncSink?.enqueuePCM(d) }
  func barge() { lipsyncSink?.setLipsyncPaused(false); lipsyncSink?.clearAudioQueue() }
  func releaseSeconds() -> Double { lipsyncSink?.audioReleaseSeconds ?? 0.05 }
}

let v = VoiceUnitShape()
precondition(v.headless, "a voice unit with no sink must report headless")
v.pushLipsync(Data(count: 320))          // no sink: a no-op, not a crash
v.barge()                                 // a barge with no avatar must also be a no-op
precondition(v.releaseSeconds() == 0.05, "the no-sink default release quantum is gone")
let s = HeadlessSink()
v.lipsyncSink = s
precondition(!v.headless)
v.pushLipsync(Data(count: 320))
v.barge()
precondition(s.bytes == 320, "the sink did not receive the lipsync bytes")
precondition(s.cleared == 1 && !s.paused, "the barge did not reach the sink")
print("OK: LipsyncSink compiles, is weak-holdable, nil is a working state, and a NON-RENDER type satisfies all of it")
SWIFT
swiftc -O "$P" "$T/main.swift" -o "$T/arm" 2>&1 | grep -v warning || true
[ -x "$T/arm" ] || { echo "::error::swiftc could not build the protocol together with a non-render conformer"; exit 1; }
"$T/arm"
