#!/bin/bash
# Plain-Swift unit tests of the Apple half's platform-free parts (test/swift), on any Mac with a Swift
# toolchain — no Flutter, no engine binaries:
#   packages/flutter-plugin/scripts/test_swift_unit.sh
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cp test/swift/model_refusal_test.swift "$T/main.swift"     # top-level test code: main.swift
swiftc -O -module-name ModelRefusalTest -o "$T/model_refusal" shared/Classes/ModelRefusal.swift "$T/main.swift"
"$T/model_refusal"
# The voice on its own clock (Essence 2, 2.6.30): VoiceClock.swift on its own.
mkdir -p "$T/vc"; cp test/swift/voice_clock_test.swift "$T/vc/main.swift"
swiftc -O -module-name VoiceClockTest -o "$T/voice_clock" shared/Classes/VoiceClock.swift "$T/vc/main.swift"
"$T/voice_clock"
