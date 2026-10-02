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
