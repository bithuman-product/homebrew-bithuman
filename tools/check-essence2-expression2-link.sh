#!/bin/bash
# check-essence2-expression2-link.sh — does an APP that takes BOTH published
# products actually LINK?
#
# ★WHY THIS EXISTS AND WHY IT IS NOT `swift build`. Through 2026-09-08 the
# Package.swift header told developers, of `Essence2`: "Depend on it alongside
# either of the others." Nothing checked it, and it was false on the iOS DEVICE
# and on macOS: `libessence2.a` is libtool'd from the engine's whole library
# closure and that closure DEFINES the UnifiedModelHeader symbols (nm -g on the
# published archives: ios-arm64 317, ios-arm64-simulator 317, macos-arm64 321),
# while the `Expression2` product forces every consumer to link
# UnifiedModelHeader.xcframework, which defines 122 of its own. 116 duplicate
# symbols, `ld` exits 1.
#
# A package-level build is BLIND to this: a library target is compiled, never
# linked, so `xcodebuild -destination 'generic/platform=iOS' build` on a package
# taking BOTH products exits 0. So is a Simulator-only CI: the simulator arm is
# green on bytes carrying the same 317 definitions. Only an EXECUTABLE link
# sees it, on the device slice. That is what this script does.
#
# Four arms, and the two controls are the point — an instrument that only ever
# reports RED cannot tell you when the defect is gone:
#   ios-arm64            + UnifiedModelHeader.framework   EXPECT fail today
#   ios-arm64            - UnifiedModelHeader.framework   EXPECT link  (control)
#   macos-arm64          + UnifiedModelHeader.framework   EXPECT fail today
#   ios-arm64-simulator  + UnifiedModelHeader.framework   EXPECT link  (control)
#
# Exit 0 when the two CONTROL arms link. Exit 1 when a control arm fails (the
# instrument is broken) — and print, loudly, whether the two DEVICE/macOS arms
# still collide, which is the number that must reach 0 when the engine is
# rebuilt without those objects and `Essence2` takes the UnifiedModelHeader
# binaryTarget instead.
#
# Usage:  tools/check-essence2-expression2-link.sh [<tag>]
#         tag defaults to the version this checkout's Package.swift is for.
# Requires: macOS + Xcode. Resolves the tag from GitHub; no credential.
set -u
TAG="${1:-2.10.0}"
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

cat > "$W/app.swift" <<'SW'
import Expression2
import Essence2
@main struct App { static func main() {
  print(Expression2Container.headerLength, be_essence2_quiesce_all(0)) } }
SW

arm () { # label sdk target slice ortslice umh
  local lab=$1 sdk=$2 tgt=$3 slice=$4 ortslice=$5 umh=$6
  local F=(-F "$AR/Expression2/Expression2.xcframework/$slice"
           -F "$AR/BithumanEngineProtocolBinary/BithumanEngineProtocol.xcframework/$slice"
           -F "$AR/UnifiedModelHeader/UnifiedModelHeader.xcframework/$slice"
           -F "$AR/onnxruntime/onnxruntime.xcframework/$ortslice"
           -framework Expression2 -framework BithumanEngineProtocol -framework onnxruntime)
  [ "$umh" = yes ] && F+=(-framework UnifiedModelHeader)
  local LES="$AR/libessence2/libessence2.xcframework/$slice"
  local log="$W/$lab.log"
  xcrun -sdk "$sdk" swiftc -target "$tgt" -O -parse-as-library -swift-version 5 \
    -sdk "$(xcrun --sdk "$sdk" --show-sdk-path)" "${F[@]}" \
    -I "$LES/Headers" -Xlinker "$LES/libessence2.a" -lc++ -lz \
    -framework CoreML -framework Metal -framework MetalPerformanceShaders \
    -framework MetalPerformanceShadersGraph -framework Accelerate \
    -framework AVFoundation -framework CoreMedia -framework CoreVideo \
    -framework VideoToolbox -framework Security -framework SystemConfiguration \
    -framework UniformTypeIdentifiers -framework QuartzCore -framework CoreGraphics \
    -framework ImageIO "$W/app.swift" -o "$W/out_$lab" > "$log" 2>&1
  local rc=$? dup
  dup=$(grep -c "duplicate symbol" "$log")
  printf '  %-22s slice=%-20s UnifiedModelHeader=%-3s rc=%s duplicate_symbols=%s\n' \
         "$lab" "$slice" "$umh" "$rc" "$dup"
  echo "$rc $dup" > "$W/$lab.rc"
}

echo "== four arms =="
arm DEVICE_with_umh  iphoneos        arm64-apple-ios26.0            ios-arm64           ios-arm64                    yes
arm DEVICE_no_umh    iphoneos        arm64-apple-ios26.0            ios-arm64           ios-arm64                    no
arm MACOS_with_umh   macosx          arm64-apple-macos26.0          macos-arm64         macos-arm64_x86_64           yes
arm SIM_with_umh     iphonesimulator arm64-apple-ios26.0-simulator  ios-arm64-simulator ios-arm64_x86_64-simulator   yes

read -r c1 _ < "$W/DEVICE_no_umh.rc"
read -r c2 _ < "$W/SIM_with_umh.rc"
read -r d1 n1 < "$W/DEVICE_with_umh.rc"
read -r d2 n2 < "$W/MACOS_with_umh.rc"

if [ "$c1" != 0 ] || [ "$c2" != 0 ]; then
  echo "INSTRUMENT BROKEN: a CONTROL arm did not link (DEVICE_no_umh rc=$c1, SIM_with_umh rc=$c2)."
  echo "Fix the instrument before reading the arms above."
  exit 1
fi
echo "controls OK: both arms that must link, linked."
if [ "$d1" = 0 ] && [ "$d2" = 0 ]; then
  echo "COLLISION GONE: Expression2 + Essence2 links on ios-arm64 and macos-arm64."
  echo "Wire this script into .github/workflows/manifest-truth.yml now — it can"
  echo "go RED again the next time the engine archive absorbs the header objects."
  exit 0
fi
echo "COLLISION PRESENT (this is the known defect of essence2-v1.4.0):"
echo "  ios-arm64   rc=$d1 duplicate_symbols=$n1"
echo "  macos-arm64 rc=$d2 duplicate_symbols=$n2"
echo "An app taking BOTH published products cannot link on a device."
echo "Root fix: models/essence-2/engine/light/apple/build-xcframework.sh must stop"
echo "libtool'ing the UnifiedModelHeader objects into libessence2.a, and the"
echo "Essence2 product must then take the UnifiedModelHeader binaryTarget."
exit 0
