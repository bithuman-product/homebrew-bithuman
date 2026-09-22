#!/bin/bash
# check-essence2-expression2-link.sh — does an APP that takes BOTH published
# products actually LINK?
#
# ★WHY THIS EXISTS AND WHY IT IS NOT `swift build`. Through 2026-09-08 the
# Package.swift header told developers, of `Essence2`: "Depend on it alongside
# either of the others." Nothing checked it, and it was false on the iOS DEVICE
# and on macOS: `libessence2.a` was libtool'd from the engine's whole library
# closure and that closure DEFINED the UnifiedModelHeader symbols, while the
# `Expression2` product forces every consumer to link
# UnifiedModelHeader.xcframework, which defines its own. `ld` exits 1 on the
# overlap.
#
# MEASURED 2026-09-21 on echelon, `nm -g --defined-only` per slice, symbols
# OWNED by the module (Swift mangling prefix `_$s18UnifiedModelHeader`),
# deduplicated — so essence-2's own "conformance of Expression.UnifiedHandle to
# UnifiedModelHeader.UnifiedAvatarHandle", which merely NAMES the module, is not
# counted:
#
#     published bytes                          ios-arm64  ios-sim  macos-arm64
#     essence2-v1.9.0  libessence2.a DEFINES       247      247       247
#     UnifiedModelHeader.xcframework @ v2.6.3      118      118       118
#     ⟹ colliding symbols                         112      112       112
#
# ★THAT IS NOT THE NUMBER THIS FILE FIRST CARRIED, AND THE DIFFERENCE IS A
# READING BUG WORTH KEEPING: `nm -g | grep ' [A-Z] '` counts `U` as a
# definition, which read 279/279/280 on the same bytes. `--defined-only` asks
# nm the question instead. (The 2026-09-08 note of "317/317/321" against
# essence2-v1.4.0 came from a looser count still — an un-anchored, un-deduped
# `grep -c UnifiedModelHeader`. The COLLIDING count, which is the one that
# decides whether an app links, is measured the same way on every row here.)
#
# A package-level build is BLIND to this: a library target is compiled, never
# linked, so `xcodebuild -destination 'generic/platform=iOS' build` on a package
# taking BOTH products exits 0. Only an EXECUTABLE link sees it. That is what
# this script does.
#
# ★AND ONE LINK SHAPE IS NOT AN ANSWER — see the ★ at the `arm` function for the
# five shapes measured on one source. In short: ios-arm64 is red with the
# archives loaded lazily, macos-arm64 and the simulator are red only once BOTH
# archives are force-loaded, and `-force_load` on libessence2.a ALONE is GREEN
# while the defect is live (measured on macos-arm64 and ios-arm64; the five-shape
# sweep was not run on the simulator). So every slice is run in both shapes.
#
# ★THE DISCRIMINATOR ARM MEANS THE OPPOSITE THING BEFORE AND AFTER, WHICH IS
# EXACTLY WHY IT IS HERE. While the engine archive carried those objects,
# dropping the framework from the link line was the only way to get an app to
# link at all. Now that the archive REFERENCES them, that arm must FAIL — with
# 14 *undefined* symbols (6 on the simulator) rather than duplicates. It is
# reported, not graded, and the script says which world it is looking at:
#   duplicates > 0, undefined 0  -> the OLD defect (archive defines them)
#   duplicates 0, undefined > 0  -> the archive is clean and the app is simply
#                                   missing the framework (Essence2-only apps
#                                   must therefore get UnifiedModelHeaderBinary
#                                   through the `Essence2` product)
#   duplicates 0, undefined 0    -> fixed, both halves shipped
#
# Usage:
#   tools/check-essence2-expression2-link.sh [<tag>]
#   tools/check-essence2-expression2-link.sh --tag <tag> \
#        [--libessence2 /path/to/libessence2.xcframework]
#
# `--libessence2` links a LOCALLY BUILT archive in place of the one the tag
# publishes, so a candidate can be graded before anything is released. Every
# other framework still comes from the resolved tag.
#
# Requires: macOS + Xcode. Resolves the tag from GitHub; no credential.
set -u

TAG=""
LES_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tag)          TAG="$2"; shift 2 ;;
    --libessence2)  LES_OVERRIDE="$2"; shift 2 ;;
    -*)             echo "unknown flag $1" >&2; exit 2 ;;
    *)              TAG="$1"; shift ;;
  esac
done
TAG="${TAG:-2.13.8}"

W="${TMPDIR:-/tmp}/e2x2link.$$"
mkdir -p "$W/pkg/Sources/Probe"
trap 'rm -rf "$W"' EXIT

