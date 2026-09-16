#!/bin/bash
# check_dev_levers.sh — DEV LEVERS HAVE ONE DOOR PER LANGUAGE, AND A RELEASE BUILD HAS NO KEY.
#
# ★WHY (2026-09-15/16). A persistent Android sysprop — our own A/V sync marker — painted every
# 40th speech unit WHITE with a click on every build after it, release included (#41 gated it on
# FLAG_DEBUGGABLE). A proof APK with BITHUMAN_DEV_STRESS + BH_MIC_FILE sat on the owner's phone
# ("the agent starts self talking non-stop"). The Apple plugin read 15 env vars in every build,
# EMBODY_MARKER_EVERY (the marker's Apple twin) and BITHUMAN_NO_VPIO (removes the canceller)
# among them. A dev lever a release build honours is a customer defect.
#
# THE RULE, per language, as a build-config check (not a runtime `if` per lever):
#   Swift   every environment read goes through shared/Classes/DevLevers.swift, whose one
#           read is `#if DEBUG` — a Release build (no DEBUG condition) returns nil for every name.
#   Dart    every `--dart-define` goes through lib/src/dev_levers.dart, where each lever is
#           `enabled && …` / `enabled ? …` with `enabled = !kReleaseMode` — a compile-time
#           constant, so `flutter build --release` folds every lever away.
#   Kotlin  every sysprop read goes through AvatarPlayer.devInt(), consulted only when the host
#           app's manifest is FLAG_DEBUGGABLE (BithumanPlugin.kt), and nothing reads System.getenv.
#   Echo    the server_vad threshold has ONE writer, lib/src/echo_profile.dart — no other
#           numeric `'threshold':` literal in lib/ (three constants in three files was the
#           defect that put 0.5 on a device that needed 0.7).
#
# Fires red on any read outside its door, on a door that lost its build-config guard, on an
# ungated lever inside the Dart door, and on a second threshold writer. The workflow runs a
# negative control on each (a stray read, a stripped guard) and demands red.
set -uo pipefail
cd "$(dirname "$0")/.."
P=packages/flutter-plugin
BAD=0
err() { echo "::error::$*"; BAD=$((BAD+1)); }

# ── Swift: one door ────────────────────────────────────────────────────────────────────────
SW_DOOR=$P/shared/Classes/DevLevers.swift
[ -f "$SW_DOOR" ] || err "missing $SW_DOOR — the Swift dev-lever door is gone"
while IFS=: read -r f n rest; do
  [ -n "${f:-}" ] || continue
  case "$f" in "$SW_DOOR") continue ;; esac
  err "file=$f,line=$n::environment read outside DevLevers.swift: ${rest}"
done < <(grep -rnE 'ProcessInfo\.processInfo\.environment|getenv\(|NSHomeDirectory\(\)' "$P/shared/Classes" "$P/macos/Classes" "$P/ios/Classes" 2>/dev/null | grep -v '^Binary' | sort -u || true)
if [ -f "$SW_DOOR" ]; then
  # the one read must sit under #if DEBUG with a release branch that returns nil
  if ! awk '/static func env\(/{f=1} f&&/#if DEBUG/{d=1} f&&d&&/#else/{e=1} f&&d&&e&&/return nil/{ok=1} f&&/^  }/{exit} END{exit !ok}' "$SW_DOOR"; then
    err "file=$SW_DOOR::DevLevers.env must read the environment under #if DEBUG and return nil otherwise"
  fi
  N_SW=$(grep -vE '^\s*(//|///)' "$SW_DOOR" | grep -cE 'ProcessInfo\.processInfo\.environment\[')
  [ "$N_SW" = 1 ] || err "file=$SW_DOOR::expected exactly ONE environment read in the door, found $N_SW"
fi
for lnk in "$P/ios/Classes/DevLevers.swift" "$P/macos/Classes/DevLevers.swift"; do
  [ -L "$lnk" ] || err "missing symlink $lnk — the podspec source glob will not compile the door on that platform"
done

