#!/usr/bin/env bash
# stress-webrtc-iphone.sh — iPhone self-interruption stress protocol
# (tasks #56/#62). Continuous agent speech, no user input — any server-VAD
# speech event counts as a SPURIOUS barge-in (target: 0/min).
#
# Since task #62 the iOS default transport is the WebSocket + native VP-IO
# path (same single-engine architecture as macOS), so this script stresses
# THAT path by default; add --dart-define=BITHUMAN_TRANSPORT=webrtc to the
# build below to stress the legacy WebRTC arm instead. The metrics script
# scores both (WS barges land as native `[RealtimeAudioIO] barge:` lines).
#
# Per arm: build (release, Elevate variant — same bundle the device already
# has: ai.bithuman.app.elevate), devicectl install (NEVER uninstall — that
# wipes the multi-GB sandbox), launch with --console, capture DURATION
# seconds, then score with stress-webrtc-metrics.py.
#
# The app drives itself:
#   BITHUMAN_DEV_AUTOCONNECT=true  session starts after engine warm-up
#   BITHUMAN_DEV_STRESS=true       ~60 s monologue per turn, re-armed after
#                                  every response.done (openai_webrtc_session)
#
# Arms (run one per invocation):
#   quiet50   quiet room, speaker ~50 %         (baseline)
#   loud100   quiet room, speaker 100 %         (echo-hostile)
#   bgaudio   background audio from this Mac near the phone (BG_AUDIO_FILE)
#
# NOT automatable: the iPhone's volume slider (no devicectl/AppleScript path)
# — the script prompts for it and counts down before launching. Everything
# else (build, install, launch, capture, scoring) is hands-off.
#
# Usage:
#   scripts/stress-webrtc-iphone.sh quiet50            # 4 min default
#   DURATION=300 scripts/stress-webrtc-iphone.sh loud100
#   BG_AUDIO_FILE=/path/x.m4a scripts/stress-webrtc-iphone.sh bgaudio
#   SKIP_BUILD=1 scripts/stress-webrtc-iphone.sh loud100   # reuse last build
#
# Env (defaults from ~/.env): OPENAI_API_KEY, BITHUMAN_API_SECRET,
# DEVELOPMENT_TEAM, DURATION (s, default 240), SKIP_BUILD, BG_AUDIO_FILE.
# Logs: /tmp/bithuman-stress/<arm>-<ts>.log (+ .metrics.txt)
#
# Apache-2.0; (c) bitHuman.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EX="$ROOT/example"
ARM="${1:-}"
case "$ARM" in quiet50|loud100|bgaudio) ;; *)
    echo "usage: $0 quiet50|loud100|bgaudio   (see header)"; exit 2 ;;
esac

DURATION="${DURATION:-240}"
SKIP_BUILD="${SKIP_BUILD:-0}"
BG_AUDIO_FILE="${BG_AUDIO_FILE:-}"
OUT_DIR="/tmp/bithuman-stress"
mkdir -p "$OUT_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$OUT_DIR/$ARM-$STAMP.log"

# Keys from ~/.env when not already exported (same contract as run-all.sh).
if [ -f "$HOME/.env" ]; then
    while IFS='=' read -r k v; do
        [[ "$k" =~ ^[A-Z_]+$ ]] || continue
        [ -z "${!k:-}" ] && export "$k=$v" || true
    done < "$HOME/.env"
fi
[ -n "${OPENAI_API_KEY:-}" ] || { echo "OPENAI_API_KEY missing (env or ~/.env)"; exit 2; }
TEAM="${DEVELOPMENT_TEAM:-G64NFNZX84}"

# ── device ──────────────────────────────────────────────────────────────
UDID="$(xcrun devicectl list devices 2>/dev/null | awk '
    /available \(paired\)/ && /iPhone/ {
        for (i=1; i<=NF; i++)
            if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/) { print $i; exit }
    }')"
[ -n "$UDID" ] || { echo "no paired iPhone reachable via devicectl"; exit 2; }
echo "[stress] iPhone: $UDID  arm: $ARM  duration: ${DURATION}s"

BUNDLE="ai.bithuman.app.elevate"

# ── build (Elevate variant, release — devicectl refuses debug Flutter) ──
if [ "$SKIP_BUILD" != "1" ]; then
    IOS_CFG="$EX/ios/Flutter/Variant.local.xcconfig"
    printf 'BITHUMAN_BUNDLE_SUFFIX = .elevate\nBITHUMAN_DISPLAY_NAME = bitHuman Elevate\n' >"$IOS_CFG"
    printf 'DEVELOPMENT_TEAM = %s\n' "$TEAM" >"$EX/ios/Flutter/DevelopmentTeam.local.xcconfig"
    trap 'rm -f "$IOS_CFG"' EXIT
    echo "[stress] building iOS release (stress + autoconnect defines)…"
    ( cd "$EX" && flutter build ios --release \
        --dart-define=BITHUMAN_ENGINE=elevate \
        --dart-define=BITHUMAN_DEV_AUTOCONNECT=true \
        --dart-define=BITHUMAN_DEV_STRESS=true \
        --dart-define=OPENAI_API_KEY="$OPENAI_API_KEY" \
        --dart-define=BITHUMAN_API_SECRET="${BITHUMAN_API_SECRET:-}" \
        >"$OUT_DIR/build-$STAMP.log" 2>&1 ) \
        || { echo "build failed — $OUT_DIR/build-$STAMP.log"; exit 1; }