cat > "$W/pkg/Package.swift" <<PKG
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Probe",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "Probe", targets: ["Probe"])],
    dependencies: [
        .package(url: "https://github.com/bithuman-product/homebrew-bithuman.git", exact: "$TAG")
    ],
    targets: [.target(name: "Probe", dependencies: [
        .product(name: "Expression2", package: "homebrew-bithuman"),
        .product(name: "Essence2", package: "homebrew-bithuman")])]
)
PKG
echo 'import Expression2' > "$W/pkg/Sources/Probe/Probe.swift"
echo 'public enum Probe {}' >> "$W/pkg/Sources/Probe/Probe.swift"

echo "== resolving the PUBLISHED tag $TAG (no credential) =="
( cd "$W/pkg" && swift package resolve ) || { echo "RESOLVE FAILED"; exit 1; }
AR="$W/pkg/.build/artifacts/homebrew-bithuman"
[ -d "$AR" ] || { echo "no artifacts under $AR"; exit 1; }

# ★THE ARTIFACT DIRECTORY IS NAMED FOR THE *TARGET*, NOT THE MODULE, AND THE
# TARGETS WERE RENAMED. Expression2 -> Expression2Binary, UnifiedModelHeader ->
# UnifiedModelHeaderBinary (2026-09-11, so the two packages that BUILD those
# modules from source can take this package as a dependency without a
# target-name clash). This script hard-coded the old directory names and would
# have silently linked nothing from them. Discover the directory from the
# xcframework it contains instead, and refuse if it is not there.
xcf () {  # $1 = xcframework base name -> prints the .xcframework path
  local n="$1" p
  p="$(find "$AR" -maxdepth 2 -type d -name "$n.xcframework" | head -1)"
  [ -n "$p" ] || { echo "MISSING $n.xcframework under $AR" >&2; exit 1; }
  printf '%s\n' "$p"
}
XCF_EXPR2="$(xcf Expression2)"       || exit 1
XCF_BEP="$(xcf BithumanEngineProtocol)" || exit 1
XCF_UMH="$(xcf UnifiedModelHeader)"  || exit 1
XCF_ORT="$(xcf onnxruntime)"         || exit 1
if [ -n "$LES_OVERRIDE" ]; then
  [ -d "$LES_OVERRIDE" ] || { echo "no such xcframework: $LES_OVERRIDE" >&2; exit 1; }
  XCF_LES="$LES_OVERRIDE"
  echo "== libessence2 OVERRIDDEN with a local build: $XCF_LES"
else
  XCF_LES="$(xcf libessence2)"       || exit 1
fi

cat > "$W/app.swift" <<'SW'
import Expression2
import Essence2
@main struct App { static func main() {
  print(Expression2Container.headerLength, be_essence2_quiesce_all(0)) } }
SW
# The OTHER app a developer writes, and the one the second half of the fix is
# for: Essence2 alone, no Expression2 anywhere in the graph.
cat > "$W/app-essence2-only.swift" <<'SW'
import Essence2
@main struct App { static func main() {
  print(be_essence2_quiesce_all(0)) } }
SW