# ── Dart: one door, every lever gated ──────────────────────────────────────────────────────
DT_DOOR=$P/lib/src/dev_levers.dart
[ -f "$DT_DOOR" ] || err "missing $DT_DOOR — the Dart dev-lever door is gone"
while IFS=: read -r f n rest; do
  [ -n "${f:-}" ] || continue
  case "$f" in "$DT_DOOR") continue ;; esac
  err "file=$f,line=$n::fromEnvironment outside dev_levers.dart: ${rest}"
done < <(grep -rnE '\.fromEnvironment\(' "$P/lib" 2>/dev/null | sort -u || true)
if [ -f "$DT_DOOR" ]; then
  grep -qE 'static const bool enabled = !kReleaseMode;' "$DT_DOOR" \
    || err "file=$DT_DOOR::'enabled' must be exactly '!kReleaseMode' (a compile-time constant)"
  # every fromEnvironment must be on a line, or the continuation of a line, guarded by `enabled`
  while IFS=: read -r n rest; do
    [ -n "${n:-}" ] || continue
    ctx=$(sed -n "$((n-1)),${n}p" "$DT_DOOR" | tr '\n' ' ')
    echo "$ctx" | grep -qE 'enabled (&&|\?)' || err "file=$DT_DOOR,line=$n::lever not guarded by 'enabled &&' / 'enabled ?': ${rest}"
  done < <(grep -nE '\.fromEnvironment\(' "$DT_DOOR" | grep -v "dart.vm.product" || true)
fi

# ── Kotlin: the FLAG_DEBUGGABLE gate (#41) ─────────────────────────────────────────────────
KT=$P/android/src/main/kotlin/ai/bithuman/flutter
grep -rqE 'ApplicationInfo\.FLAG_DEBUGGABLE' "$KT/BithumanPlugin.kt" || err "BithumanPlugin.kt no longer computes FLAG_DEBUGGABLE"
grep -rnE 'System\.getenv\(' "$KT" && err "Kotlin reads System.getenv — an env is not a debug-gated door"
# every CALL of devInt() sits on a line that consults `debuggable`; the reflection on
# SystemProperties exists once, inside devInt() itself
while IFS=: read -r f n rest; do
  [ -n "${f:-}" ] || continue
  echo "$rest" | grep -qE 'debuggable' || err "file=$f,line=$n::devInt() call not gated on 'debuggable': ${rest}"
done < <(grep -rnE '\bdevInt\(' "$KT" | grep -vE 'fun devInt' | grep -vE '^\S+:[0-9]+:\s*(//|\*|/\*)' || true)
N_SP=$(grep -rE 'SystemProperties' "$KT" | grep -vE ':\s*(//|\*|/\*)' | wc -l | tr -d ' ')
[ "$N_SP" = 1 ] || err "expected exactly ONE SystemProperties read (inside devInt) in $KT, found $N_SP"
awk '/fun devInt\(/{f=NR} f&&NR>f&&NR<=f+6&&/SystemProperties/{ok=1} END{exit !ok}' "$KT/AvatarPlayer.kt" \
  || err "the SystemProperties read is not inside devInt()"

# ── Echo: one threshold writer ─────────────────────────────────────────────────────────────
while IFS=: read -r f n rest; do
  [ -n "${f:-}" ] || continue
  err "file=$f,line=$n::a numeric server_vad threshold outside echo_profile.dart: ${rest}"
done < <(grep -rnE "'threshold':\s*[0-9]" "$P/lib" || true)
grep -qE "serverVadThreshold: 0\.[0-9]" "$P/lib/src/echo_profile.dart" 2>/dev/null || err "echo_profile.dart carries no row — the table is empty"
grep -rnE 'isVoiceProcessingAGCEnabled = (true|false)' "$P/shared/Classes" | grep -v 'if !vpioAgc' && err "AGC set by a literal in Swift — the table row decides"

if [ "$BAD" -gt 0 ]; then echo "FAIL: $BAD dev-lever door violation(s)"; exit 1; fi
echo "OK: Swift env reads=1 (DevLevers.swift, #if DEBUG); Dart fromEnvironment only in dev_levers.dart, every lever gated on !kReleaseMode; Kotlin sysprops behind FLAG_DEBUGGABLE; one server_vad writer (echo_profile.dart)"
