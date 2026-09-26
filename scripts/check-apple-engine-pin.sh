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
#   A1 NO-SOURCE       bootstrap.sh fetches and copies no engine source (2.6.19:
#                      the pod links the published binaries).
#   A2 X2-AGREES       the pod's Expression 2 release + checksums == Package.swift's.
#   A3 ENGINE-PINNED   bootstrap.sh defaults all four engine coordinates
#                      (release + sha256, engine + resources).
#   A4 PATHS-AGREE     the plugin's LIBESSENCE2_RELEASE == Package.swift's
#                      essence2Tag. The headline defect.
#   A5 DIGEST-AGREES   the plugin's LIBESSENCE2_SHA256 == Package.swift's
#                      libessence2.xcframework.zip binaryTarget checksum. That
#                      checksum is itself held to the published bytes by
#                      manifest-truth R1, so agreeing with it is agreeing with
#                      the artifact — no second download here.
#   A6 UMH-AGREES      the pod's UnifiedModelHeader pin == the SwiftPM binaryTarget.
#   A7 KIT-AGREES      Essence2Kit's Essence2Resources.releaseTag == essence2Tag.
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

ENG_TAG="$(pin LIBESSENCE2_RELEASE)"
ENG_SHA="$(pin LIBESSENCE2_SHA256)"
RES_TAG="$(pin LIBESSENCE2_RESOURCES_RELEASE)"
RES_SHA="$(pin LIBESSENCE2_RESOURCES_SHA256)"

# ── A1 NO-SOURCE ────────────────────────────────────────────────────────────
# ★Since 2.6.19 the pod links the PUBLISHED engine binaries and compiles no engine source
# (owner ruling 2026-09-26: engine source is proprietary). bootstrap.sh must not clone the
# engine repository or copy engine Classes, and must pin the Expression 2 binaries.
if grep -nE 'locate_engine_sdk [A-Z]|git clone .*bithuman-models|gh repo clone|/sdk/Classes' "$BOOT" | grep -v '^[0-9]*:\s*#' | grep -q .; then
    refuse "A1 bootstrap.sh still fetches or copies engine SOURCE:
$(grep -nE 'locate_engine_sdk [A-Z]|git clone .*bithuman-models|gh repo clone|/sdk/Classes' "$BOOT" | grep -v '^[0-9]*:\s*#')"
else
    pass "A1 bootstrap.sh fetches no engine source"
fi