arm () { # label sdk target slice ortslice umh load [essence2only]
  local lab=$1 sdk=$2 tgt=$3 slice=$4 ortslice=$5 umh=$6 load=$7 only="${8:-no}"
  local F=() SRC="$W/app.swift"
  if [ "$only" = yes ]; then
    SRC="$W/app-essence2-only.swift"
    F=(-F "$XCF_ORT/$ortslice" -framework onnxruntime)
  else
    F=(-F "$XCF_EXPR2/$slice"
       -F "$XCF_BEP/$slice"
       -F "$XCF_ORT/$ortslice"
       -framework Expression2 -framework BithumanEngineProtocol -framework onnxruntime)
  fi
  F+=(-F "$XCF_UMH/$slice")
  [ "$umh" = yes ] && F+=(-framework UnifiedModelHeader)
  local LES="$XCF_LES/$slice"
  # ★HOW THE TWO ARCHIVES ARE LOADED DECIDES WHETHER THE DEFECT IS VISIBLE, AND
  # A SINGLE LINK SHAPE IS NOT AN ANSWER. ld pulls a static-archive MEMBER only
  # when something still-undefined needs it, and BOTH of these are static
  # archives (UnifiedModelHeader.framework's binary is one object made by
  # `libtool -static`). So whether the collision fires depends on which members
  # get pulled — which depends on the app.
  #
  # MEASURED on the published essence2-v1.9.0 + v2.6.3 bytes, ONE source, five
  # link shapes, 2026-09-21 on echelon:
  #
  #     shape                                   macos-arm64   ios-arm64
  #     lazy (both archives lazy)               rc=0          rc=1 dup=113
  #     -force_load libessence2.a only          rc=0          rc=0
  #     -force_load BOTH archives               rc=1 dup=113  rc=1 dup=113
  #     -force_load the UMH framework only      rc=0          rc=1 dup=113
  #     libessence2.a BEFORE the frameworks     rc=0          rc=1 dup=113
  #
  # Two readings matter. (1) `-force_load libessence2.a` alone HIDES the defect
  # — every essence-2 member is in before the framework is consulted, so the
  # framework's one object is never pulled. An instrument built only on that
  # shape would have called the defect fixed while it was live. (2) macos-arm64
  # is NOT immune: it needs both archives fully loaded, which is what an app
  # that force-loads its engines does, and then it is red with the same 113.
  # So this script runs `lazy` and `force_both` on every slice.
  local LOAD=(-Xlinker "$LES/libessence2.a")
  local UMHBIN="$XCF_UMH/$slice/UnifiedModelHeader.framework/UnifiedModelHeader"
  case "$load" in
    lazy)       LOAD=(-Xlinker "$LES/libessence2.a") ;;
    force_les)  LOAD=(-Xlinker -force_load -Xlinker "$LES/libessence2.a") ;;
    force_both) LOAD=(-Xlinker -force_load -Xlinker "$LES/libessence2.a")
                [ "$umh" = yes ] && LOAD+=(-Xlinker -force_load -Xlinker "$UMHBIN") ;;
    *) echo "unknown load mode $load" >&2; exit 2 ;;
  esac
  local log="$W/$lab.log"
  xcrun -sdk "$sdk" swiftc -target "$tgt" -O -parse-as-library -swift-version 5 \
    -sdk "$(xcrun --sdk "$sdk" --show-sdk-path)" "${F[@]}" \
    -I "$LES/Headers" "${LOAD[@]}" -lc++ -lz \
    -framework CoreML -framework Metal -framework MetalPerformanceShaders \
    -framework MetalPerformanceShadersGraph -framework Accelerate \
    -framework AVFoundation -framework CoreMedia -framework CoreVideo \
    -framework VideoToolbox -framework Security -framework SystemConfiguration \
    -framework UniformTypeIdentifiers -framework QuartzCore -framework CoreGraphics \
    -framework ImageIO "$SRC" -o "$W/out_$lab" > "$log" 2>&1
  local rc=$? dup und
  dup=$(grep -c "duplicate symbol" "$log")
  # ★COUNT THE UNDEFINED SYMBOLS, NOT THE WORD, AND MATCH WHAT ld ACTUALLY
  # PRINTS. Two wrong readings were measured out of this line before it settled:
  # `grep -c UnifiedModelHeader` also counts the two archive PATHS ld prints
  # under every duplicate symbol (a duplicate-symbol failure reported 224
  # "undefined" lines while having none), and a mangled-name pattern matches
  # nothing at all because ld DEMANGLES:
  #     "static UnifiedModelHeader.EngineLoaderRegistry.shared.getter : …", referenced from:
  # The quoted name followed by `, referenced from:` is unique to the undefined
  # list; a duplicate symbol is printed as `duplicate symbol '…' in:`.
  und=$(grep -cE '^ *"[^"]*UnifiedModelHeader[^"]*", referenced from:' "$log")
  printf '  %-22s slice=%-20s UMH=%-3s load=%-11s rc=%s dup=%-4s undef_umh=%s\n' \
         "$lab" "$slice" "$umh" "$load" "$rc" "$dup" "$und"
  echo "$rc $dup $und" > "$W/$lab.rc"
}

IOS=(iphoneos        arm64-apple-ios26.0           ios-arm64           ios-arm64)
MAC=(macosx          arm64-apple-macos26.0         macos-arm64         macos-arm64_x86_64)
SIM=(iphonesimulator arm64-apple-ios26.0-simulator ios-arm64-simulator ios-arm64_x86_64-simulator)

echo "== BOTH products in one app =="
arm DEVICE_lazy      "${IOS[@]}" yes lazy
arm DEVICE_forceboth "${IOS[@]}" yes force_both
arm MACOS_lazy       "${MAC[@]}" yes lazy
arm MACOS_forceboth  "${MAC[@]}" yes force_both
arm SIM_lazy         "${SIM[@]}" yes lazy
arm SIM_forceboth    "${SIM[@]}" yes force_both

