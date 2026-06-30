#!/usr/bin/env bash
# run_all.sh — the bitHuman Flutter app's automated, simulator-first e2e
# harness. One command runs Tier 1 (pure-Dart logic) + Tier 2 (real app on
# simulators with the hermetic mock voice backend) and prints a summary
# table an agent can parse headlessly. No OpenAI calls, no secrets.
#
# Usage:
#   e2e/run_all.sh                       # tier1 + every reachable sim target
#   E2E_TARGETS=tier1,macos e2e/run_all.sh
#   E2E_TARGETS=ios e2e/run_all.sh       # one target
#   E2E_TARGETS=android e2e/run_all.sh   # boots the arm64 emulator (heavy)
#   E2E_TARGETS=gate e2e/run_all.sh      # THE RIGOROUS SIMULATION GATE:
#            tier1 + macOS flow + macOS/iOS-sim/Android-emu regression
#            scenarios with measured asserts (e2e/scenarios/gate_metrics.py)
#            + a merged gate-metrics.json measurement artifact.
#
# Targets:
#   tier1    flutter test test/                      (fast; no device)
#   macos    full session flow + engine on the host  (mock WS voice backend)
#   ios      boot smoke + engine on an iPhone sim    (elevatedir staged from
#            the host filesystem — sim apps can read host paths)
#   android  boot smoke on the arm64 emulator        (graceful-failure UI
#            profile by default — hermetic, no bundle download; stage a
#            le-bundle via E2E_ANDROID_BUNDLE for the full engine path)
#   macos_scn    gate scenarios on macOS: mic-on idle stability + storm/
#                barge lifecycle, native log truth via unified log
#   ios_scn      the same two scenarios on the iPhone sim (WS forced via
#                debugEndpointOverride; engine = idle-only there, boundary
#                documented in e2e/scenarios/README.md)
#   android_scn  drive-loop soak on the emulator: pacing truth (±2% wall
#                clock), mouth-gate flip latency, governor sanity
#                (feature-detected; SKIPPED loudly pre-task48)
#
# Env knobs:
#   E2E_ELEVATE_SRC      host path to a <agent>.elevatedir for iOS staging
#                        (default: the v3 A63 bundle in _elevate_proof, then
#                        the macOS app container cache)
#   E2E_ACTOR_SRC        host path to the Expression actor .bhx the elevate
#                        engine needs alongside the elevatedir (default:
#                        ~/.cache/bithuman/expression/…int4.bhx, then the
#                        macOS app container cache). iOS sim: symlinked into
#                        the app container by the boot smoke test.
#   E2E_ANDROID_BUNDLE   host path to an Android le-bundle dir; when set the
#                        Android target pushes it (adb root) and runs the
#                        engine smoke + mouth-gate logcat asserts
#   E2E_LOAD_BUDGET_S    engine warm-up budget (default 240/300 in-tests)
#   E2E_KEEP_BOOTED=1    leave sims/emulators running afterwards
#
# Exit: 0 only if every selected target passed (skips don't fail the run).
#
# Apache-2.0; (c) bitHuman.

set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE_DIR="$HERE/../example"
OUT_DIR="${OUT_DIR:-/tmp/bithuman-e2e-harness}"
METRICS_DIR="$OUT_DIR/metrics"
mkdir -p "$OUT_DIR" "$METRICS_DIR"
GATE_METRICS="$HERE/scenarios/gate_metrics.py"

TARGETS="${E2E_TARGETS:-tier1,macos,ios}"
# The gate meta-target = the authoritative rigorous-simulation pass.
[ "$TARGETS" = "gate" ] && TARGETS="tier1,macos,macos_scn,ios_scn,android_scn"

# Hermetic defines shared by every Tier 2 profile. OPENAI_API_KEY is a FAKE
# value (never a real key): it keeps the app off the ephemeral-token backend
# and the mock server accepts any Bearer.
COMMON_DEFINES=(
  --dart-define=DEV_AUTH_BYPASS=true
  --dart-define=OPENAI_API_KEY=e2e-mock-key
)

# Default iOS/macOS elevate source: prefer the dev v3 elevatedir, fall back
# to the macOS app container's delivered cache.
DEFAULT_V3="$HOME/bithuman/_elevate_proof/A63GVG1577/A63GVG1577_v3.elevatedir"
CONTAINER_CACHE="$HOME/Library/Application Support/ai.bithuman.app/elevate/A63GVG1577.elevatedir"
if [ -z "${E2E_ELEVATE_SRC:-}" ]; then
    if [ -d "$DEFAULT_V3" ]; then E2E_ELEVATE_SRC="$DEFAULT_V3"
    elif [ -d "$CONTAINER_CACHE" ]; then E2E_ELEVATE_SRC="$CONTAINER_CACHE"
    else E2E_ELEVATE_SRC=""; fi