# ── A2 EXPRESSION2-AGREES ───────────────────────────────────────────────────
# The Expression 2 binaries the pod stages are the SDK tag's own bytes.
X2_TAG="$(pin EXPRESSION2_RELEASE)"; X2_SHA="$(pin EXPRESSION2_SHA256)"; BEP_SHA="$(pin BEP_SHA256)"
SPM_X2_TAG0="$(sed -n 's/^let expression2Tag = "\([^"]*\)"$/\1/p' "$MANIFEST" | head -1)"
spm_sum() { python3 - "$MANIFEST" "$1" <<'PY2'
import re, sys
s = open(sys.argv[1]).read()
m = re.search(r'name:\s*"%s",\s*url:\s*"[^"]*",\s*checksum:\s*"([0-9a-f]{64})"' % sys.argv[2], s)
print(m.group(1) if m else "")
PY2
}
SPM_X2_SHA="$(spm_sum Expression2Binary)"; SPM_BEP_SHA="$(spm_sum BithumanEngineProtocolBinary)"
if [ -z "$X2_TAG" ] || [ -z "$X2_SHA" ] || [ -z "$BEP_SHA" ]; then
    refuse "A2 bootstrap.sh declares no EXPRESSION2_RELEASE / EXPRESSION2_SHA256 / BEP_SHA256 default"
elif [ "$X2_TAG" != "$SPM_X2_TAG0" ] || [ "$X2_SHA" != "$SPM_X2_SHA" ] || [ "$BEP_SHA" != "$SPM_BEP_SHA" ]; then
    refuse "A2 the pod's Expression 2 pins ($X2_TAG ${X2_SHA:0:12} ${BEP_SHA:0:12}) differ from Package.swift's ($SPM_X2_TAG0 ${SPM_X2_SHA:0:12} ${SPM_BEP_SHA:0:12})"
else
    pass "A2 the pod links Expression 2 $X2_TAG, the bytes SwiftPM serves"
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

# A6 — the UnifiedModelHeader the pod stages is the SDK tag's own bytes.
# From essence2-v1.10.0 the engine archive REFERENCES UnifiedModelHeader, and the
# pod stages the module from the tap release SwiftPM's UnifiedModelHeaderBinary
# pins. The two drifted once with no check between them: Package.swift moved to
# v2.6.4 (Swift SDK tag v2.14.1) while the pod kept v2.6.3, so a plugin tag and
# the SDK tag it ships beside named different bytes for one module.
UMH_TAG="$(pin UMH_RELEASE)"
UMH_SHA="$(pin UMH_SHA256)"
SPM_X2_TAG="$(sed -n 's/^let expression2Tag = "\([^"]*\)"$/\1/p' "$MANIFEST" | head -1)"
SPM_UMH_SHA="$(python3 - "$MANIFEST" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'name:\s*"UnifiedModelHeaderBinary"\s*,\s*url:\s*"[^"]*/UnifiedModelHeader\.xcframework\.zip"\s*,\s*checksum:\s*"([0-9a-fA-F]{64})"', src)
print(m.group(1).lower() if m else "")
PY
)"
[ -n "$SPM_X2_TAG" ]  || cannot "could not read expression2Tag out of $MANIFEST"
[ -n "$SPM_UMH_SHA" ] || cannot "could not read the UnifiedModelHeaderBinary checksum out of $MANIFEST"
if [ -z "$UMH_TAG" ] || [ -z "$UMH_SHA" ]; then
    refuse "A6 bootstrap.sh declares no UMH_RELEASE/UMH_SHA256 default — the pod would stage no UnifiedModelHeader and the app's final link fails"
elif [ "$UMH_TAG" != "$SPM_X2_TAG" ] || [ "$UMH_SHA" != "$SPM_UMH_SHA" ]; then
    refuse "A6 the pod stages UnifiedModelHeader $UMH_TAG (${UMH_SHA:0:16}…), SwiftPM serves $SPM_X2_TAG (${SPM_UMH_SHA:0:16}…) — roll UMH_RELEASE/UMH_SHA256 with expression2Tag"
else
    pass "A6 UnifiedModelHeader pinned at $UMH_TAG, the SwiftPM binaryTarget's bytes (${SPM_UMH_SHA:0:16}…)"
fi

# A7 — Essence2Kit fetches the engine's runtime files from ONE release, named in its
# source, and the engine they must match is the one SwiftPM serves. A tag roll that moves
# essence2Tag and not this constant hands a new engine the last release's files — or, for
# a release that never carried them, a 404 on every customer's first run (#1224).
KIT="$ROOT/Sources/Essence2Kit/Essence2Engine.swift"
if [ -f "$KIT" ]; then
    KIT_TAG="$(sed -n 's/^ *public static let releaseTag = "\([^"]*\)"$/\1/p' "$KIT" | head -1)"
    if [ -z "$KIT_TAG" ]; then
        refuse "A7 could not read Essence2Resources.releaseTag out of $KIT — this check has lost its subject"
    elif [ "$KIT_TAG" != "$SPM_TAG" ]; then
        refuse "A7 Essence2Kit fetches its runtime files from '$KIT_TAG', SwiftPM serves the engine '$SPM_TAG' — roll releaseTag (and its sha256 pins) with essence2Tag"
    else
        pass "A7 Essence2Kit's runtime files come from $SPM_TAG, the engine SwiftPM serves"
    fi
fi

if [ "$FAIL" -ne 0 ]; then
    echo
    echo "The Apple engine edge is the Android edge's twin: packages/flutter-plugin/android/build.gradle"
    echo "names immutable Maven coordinates, and packages/flutter-plugin/scripts/bootstrap.sh must name"
    echo "immutable Apple ones. Fix the pin block there, not this check."
    exit 1
fi
echo "PASS — the plugin tag names an engine, on both Apple paths."
