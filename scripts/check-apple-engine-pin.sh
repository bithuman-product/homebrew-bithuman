#!/usr/bin/env bash
# check-apple-engine-pin.sh — A TAG MUST NAME AN ENGINE.
#
# ★THE DEFECT THIS REFUSES, MEASURED ON THE PUBLISHED BYTES 2026-09-16.
#
# This repo shipped TWO Apple paths to the same on-device engine and nothing
# compared them:
#
#   SwiftPM   Package.swift  `essence2Tag = "essence2-v1.7.0"`
#   CocoaPods the Flutter pod, whose bootstrap ran the engine SDK's own script
#             with NO engine coordinate — so the tag came from a default in the
#             PRIVATE engine repo: `LIBESSENCE2_RELEASE="${LIBESSENCE2_RELEASE-essence2-v1.2.0}"`,
#             last rolled 2026-09-06 and never moved again.
#
# essence2-v1.2.0 is a PRE-RELEASE whose own title reads "superseded by
# essence2-v1.5.0". Five releases apart, on one repo, silently. Measured by
# `strings -a` on the slices as the releases serve them:
#
#            slice          DriverCursor   "decoded IN PLACE"
#   v1.2.0   macos-arm64              0                     0
#   v1.2.0   ios-arm64                0                     0
#   v1.7.0   macos-arm64            257                     1
#   v1.7.0   ios-arm64              257                     1
#
# No device ran v1.2.0 — every Apple build that day overrode the default by
# hand — but the pod's COMMITTED assumptions were written for it: `s.resources`
# globbed `a2x_w2v.*.onnx`, a name only the v1.2.0-era resources archive ships,
# so the app carried the .bundles and no audio encoder and `be_essence2_create`
# returned -2 on the first macOS run. A default nobody links still decides what
# the code around it believes.
#
# The second half: `locate_engine_sdk` took a ref and BOTH call sites omitted
# it, so the engine adapter Swift compiled into the pod came from the private
# repo's main HEAD *at bootstrap time*, into gitignored directories, with no
# revision recorded anywhere. `flutter-plugin-v2.6.1` named no engine at all.
#
# So the coordinates now live in the plugin, committed, exactly as
# android/build.gradle names `ai.bithuman:essence2-android:0.5.8` — and this
# refuses a commit where they drift apart again.
#
# CHECKS (all offline — no network, no credential, runs on a fork)
#   A1 SOURCE-PINNED   bootstrap.sh defaults BITHUMAN_MODELS_REF to a full
#                      40-hex commit sha. A branch name is not a pin.
#   A2 REF-PASSED      every locate_engine_sdk call site passes the ref. This is
#                      the exact line that was missing; two call sites, twice.
#   A3 ENGINE-PINNED   bootstrap.sh defaults all four engine coordinates
#                      (release + sha256, engine + resources).
#   A4 PATHS-AGREE     the plugin's LIBESSENCE2_RELEASE == Package.swift's
#                      essence2Tag. The headline defect.
#   A5 DIGEST-AGREES   the plugin's LIBESSENCE2_SHA256 == Package.swift's
#                      libessence2.xcframework.zip binaryTarget checksum. That
#                      checksum is itself held to the published bytes by
#                      manifest-truth R1, so agreeing with it is agreeing with
#                      the artifact — no second download here.
#
# Usage:  check-apple-engine-pin.sh [repo-root]
# Exit:   0 PASS   1 REFUSE   2 could not run (never a silent pass)
# Apache-2.0; (c) bitHuman.
set -uo pipefail

ROOT="${1:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
BOOT="$ROOT/packages/flutter-plugin/scripts/bootstrap.sh"
MANIFEST="$ROOT/Package.swift"

cannot() { echo "::error::check-apple-engine-pin: $*" >&2; exit 2; }
[ -f "$BOOT" ]     || cannot "no $BOOT"
[ -f "$MANIFEST" ] || cannot "no $MANIFEST"

FAIL=0
refuse() { echo "REFUSE  $*"; echo "::error::check-apple-engine-pin: $*" >&2; FAIL=1; }
pass()   { echo "ok      $*"; }

# Read a `NAME="${NAME:-VALUE}"` default out of bootstrap.sh. Deliberately
# strict: `${NAME-VALUE}` (no colon) is a different operator and an empty export
# would silently disable the pin, so only the `:-` form counts as a pin.
pin() {  # $1 = var name -> prints VALUE, empty if undeclared
    sed -n "s/^$1=\"\\\${$1:-\\([^}]*\\)}\"\$/\\1/p" "$BOOT" | head -1
}

MODELS_REF="$(pin BITHUMAN_MODELS_REF)"
ENG_TAG="$(pin LIBESSENCE2_RELEASE)"
ENG_SHA="$(pin LIBESSENCE2_SHA256)"
RES_TAG="$(pin LIBESSENCE2_RESOURCES_RELEASE)"
RES_SHA="$(pin LIBESSENCE2_RESOURCES_SHA256)"