# ★THE TRAP THAT HAS BLOCKED THIS FIX, MEASURED RATHER THAN ASSERTED. Removing
# the objects from the archive and stopping there does not fix anything — it
# moves the failure onto the OTHER app, the one that takes Essence2 alone. The
# `_with_umh` arms below are what the `Essence2` product must make true for
# that app by listing UnifiedModelHeaderBinary in its targets; the `_no_umh`
# arms are the same app WITHOUT that half, and they are supposed to be red
# once the archive is clean.
# ★THE TRAP THAT HAS BLOCKED THIS FIX, MEASURED RATHER THAN ASSERTED. Removing
# the objects from the archive and stopping there does not fix anything — it
# moves the failure onto the OTHER app, the one that takes Essence2 alone. These
# arms force-load libessence2.a so EVERY member is in and nothing can be missed
# by laziness: `_with_umh` is what the `Essence2` product must make true by
# listing UnifiedModelHeaderBinary, `_no_umh` is the same app without that half.
echo "== Essence2 ALONE (no Expression2 in the graph), libessence2.a force-loaded =="
arm E2ONLY_DEV_with_umh "${IOS[@]}" yes force_les yes
arm E2ONLY_DEV_no_umh   "${IOS[@]}" no  force_les yes
arm E2ONLY_MAC_with_umh "${MAC[@]}" yes force_les yes
arm E2ONLY_MAC_no_umh   "${MAC[@]}" no  force_les yes
arm E2ONLY_SIM_with_umh "${SIM[@]}" yes force_les yes

read -r e1 _ eu1 < "$W/E2ONLY_DEV_with_umh.rc"
read -r e2 _ eu2 < "$W/E2ONLY_MAC_with_umh.rc"
read -r e3 _ eu3 < "$W/E2ONLY_SIM_with_umh.rc"
read -r t1 _ tu1 < "$W/E2ONLY_DEV_no_umh.rc"
read -r t2 _ tu2 < "$W/E2ONLY_MAC_no_umh.rc"

fail=0
echo
echo "discriminator — Essence2 ALONE, force-loaded, WITHOUT the framework:"
if [ "$t1" = 0 ] && [ "$t2" = 0 ]; then
  echo "  it LINKS on both -> libessence2.a still DEFINES the UnifiedModelHeader"
  echo "  symbols; these are the OLD bytes."
else
  echo "  it FAILS (ios rc=$t1 undef=$tu1, macos rc=$t2 undef=$tu2) -> the archive"
  echo "  REFERENCES UnifiedModelHeader instead of defining it, which is the"
  echo "  FIXED archive. An Essence2-ONLY app therefore needs"
  echo "  UnifiedModelHeaderBinary in the \`Essence2\` product — that is the"
  echo "  second half, and the arms above say whether it is in place."
fi
echo
echo "BOTH products in one app — every slice, both link shapes:"
for a in DEVICE_lazy DEVICE_forceboth MACOS_lazy MACOS_forceboth SIM_lazy SIM_forceboth; do
  read -r r d _ < "$W/$a.rc"
  [ "$r" = 0 ] || { fail=1; printf '  RED  %-18s rc=%s duplicate_symbols=%s\n' "$a" "$r" "$d"; }
done
[ "$fail" = 0 ] && echo "  all green."
echo
echo "Essence2 ALONE, with the framework the product must supply:"
printf '  ios-arm64 rc=%s undef=%s   macos-arm64 rc=%s undef=%s   simulator rc=%s undef=%s\n' \
       "$e1" "$eu1" "$e2" "$eu2" "$e3" "$eu3"
if [ "$e1" != 0 ] || [ "$e2" != 0 ] || [ "$e3" != 0 ]; then
  fail=1
  echo "  RED: an Essence2-only app does NOT link. Do not ship the archive change"
  echo "  without the product change — this is the half that breaks every"
  echo "  Essence2-only consumer."
fi
echo
if [ "$fail" = 0 ]; then
  echo "COLLISION GONE: Expression2 + Essence2 links on every slice in both link"
  echo "shapes, and Essence2 alone still links with 0 undefined symbols."
  exit 0
fi
echo "NOT FIXED on these bytes. Root fix, both halves:"
echo "  1. models/essence-2/engine/light/apple/build-xcframework.sh must stop"
echo "     libtool'ing the UnifiedModelHeader objects into libessence2.a;"
echo "  2. the \`Essence2\` product must then list UnifiedModelHeaderBinary."
exit 1
