#!/bin/bash
# prove_dev_levers_release.sh — A RELEASE BUILD IGNORES EVERY DEV LEVER; A DEBUG BUILD KEEPS THEM.
#
# Compiles the Swift dev-lever door (packages/flutter-plugin/shared/Classes/DevLevers.swift)
# with a probe that prints every lever, twice: `-O` with no DEBUG condition (what
# `flutter build --release` and the pod's Release configuration compile) and `-Onone -DDEBUG`
# (the Pods project's Debug configuration). Both binaries run with EVERY lever set to a
# sentinel. Release must print the unset value for each; Debug must print the sentinel.
# Together with check_dev_levers.sh (every read goes through the door) this is the arm
# "set every lever on a release build, assert == unset" — on the one place the reads happen.
set -euo pipefail
cd "$(dirname "$0")/.."
DOOR=packages/flutter-plugin/shared/Classes/DevLevers.swift
T=$(mktemp -d "${TMPDIR:-/tmp}/devlevers.XXXXXX"); trap 'rm -rf "$T"' EXIT
cat > "$T/main.swift" <<'SWIFT'
import Foundation
let row = [
  "enabled=\(DevLevers.enabled)",
  "debugAudio=\(DevLevers.debugAudio)", "debugBarge=\(DevLevers.debugBarge)", "noVPIO=\(DevLevers.noVPIO)",
  "avatarDebug=\(DevLevers.avatarDebug)", "dumpFrames=\(DevLevers.dumpFrames)",
  "dumpDir=\(DevLevers.dumpDir ?? "nil")", "markerEverySeconds=\(DevLevers.markerEverySeconds)",
  "warmWav=\(DevLevers.warmWav ?? "nil")", "testAudio=\(DevLevers.testAudio)",
  "testWav=\(DevLevers.testWav ?? "nil")", "bench=\(DevLevers.bench)",
]
print(row.joined(separator: " "))
SWIFT
UNSET='enabled=false debugAudio=false debugBarge=false noVPIO=false avatarDebug=false dumpFrames=false dumpDir=nil markerEverySeconds=0.0 warmWav=nil testAudio=false testWav=nil bench=false'
LEVERS=(BITHUMAN_DEBUG_AUDIO=1 BITHUMAN_DEBUG_BARGE=true BITHUMAN_NO_VPIO=1 BH_AVATAR_DEBUG=1 EMBODY_DUMP_FRAMES=1 EMBODY_DUMP_DIR=/SENTINEL_dump EMBODY_MARKER_EVERY=2 EMBODY_WARM_WAV=/SENTINEL_warm.wav EMBODY_TEST_AUDIO=1 EMBODY_TEST_WAV=/SENTINEL_test.wav EMBODY_BENCH=1)
swiftc -O "$DOOR" "$T/main.swift" -o "$T/release" 2>&1 | grep -v warning || true
swiftc -Onone -DDEBUG "$DOOR" "$T/main.swift" -o "$T/debug" 2>&1 | grep -v warning || true
[ -x "$T/release" ] && [ -x "$T/debug" ] || { echo "::error::swiftc failed"; exit 1; }
REL=$(env "${LEVERS[@]}" "$T/release"); DBG=$(env "${LEVERS[@]}" "$T/debug"); BARE=$("$T/release")
echo "release, every lever set : $REL"
echo "release, nothing set     : $BARE"
echo "debug,   every lever set : $DBG"
[ "$REL" = "$UNSET" ] || { echo "::error::a RELEASE build honoured a dev lever (expected: $UNSET)"; exit 1; }
[ "$REL" = "$BARE" ] || { echo "::error::release output differs with levers set vs unset"; exit 1; }
for want in 'enabled=true' 'noVPIO=true' 'dumpDir=/SENTINEL_dump' 'markerEverySeconds=2.0' 'testWav=/SENTINEL_test.wav' 'bench=true'; do
  case "$DBG" in *"$want"*) ;; *) echo "::error::the DEBUG build did not read '$want' — the door is dead in debug too (a gate that cannot pass is decoration)"; exit 1 ;; esac
done
echo "OK: release ignores all ${#LEVERS[@]} levers (output == unset); debug reads them"