fi

# Expression actor model (.bhx) — elevate needs it in addition to the
# elevatedir. Prefer the user cache, fall back to the macOS app container's
# downloaded copy.
DEFAULT_BHX="$HOME/.cache/bithuman/expression/expression-engine-1.0-int4.bhx"
CONTAINER_BHX="$HOME/Library/Containers/ai.bithuman.app/Data/.cache/bithuman/expression/expression-engine-1.0-int4.bhx"
if [ -z "${E2E_ACTOR_SRC:-}" ]; then
    if [ -f "$DEFAULT_BHX" ]; then E2E_ACTOR_SRC="$DEFAULT_BHX"
    elif [ -f "$CONTAINER_BHX" ]; then E2E_ACTOR_SRC="$CONTAINER_BHX"
    else E2E_ACTOR_SRC=""; fi
fi

result_tier1="skip"; result_macos="skip"; result_ios="skip"; result_android="skip"
result_macos_scn="skip"; result_ios_scn="skip"; result_android_scn="skip"

# GUI-launching legs (macOS app windows, iOS Simulator, Android emulator) are
# OPT-IN: they pop windows and play fixture audio on the host desktop, which
# the user has asked not to happen unattended (2026-06-11). Set E2E_ALLOW_GUI=1
# to run them (coordinate with the user, or wait for BITHUMAN_TEST_HEADLESS).
# Tier 1 (pure `flutter test`, no GUI) always runs.
if [ "${E2E_ALLOW_GUI:-0}" != "1" ]; then
    _kept=""
    for leg in $(printf '%s' "$TARGETS" | tr ',' ' '); do
        case " macos ios android macos_scn ios_scn android_scn " in
            *" $leg "*)
                eval "result_$leg=\"SKIP (GUI leg; set E2E_ALLOW_GUI=1)\"" ;;
            *)  _kept="${_kept:+$_kept,}$leg" ;;
        esac
    done
    TARGETS="$_kept"
fi