# ── A1 SOURCE-PINNED ────────────────────────────────────────────────────────
if [ -z "$MODELS_REF" ]; then
    refuse "A1 bootstrap.sh declares no BITHUMAN_MODELS_REF default — the engine adapter source would come from whatever main HEAD is at bootstrap time, and the tag would name no engine"
elif ! printf '%s' "$MODELS_REF" | grep -Eq '^[0-9a-f]{40}$'; then
    refuse "A1 BITHUMAN_MODELS_REF is '$MODELS_REF' — a pin must be a full 40-hex commit sha; a branch or tag name can move under a published plugin tag"
else
    pass "A1 engine adapter source pinned at $MODELS_REF"
fi

# ── A2 REF-PASSED ───────────────────────────────────────────────────────────
# Every call must carry four arguments. Grading the CALL, not the default, is
# the point: the function has always accepted a ref and always defaulted it.
BAD_CALLS="$(grep -n 'locate_engine_sdk [A-Z]' "$BOOT" \
             | grep -v '"\$BITHUMAN_MODELS_REF"' || true)"
CALLS="$(grep -c 'locate_engine_sdk [A-Z]' "$BOOT" || true)"
if [ "${CALLS:-0}" -lt 1 ]; then
    refuse "A2 found no locate_engine_sdk call sites in bootstrap.sh — this check has lost its subject"
elif [ -n "$BAD_CALLS" ]; then
    refuse "A2 locate_engine_sdk call site(s) do not pass the pin:
$BAD_CALLS"
else
    pass "A2 all $CALLS locate_engine_sdk call site(s) pass \$BITHUMAN_MODELS_REF"
fi

# ── A3 ENGINE-PINNED ────────────────────────────────────────────────────────
MISSING=""
[ -n "$ENG_TAG" ] || MISSING="$MISSING LIBESSENCE2_RELEASE"
[ -n "$ENG_SHA" ] || MISSING="$MISSING LIBESSENCE2_SHA256"
[ -n "$RES_TAG" ] || MISSING="$MISSING LIBESSENCE2_RESOURCES_RELEASE"
[ -n "$RES_SHA" ] || MISSING="$MISSING LIBESSENCE2_RESOURCES_SHA256"
if [ -n "$MISSING" ]; then
    refuse "A3 bootstrap.sh declares no default for:$MISSING — an undeclared coordinate falls back to the private engine repo's own default, which is how the pod came to link a superseded pre-release"
elif ! printf '%s' "$ENG_SHA$RES_SHA" | grep -Eq '^[0-9a-f]{128}$'; then
    refuse "A3 the engine digests are not two 64-hex sha256 values (engine '$ENG_SHA', resources '$RES_SHA')"
else
    pass "A3 engine pinned at $ENG_TAG (${ENG_SHA:0:16}…) + resources $RES_TAG (${RES_SHA:0:16}…)"
fi

# ── A4 PATHS-AGREE / A5 DIGEST-AGREES ───────────────────────────────────────
SPM_TAG="$(sed -n 's/^let essence2Tag = "\([^"]*\)"$/\1/p' "$MANIFEST" | head -1)"
[ -n "$SPM_TAG" ] || cannot "could not read essence2Tag out of $MANIFEST"
SPM_SHA="$(python3 - "$MANIFEST" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'url:\s*"[^"]*/libessence2\.xcframework\.zip"\s*,\s*checksum:\s*"([0-9a-fA-F]{64})"', src)
print(m.group(1).lower() if m else "")
PY
)"
[ -n "$SPM_SHA" ] || cannot "could not read the libessence2.xcframework.zip binaryTarget checksum out of $MANIFEST"

if [ "$ENG_TAG" != "$SPM_TAG" ]; then
    refuse "A4 THE TWO APPLE PATHS NAME DIFFERENT ENGINES — the Flutter pod links '$ENG_TAG', SwiftPM serves '$SPM_TAG'. Roll both, in one commit, or a developer's pod and their Package.resolved disagree with no way to see it."
else
    pass "A4 both Apple paths name $SPM_TAG"
fi

if [ "$ENG_SHA" != "$SPM_SHA" ]; then
    refuse "A5 the pod's engine digest ${ENG_SHA:0:16}… is not Package.swift's binaryTarget checksum ${SPM_SHA:0:16}… — same tag, different bytes claimed"
else
    pass "A5 engine digest matches the binaryTarget checksum (${SPM_SHA:0:16}…)"
fi

if [ "$FAIL" -ne 0 ]; then
    echo
    echo "The Apple engine edge is the Android edge's twin: packages/flutter-plugin/android/build.gradle"
    echo "names immutable Maven coordinates, and packages/flutter-plugin/scripts/bootstrap.sh must name"
    echo "immutable Apple ones. Fix the pin block there, not this check."
    exit 1
fi
echo "PASS — the plugin tag names an engine, on both Apple paths."
