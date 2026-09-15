#!/bin/bash
# Every bare `#if os(macOS)` in the plugin's SHARED sources must carry a stated reason.
#
# ★WHY. `shared/Classes/` compiles for BOTH macOS and iOS, so `#if os(macOS)` alone
# silently deletes code on iPhone. Three shipping defects came from exactly that, all
# found by accident rather than by a gate:
#   • setExpression2AgentDir           — iOS could not load a downloaded agent (PR #26)
#   • notifyTurnEnd / onTurnEnd        — every bot utterance on iPhone ended with the last
#                                        partial chunk unflushed: last word clipped, picture
#                                        frozen 3 s on the drain watchdog
#   • clearAudioQueue (barge)          — a barge on iPhone did not reset the engine, so the
#                                        avatar kept animating the cancelled response
# In this directory the DEFAULT CORRECT FORM IS `#if os(macOS) || os(iOS)`. A macOS-only
# guard is a real thing (AppKit, IOKit, the CoreAudio HAL device swap) — it just has to say
# so, in a `macOS-only:` comment within the three lines above it, where the next reader and
# this check can both see it.
#
# ★WHY A REASON AND NOT MERELY A COMMENT. A WRONG reason is worse than none, because it
# stops the next reader from looking. `ensureEngineExtracted` carried "macOS-only (embody
# runtime is macOS)" long after expression-2 shipped on iPhone: anyone auditing this file
# read that line and moved on. The reason has to be the thing that is actually macOS-only
# — here, the embody.model bundled in the macOS app — so that when it stops being true,
# it reads as false instead of as settled.
#
# ★AND A GUARD CAN FALSIFY A COMMENT FAR AWAY. `embodyDisplayTick` reasons that "a real
# barge bypasses all this: clearAudioQueue() resets the runtime (buf empty → hasPendingTail
# false) → the next tick idles." That was TRUE on macOS and FALSE on iOS for as long as the
# barge reset was macOS-gated — one missing platform in a `#if` two hundred lines away
# turned a documented invariant into a lie about the system.
set -uo pipefail
cd "$(dirname "$0")/.."
DIR=packages/flutter-plugin/shared/Classes
BAD=0
while IFS=: read -r f n _; do
  [ -n "${f:-}" ] || continue
  if ! sed -n "$((n-3)),$((n-1))p" "$f" | grep -q "macOS-only"; then
    echo "::error file=$f,line=$n::bare '#if os(macOS)' with no stated reason in shared sources."
    echo "    This compiles the block OUT on iPhone. If that is intended, put a"
    echo "    '// macOS-only: <why>' comment directly above it. If not, the correct"
    echo "    form is '#if os(macOS) || os(iOS)'."
    BAD=$((BAD+1))
  fi
done < <(grep -rnE '^[[:space:]]*#if os\(macOS\)[[:space:]]*$' "$DIR" || true)
TOTAL=$(grep -rcE '^[[:space:]]*#if os\(macOS\)[[:space:]]*$' "$DIR" | awk -F: '{s+=$2} END {print s+0}')
if [ "$BAD" -gt 0 ]; then echo "FAIL: $BAD of $TOTAL bare macOS guards have no stated reason"; exit 1; fi
echo "OK: all $TOTAL bare '#if os(macOS)' guards in $DIR carry a stated reason"