want() { case ",${TARGETS}," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

note() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

# Run gate_metrics.py and fold its exit into a leg result variable name
# passed by reference: 0 keeps the current value, 1 forces FAIL, 3 records
# a LOUD skip (does not fail the leg but is shown in the summary).
metric() { # metric <scenario> <logfile> <out.json> [extra args…]
    local scen="$1" log="$2" out="$3"; shift 3
    python3 "$GATE_METRICS" "$scen" --log "$log" --out "$out" "$@"
}

# ────────────────────────────────────────────────────────── Tier 1
run_tier1() {
    want tier1 || return 0
    note "TIER 1 — widget/unit (test/)"
    ( cd "$EXAMPLE_DIR" && flutter test test/ ) 2>&1 | tee "$OUT_DIR/tier1.log" | tail -3
    if grep -q "All tests passed" "$OUT_DIR/tier1.log"; then result_tier1="pass"
    else result_tier1="FAIL"; fi
}

# ────────────────────────────────────────────────────────── macOS
run_macos() {
    want macos || return 0
    note "TIER 2 — macOS (full session flow vs mock realtime)"
    cd "$EXAMPLE_DIR" || { result_macos="FAIL"; return; }
    flutter test integration_test/e2e_session_flow_test.dart -d macos \
        "${COMMON_DEFINES[@]}" \
        --dart-define=BITHUMAN_ENGINE=elevate \
        > "$OUT_DIR/macos-flow.log" 2>&1
    local rc=$?
    tail -5 "$OUT_DIR/macos-flow.log"
    # Informational: native NSLog markers usually DON'T reach the flutter
    # test runner's stdout on macOS desktop, so their absence is not a
    # failure — but when present they corroborate the engine/voice path.
    grep -q "elevate-av.*first frame" "$OUT_DIR/macos-flow.log" \
        && echo "  info: native '[elevate-av] first frame' marker present"
    grep -q "\[realtime\] ws closed" "$OUT_DIR/macos-flow.log" \
        && echo "  info: '[realtime] ws closed' marker present"
    if [ $rc -eq 0 ] && grep -q "All tests passed" "$OUT_DIR/macos-flow.log"; then
        result_macos="pass"
    else
        result_macos="FAIL"
        echo "  full log: $OUT_DIR/macos-flow.log"
    fi
}

# ────────────────────────────────────────────────────────── iOS sim
run_ios() {
    want ios || return 0
    note "TIER 2 — iOS Simulator (boot smoke + staged elevate engine)"
    # Probe: libessence2/libconverse xcframeworks must carry an ios-simulator
    # slice (vendored since 2026-06-11 — ios-arm64-simulator, arm64-only; see
    # bithuman-sdk engine/{elevate,converse}/build-xcframework.sh). On a
    # checkout bootstrapped against an older SDK vendor drop the slice is
    # missing and ANY simulator build of the plugin fails in the Pods rsync
    # phase — auto-skip with the reason instead.
    if ! ls -d "$HERE/../ios/Frameworks/libessence2.xcframework/"ios-arm64*-simulator >/dev/null 2>&1; then
        echo "  SKIP: libessence2.xcframework has no ios-simulator slice"
        echo "        (re-vendor from bithuman-sdk: engine/elevate/build-xcframework.sh)"
        result_ios="skip (no sim slice)"
        return
    fi
    if [ -z "$E2E_ELEVATE_SRC" ]; then
        echo "  no elevatedir found to stage (set E2E_ELEVATE_SRC) — skipping"
        return
    fi
    local udid booted_by_us=0
    udid=$(xcrun simctl list devices booted 2>/dev/null \
        | awk '/iPhone/ {print $(NF-1)}' | tr -d '()' | head -1)
    if [ -z "$udid" ]; then
        udid=$(xcrun simctl list devices available 2>/dev/null \
            | awk '/iPhone 17 Pro \(/ {print $(NF-1)}' | tr -d '()' | tail -1)
        [ -n "$udid" ] && { xcrun simctl boot "$udid"; booted_by_us=1; sleep 8; }
    fi
    if [ -z "$udid" ]; then
        echo "  no iPhone simulator available — skipping"; return
    fi
    if [ -z "$E2E_ACTOR_SRC" ]; then
        echo "  WARN: no Expression actor .bhx found (set E2E_ACTOR_SRC) —"
        echo "        elevate create will fail on a fresh sim container"
    fi
    echo "  sim: $udid (staging $E2E_ELEVATE_SRC via config.json)"
    cd "$EXAMPLE_DIR" || { result_ios="FAIL"; return; }
    local log_start
    log_start=$(date '+%Y-%m-%d %H:%M:%S')
    flutter test integration_test/e2e_boot_smoke_test.dart -d "$udid" \
        "${COMMON_DEFINES[@]}" \
        --dart-define=BITHUMAN_ENGINE=elevate \
        --dart-define=E2E_ELEVATE_SRC="$E2E_ELEVATE_SRC" \
        --dart-define=E2E_ACTOR_SRC="$E2E_ACTOR_SRC" \
        > "$OUT_DIR/ios-boot.log" 2>&1
    local rc=$?
    tail -5 "$OUT_DIR/ios-boot.log"
    # Native-marker asserts: the in-process test can only see widgets (a
    # Texture exists even when engine create fails), but the sim's unified
    # log reliably carries the plugin's NSLogs — REQUIRE engine truth there.
    local nlog="$OUT_DIR/ios-native.log" native_ok=1
    xcrun simctl spawn "$udid" log show --start "$log_start" \
        --predicate 'processImagePath CONTAINS "Runner"' --style compact \
        > "$nlog" 2>/dev/null
    if grep -q "be_essence2_create failed" "$nlog"; then
        echo "  FAIL: native be_essence2_create failed (see $nlog)"; native_ok=0
    fi
    if grep -q "first frame" "$nlog"; then
        echo "  info: native first-frame marker present"
    else
        echo "  FAIL: no native first-frame marker in sim log ($nlog)"; native_ok=0
    fi
    if [ $rc -eq 0 ] && [ $native_ok -eq 1 ] \
        && grep -q "All tests passed" "$OUT_DIR/ios-boot.log"; then
        result_ios="pass"
    else
        result_ios="FAIL"; echo "  full log: $OUT_DIR/ios-boot.log"
    fi
    if [ $booted_by_us -eq 1 ] && [ "${E2E_KEEP_BOOTED:-0}" != "1" ]; then
        xcrun simctl shutdown "$udid" >/dev/null 2>&1
    fi
}

# ────────────────────────────────────────────────────────── Android emulator
run_android() {
    want android || return 0
    note "TIER 2 — Android emulator (arm64)"
    local SDK="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
    local EMU="$SDK/emulator/emulator" ADB="$SDK/platform-tools/adb"
    local AVD="${E2E_AVD:-bench-arm64}"
    if ! "$EMU" -list-avds 2>/dev/null | grep -qx "$AVD"; then
        echo "  AVD '$AVD' not found — create one, e.g.:"
        echo "    sdkmanager 'system-images;android-34;google_apis;arm64-v8a'"
        echo "    avdmanager create avd -n $AVD -k 'system-images;android-34;google_apis;arm64-v8a'"
        return
    fi
    local started_by_us=0
    if ! "$ADB" get-state >/dev/null 2>&1; then
        echo "  booting $AVD headless…"
        "$EMU" -avd "$AVD" -no-window -no-audio -no-boot-anim -netfast \
            > "$OUT_DIR/android-emulator.log" 2>&1 &
        started_by_us=1
        "$ADB" wait-for-device
        local i=0
        until [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do
            sleep 3; i=$((i+1)); [ $i -gt 100 ] && { echo "  emulator boot timeout"; result_android="FAIL"; return; }
        done
    fi
    "$ADB" logcat -c 2>/dev/null
    cd "$EXAMPLE_DIR" || { result_android="FAIL"; return; }

    local SERIAL
    SERIAL=$("$ADB" devices | awk '/^emulator-/ {print $1; exit}')
    [ -z "$SERIAL" ] && { echo "  no emulator serial found"; result_android="FAIL"; return; }

    if [ -n "${E2E_ANDROID_BUNDLE:-}" ] && [ -d "${E2E_ANDROID_BUNDLE}" ]; then
        # Full engine path: push the le-bundle to /data/local/tmp (world-
        # readable; validated app-readable on the API-29 google_apis image —
        # if a newer image SELinux-denies it, stage inside the app data dir
        # with adb root + chown + restorecon instead, see e2e/README.md),
        # then: engine smoke (le_core JNI + setSpeaking) → full-app boot
        # smoke (elevate via config.json) → mouth-gate logcat assert.
        local DEV_BUNDLE=/data/local/tmp/e2e/bundle
        # NB: ${braces} or ASCII required next to variables — bash 3.2 (macOS)
        # folds an adjacent multibyte char into the name and dies under set -u.
        echo "  pushing le-bundle to ${DEV_BUNDLE}..."
        "$ADB" -s "$SERIAL" shell mkdir -p /data/local/tmp/e2e >/dev/null 2>&1
        "$ADB" -s "$SERIAL" push "${E2E_ANDROID_BUNDLE}" "$DEV_BUNDLE" >/dev/null \
            || { echo "  adb push failed"; result_android="FAIL"; return; }
        "$ADB" -s "$SERIAL" shell chmod -R a+rX /data/local/tmp/e2e
        flutter test integration_test/engine_smoke_test.dart -d "$SERIAL" \
            "${COMMON_DEFINES[@]}" \
            --dart-define=E2E_BUNDLE=$DEV_BUNDLE \
            > "$OUT_DIR/android-engine.log" 2>&1
        local rc=$?
        tail -3 "$OUT_DIR/android-engine.log"
        flutter test integration_test/e2e_boot_smoke_test.dart -d "$SERIAL" \
            "${COMMON_DEFINES[@]}" \
            --dart-define=BITHUMAN_ENGINE=elevate \
            --dart-define=E2E_ELEVATE_SRC=$DEV_BUNDLE \
            > "$OUT_DIR/android-boot.log" 2>&1
        local rc2=$?
        tail -3 "$OUT_DIR/android-boot.log"
        "$ADB" -s "$SERIAL" logcat -d > "$OUT_DIR/android-logcat.log" 2>/dev/null
        local gate_ok=1
        grep -q "mode -> TALKING" "$OUT_DIR/android-logcat.log" || {
            echo "  WARN: no 'mode -> TALKING' flip in logcat"; gate_ok=0; }
        grep -q "mode -> IDLE" "$OUT_DIR/android-logcat.log" || {
            echo "  WARN: no 'mode -> IDLE' flip in logcat"; gate_ok=0; }
        if [ $rc -eq 0 ] && [ $rc2 -eq 0 ] \
            && grep -q "All tests passed" "$OUT_DIR/android-engine.log" \
            && grep -q "All tests passed" "$OUT_DIR/android-boot.log" \
            && [ $gate_ok -eq 1 ]; then result_android="pass"
        else result_android="FAIL"; echo "  logs: $OUT_DIR/android-{engine,boot}.log"; fi
    else
        # Hermetic no-engine UI profile: unroutable catalog URL → the app
        # must surface the graceful Failed + Retry state (never a spinner).
        flutter test integration_test/e2e_boot_smoke_test.dart -d "$("$ADB" get-serialno)" \
            "${COMMON_DEFINES[@]}" \
            --dart-define=BITHUMAN_ENGINE=elevate \
            --dart-define=ELEVATE_CATALOG_URL=http://127.0.0.1:9/catalog.json \
            --dart-define=E2E_EXPECT_FAILURE=true \
            > "$OUT_DIR/android-boot.log" 2>&1
        local rc=$?
        tail -5 "$OUT_DIR/android-boot.log"
        if [ $rc -eq 0 ] && grep -q "All tests passed" "$OUT_DIR/android-boot.log"; then
            result_android="pass"
        else
            result_android="FAIL"; echo "  full log: $OUT_DIR/android-boot.log"
        fi
    fi

    if [ $started_by_us -eq 1 ] && [ "${E2E_KEEP_BOOTED:-0}" != "1" ]; then
        "$ADB" emu kill >/dev/null 2>&1
    fi
}

# ─────────────────────────────────────── GATE scenarios: macOS (engine truth)
# Scenario 1 (mic-on idle stability) + scenario 2 (storm/silence/stuck-gate)
# with the FULL speech path — the macOS leg is where the Darwin engine truth
# (gate release, queue bound, A/V skew) is measured. Native NSLogs are
# captured by the TEST ITSELF (dup2 of the app's stderr — see
# integration_test/native_log_capture.dart; the unified log redacts NSLog
# bodies as <private> on macOS and the flutter tool swallows app stderr).
run_macos_scn() {
    want macos_scn || return 0
    note "GATE — macOS scenarios (idle stability + storm lifecycle)"
    if [ -z "$E2E_ELEVATE_SRC" ]; then
        echo "  SKIP: no elevatedir found (set E2E_ELEVATE_SRC)"; return
    fi
    cd "$EXAMPLE_DIR" || { result_macos_scn="FAIL"; return; }
    local soak="${E2E_IDLE_SOAK_S:-60}" ok=1

    : > "$OUT_DIR/macos-idle-native.log"
    flutter test integration_test/e2e_idle_stability_test.dart -d macos \
        "${COMMON_DEFINES[@]}" \
        --dart-define=E2E_BUNDLE="$E2E_ELEVATE_SRC" \
        --dart-define=E2E_IDLE_SOAK_S="$soak" \
        --dart-define=E2E_NATIVE_LOG="$OUT_DIR/macos-idle-native.log" \
        > "$OUT_DIR/macos-idle.log" 2>&1
    local rc=$?
    tail -3 "$OUT_DIR/macos-idle.log"
    cat "$OUT_DIR/macos-idle.log" "$OUT_DIR/macos-idle-native.log" \
        > "$OUT_DIR/macos-idle-combined.log"
    metric darwin-idle "$OUT_DIR/macos-idle-combined.log" \
        "$METRICS_DIR/macos-idle.json"
    local mrc=$?
    { [ $rc -ne 0 ] || ! grep -q "All tests passed" "$OUT_DIR/macos-idle.log" \
        || [ $mrc -eq 1 ]; } && ok=0

    : > "$OUT_DIR/macos-storm-native.log"
    flutter test integration_test/e2e_storm_lifecycle_test.dart -d macos \
        "${COMMON_DEFINES[@]}" \
        --dart-define=E2E_BUNDLE="$E2E_ELEVATE_SRC" \
        --dart-define=E2E_NATIVE_LOG="$OUT_DIR/macos-storm-native.log" \
        > "$OUT_DIR/macos-storm.log" 2>&1
    rc=$?
    tail -3 "$OUT_DIR/macos-storm.log"
    cat "$OUT_DIR/macos-storm.log" "$OUT_DIR/macos-storm-native.log" \
        > "$OUT_DIR/macos-storm-combined.log"
    metric darwin-storm "$OUT_DIR/macos-storm-combined.log" \
        "$METRICS_DIR/macos-storm.json"
    mrc=$?
    { [ $rc -ne 0 ] || ! grep -q "All tests passed" "$OUT_DIR/macos-storm.log" \
        || [ $mrc -eq 1 ]; } && ok=0

    if [ $ok -eq 1 ]; then result_macos_scn="pass"
    else result_macos_scn="FAIL"; echo "  logs: $OUT_DIR/macos-{idle,storm}*.log"; fi
}

# ─────────────────────────────────────── GATE scenarios: iOS Simulator
# Same two scenarios with the WS transport forced through
# debugEndpointOverride. The sim engine is idle-only (MLX cannot run there),
# so: idle leg = client logic + warming-heartbeat cadence (the compose-tick
# truth that catches the idle flicker); storm leg = client logic + crash
# scan, engine speech truth honestly marked SKIPPED-sim (covered on macOS,
# same Darwin plugin). See e2e/scenarios/README.md for the boundary.
run_ios_scn() {
    want ios_scn || return 0
    note "GATE — iOS Simulator scenarios (idle stability + storm logic)"
    if ! ls -d "$HERE/../ios/Frameworks/libessence2.xcframework/"ios-arm64*-simulator >/dev/null 2>&1; then
        echo "  SKIP: libessence2.xcframework has no ios-simulator slice"
        result_ios_scn="skip (no sim slice)"; return
    fi
    if [ -z "$E2E_ELEVATE_SRC" ]; then
        echo "  SKIP: no elevatedir found (set E2E_ELEVATE_SRC)"; return
    fi
    local udid booted_by_us=0
    udid=$(xcrun simctl list devices booted 2>/dev/null \
        | awk '/iPhone/ {print $(NF-1)}' | tr -d '()' | head -1)
    if [ -z "$udid" ]; then
        udid=$(xcrun simctl list devices available 2>/dev/null \
            | awk '/iPhone 17 Pro \(/ {print $(NF-1)}' | tr -d '()' | tail -1)
        [ -n "$udid" ] && { xcrun simctl boot "$udid"; booted_by_us=1; sleep 8; }
    fi
    [ -z "$udid" ] && { echo "  no iPhone simulator available — skipping"; return; }
    cd "$EXAMPLE_DIR" || { result_ios_scn="FAIL"; return; }
    local soak="${E2E_IDLE_SOAK_S:-60}" ok=1

    # Native truth: the test dup2's the Runner's stderr (NSLog mirror) to a
    # host path — sim apps can write host files. Fallback: the sim's unified
    # log (NOT redacted on the sim, unlike macOS).
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    : > "$OUT_DIR/ios-idle-native.log"
    flutter test integration_test/e2e_idle_stability_test.dart -d "$udid" \
        "${COMMON_DEFINES[@]}" \
        --dart-define=E2E_BUNDLE="$E2E_ELEVATE_SRC" \
        --dart-define=E2E_ACTOR_SRC="$E2E_ACTOR_SRC" \
        --dart-define=E2E_IDLE_SOAK_S="$soak" \
        --dart-define=E2E_NATIVE_LOG="$OUT_DIR/ios-idle-native.log" \
        > "$OUT_DIR/ios-idle.log" 2>&1
    local rc=$?
    tail -3 "$OUT_DIR/ios-idle.log"
    if [ "$(wc -l < "$OUT_DIR/ios-idle-native.log")" -lt 5 ]; then
        xcrun simctl spawn "$udid" log show --start "$ts" \
            --predicate 'processImagePath CONTAINS "Runner"' --style compact \
            > "$OUT_DIR/ios-idle-native.log" 2>/dev/null
    fi
    cat "$OUT_DIR/ios-idle.log" "$OUT_DIR/ios-idle-native.log" \
        > "$OUT_DIR/ios-idle-combined.log"
    metric darwin-idle "$OUT_DIR/ios-idle-combined.log" \
        "$METRICS_DIR/ios-idle.json" --cadence --soak-s "$soak"
    local mrc=$?
    { [ $rc -ne 0 ] || ! grep -q "All tests passed" "$OUT_DIR/ios-idle.log" \
        || [ $mrc -eq 1 ]; } && ok=0

    ts=$(date '+%Y-%m-%d %H:%M:%S')
    : > "$OUT_DIR/ios-storm-native.log"
    flutter test integration_test/e2e_storm_lifecycle_test.dart -d "$udid" \
        "${COMMON_DEFINES[@]}" \
        --dart-define=E2E_BUNDLE="$E2E_ELEVATE_SRC" \
        --dart-define=E2E_ACTOR_SRC="$E2E_ACTOR_SRC" \
        --dart-define=E2E_NATIVE_LOG="$OUT_DIR/ios-storm-native.log" \
        > "$OUT_DIR/ios-storm.log" 2>&1
    rc=$?
    tail -3 "$OUT_DIR/ios-storm.log"
    if [ "$(wc -l < "$OUT_DIR/ios-storm-native.log")" -lt 5 ]; then
        xcrun simctl spawn "$udid" log show --start "$ts" \
            --predicate 'processImagePath CONTAINS "Runner"' --style compact \
            > "$OUT_DIR/ios-storm-native.log" 2>/dev/null
    fi
    cat "$OUT_DIR/ios-storm.log" "$OUT_DIR/ios-storm-native.log" \
        > "$OUT_DIR/ios-storm-combined.log"
    metric darwin-storm "$OUT_DIR/ios-storm-combined.log" \
        "$METRICS_DIR/ios-storm.json" --sim
    mrc=$?
    { [ $rc -ne 0 ] || ! grep -q "All tests passed" "$OUT_DIR/ios-storm.log" \
        || [ $mrc -eq 1 ]; } && ok=0

    if [ $ok -eq 1 ]; then result_ios_scn="pass"
    else result_ios_scn="FAIL"; echo "  logs: $OUT_DIR/ios-{idle,storm}*.log"; fi
    if [ $booted_by_us -eq 1 ] && [ "${E2E_KEEP_BOOTED:-0}" != "1" ]; then
        xcrun simctl shutdown "$udid" >/dev/null 2>&1
    fi
}

# ─────────────────────────────────────── GATE scenarios: Android emulator
# Drive-loop soak (e2e_drive_soak_test.dart) then three measured verdicts
# from one logcat capture: pacing truth, mouth-gate flip latency, governor
# sanity (SKIPPED loudly when the governor build hasn't landed).
run_android_scn() {
    want android_scn || return 0
    note "GATE — Android emulator scenarios (pacing + mouth gate + governor)"
    local SDK="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
    local EMU="$SDK/emulator/emulator" ADB="$SDK/platform-tools/adb"
    local AVD="${E2E_AVD:-bench-arm64}"
    # Default the le-bundle to this machine's lab copy when not pinned.
    local BUNDLE="${E2E_ANDROID_BUNDLE:-$HOME/bithuman/_elevate_runtime_lab/A63GVG1577.lebundle}"
    if [ ! -d "$BUNDLE" ]; then
        echo "  SKIP: no le-bundle (set E2E_ANDROID_BUNDLE)"; return
    fi
    if ! "$EMU" -list-avds 2>/dev/null | grep -qx "$AVD"; then
        echo "  SKIP: AVD '$AVD' not found"; return
    fi
    # Multi-device safe: a phone may be plugged in alongside the emulator,
    # so never run bare adb — find (or boot) the emulator and -s it.
    "$ADB" start-server >/dev/null 2>&1
    local started_by_us=0 SERIAL
    SERIAL=$("$ADB" devices | awk '/^emulator-/ {print $1; exit}')
    # adb server restarts (e.g. a phone unplugging) can blank one listing.
    [ -z "$SERIAL" ] && { sleep 2; SERIAL=$("$ADB" devices | awk '/^emulator-/ {print $1; exit}'); }
    if [ -z "$SERIAL" ]; then
        echo "  booting $AVD headless…"
        "$EMU" -avd "$AVD" -no-window -no-audio -no-boot-anim -netfast \
            > "$OUT_DIR/android-emulator.log" 2>&1 &
        started_by_us=1
        local i=0
        until SERIAL=$("$ADB" devices | awk '/^emulator-/ {print $1; exit}'); [ -n "$SERIAL" ]; do
            sleep 3; i=$((i+1)); [ $i -gt 40 ] && break
        done
        [ -z "$SERIAL" ] && { echo "  emulator never appeared"; result_android_scn="FAIL"; return; }
    fi
    local i=0
    until [ "$("$ADB" -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do
        sleep 3; i=$((i+1)); [ $i -gt 100 ] && { echo "  emulator boot timeout"; result_android_scn="FAIL"; return; }
    done
    local DEV_BUNDLE=/data/local/tmp/e2e/bundle
    # NB: ${braces} or ASCII required next to variables — bash 3.2 (macOS)
    # folds an adjacent multibyte char into the name and dies under set -u.
    echo "  pushing le-bundle to ${DEV_BUNDLE}..."
    "$ADB" -s "$SERIAL" shell mkdir -p /data/local/tmp/e2e >/dev/null 2>&1
    "$ADB" -s "$SERIAL" shell rm -rf "$DEV_BUNDLE" >/dev/null 2>&1
    "$ADB" -s "$SERIAL" push "$BUNDLE" "$DEV_BUNDLE" >/dev/null \
        || { echo "  adb push failed"; result_android_scn="FAIL"; return; }
    "$ADB" -s "$SERIAL" shell chmod -R a+rX /data/local/tmp/e2e
    cd "$EXAMPLE_DIR" || { result_android_scn="FAIL"; return; }
    "$ADB" -s "$SERIAL" logcat -c 2>/dev/null
    flutter test integration_test/e2e_drive_soak_test.dart -d "$SERIAL" \
        "${COMMON_DEFINES[@]}" \
        --dart-define=E2E_BUNDLE=$DEV_BUNDLE \
        > "$OUT_DIR/android-soak.log" 2>&1
    local rc=$?
    tail -3 "$OUT_DIR/android-soak.log"
    "$ADB" -s "$SERIAL" logcat -v time -d > "$OUT_DIR/android-soak-logcat.log" 2>/dev/null
    local ok=1
    { [ $rc -ne 0 ] || ! grep -q "All tests passed" "$OUT_DIR/android-soak.log"; } && ok=0
    metric android-pacing "$OUT_DIR/android-soak-logcat.log" \
        "$METRICS_DIR/android-pacing.json"
    [ $? -eq 1 ] && ok=0
    metric android-mouthgate "$OUT_DIR/android-soak-logcat.log" \
        "$METRICS_DIR/android-mouthgate.json"
    [ $? -eq 1 ] && ok=0
    metric android-governor "$OUT_DIR/android-soak-logcat.log" \
        "$METRICS_DIR/android-governor.json"
    local grc=$?
    [ $grc -eq 1 ] && ok=0
    if [ $ok -eq 1 ]; then
        result_android_scn="pass"
        [ $grc -eq 3 ] && result_android_scn="pass (governor SKIPPED)"
    else
        result_android_scn="FAIL"; echo "  logs: $OUT_DIR/android-soak*.log"
    fi
    if [ $started_by_us -eq 1 ] && [ "${E2E_KEEP_BOOTED:-0}" != "1" ]; then
        "$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1
    fi
}

run_tier1
run_macos
run_ios
run_android
run_macos_scn
run_ios_scn
run_android_scn

# ────────────────────────────────────────────────────────── measurements
# Merge every per-scenario JSON into the run's single measurement artifact
# (the gate's trend-comparison record). E2E_ARCHIVE_BASELINE=1 also snapshots
# it into e2e/baselines/ (commit it to pin a release baseline).
if ls "$METRICS_DIR"/*.json >/dev/null 2>&1; then
    GIT_REV=$(git -C "$HERE" rev-parse --short HEAD 2>/dev/null || echo unknown)
    python3 "$GATE_METRICS" merge --out "$OUT_DIR/gate-metrics.json" \
        --git-rev "$GIT_REV" "$METRICS_DIR"/*.json
    if [ "${E2E_ARCHIVE_BASELINE:-0}" = "1" ]; then
        mkdir -p "$HERE/baselines"
        cp "$OUT_DIR/gate-metrics.json" \
           "$HERE/baselines/gate-metrics-$(date +%Y%m%d)-$GIT_REV.json"
        echo "  baseline archived: e2e/baselines/gate-metrics-$(date +%Y%m%d)-$GIT_REV.json"
    fi
fi

# ────────────────────────────────────────────────────────── summary
echo
echo "──────────────── e2e summary ────────────────"
printf '  %-34s %s\n' "tier1  (widget/unit)"               "$result_tier1"
printf '  %-34s %s\n' "tier2  macOS session flow"          "$result_macos"
printf '  %-34s %s\n' "tier2  iOS sim boot+engine"         "$result_ios"
printf '  %-34s %s\n' "tier2  Android emulator"            "$result_android"
printf '  %-34s %s\n' "gate   macOS idle+storm scenarios"  "$result_macos_scn"
printf '  %-34s %s\n' "gate   iOS sim idle+storm scenarios" "$result_ios_scn"
printf '  %-34s %s\n' "gate   Android pacing/gate/governor" "$result_android_scn"
echo "  logs: $OUT_DIR    measurements: $OUT_DIR/gate-metrics.json"
echo "──────────────────────────────────────────────"

for r in "$result_tier1" "$result_macos" "$result_ios" "$result_android" \
         "$result_macos_scn" "$result_ios_scn" "$result_android_scn"; do
    [ "$r" = "FAIL" ] && exit 1
done
exit 0