fi
APP="$EX/build/ios/iphoneos/Runner.app"
[ -d "$APP" ] || { echo "no Runner.app at $APP (build first / drop SKIP_BUILD)"; exit 1; }

# install only — NEVER uninstall (sandbox holds the Elevate weights).
echo "[stress] installing $BUNDLE…"
xcrun devicectl device install app --device "$UDID" "$APP" \
    >"$OUT_DIR/install-$STAMP.log" 2>&1 \
    || { echo "install failed — $OUT_DIR/install-$STAMP.log"; exit 1; }

# ── arm setup (the one manual step + optional Mac-side background audio) ─
case "$ARM" in
    quiet50) echo; echo ">>> SET THE iPHONE VOLUME TO ~50% NOW (quiet room). <<<" ;;
    loud100) echo; echo ">>> SET THE iPHONE VOLUME TO 100% NOW (quiet room). <<<" ;;
    bgaudio)
        echo; echo ">>> SET THE iPHONE VOLUME TO 100%; Mac speakers near the phone. <<<"
        [ -f "$BG_AUDIO_FILE" ] || { echo "bgaudio arm needs BG_AUDIO_FILE=<audio file>"; exit 2; } ;;
esac
for i in 10 9 8 7 6 5 4 3 2 1; do printf '\r[stress] launching in %2ds…' "$i"; sleep 1; done; echo

BG_PID=""
if [ "$ARM" = "bgaudio" ]; then
    # Loop the file for the whole arm from the Mac's speakers.
    ( while :; do afplay "$BG_AUDIO_FILE" || break; done ) & BG_PID=$!
fi

# ── launch + capture ────────────────────────────────────────────────────
# --console streams the app's stdout/stderr: NSLog ([elevate-av]/
# [RealtimeAudioIO]) for sure, Dart prints (the [webrtc]/[stress] event
# log) in the attached case; awk stamps wall-clock on every line so the
# extractor can compute per-minute rates. BELT+SUSPENDERS: idevicesyslog
# runs in parallel ($LOG.syslog) — on release builds Dart print lands in
# the device syslog, so if the console copy is missing the [webrtc] lines
# the extractor falls back to the syslog copy below.
SYSLOG_PID=""
if command -v idevicesyslog >/dev/null 2>&1; then
    idevicesyslog -u "$UDID" -m Runner >"$LOG.syslog" 2>/dev/null & SYSLOG_PID=$!
fi
echo "[stress] launching $BUNDLE with console capture → $LOG"
xcrun devicectl device process launch \
    --device "$UDID" \
    --terminate-existing \
    --console \
    --environment-variables "{\"BITHUMAN_API_SECRET\":\"${BITHUMAN_API_SECRET:-}\"}" \
    "$BUNDLE" 2>&1 \
    | awk '{ print strftime("[%H:%M:%S]"), $0; fflush() }' >"$LOG" &
CAP_PID=$!

sleep "$DURATION"
kill "$CAP_PID" 2>/dev/null; wait "$CAP_PID" 2>/dev/null
[ -n "$SYSLOG_PID" ] && kill "$SYSLOG_PID" 2>/dev/null
[ -n "$BG_PID" ] && { kill "$BG_PID" 2>/dev/null; pkill -P "$BG_PID" 2>/dev/null; }
# Leave the app running on the device (console detached); next launch uses
# --terminate-existing.

# ── score (console capture first; syslog fallback if it lacks events) ──
echo
SCORE_LOG="$LOG"
python3 "$ROOT/scripts/stress-webrtc-metrics.py" "$LOG" --label "$ARM" \
    >"$LOG.metrics.txt" 2>&1
RC=$?
if [ "$RC" = "2" ] && [ -s "$LOG.syslog" ]; then
    echo "[stress] console copy lacked events — scoring the syslog capture"
    SCORE_LOG="$LOG.syslog"
    python3 "$ROOT/scripts/stress-webrtc-metrics.py" "$LOG.syslog" --label "$ARM" \
        >"$LOG.metrics.txt" 2>&1
    RC=$?
fi
cat "$LOG.metrics.txt"
echo
echo "[stress] scored: $SCORE_LOG"
exit "$RC"
