#!/usr/bin/env bash
# build-protocol-xcframework.sh — build BithumanEngineProtocol.xcframework from
# THIS repo's own Sources/BithumanEngineProtocol, on a macOS host.
#
# ★ WHY THIS SCRIPT EXISTS, AND WHY IT IS HERE RATHER THAN IN bithuman-models.
# The Layer-0 protocol's source has always lived here (public: it is what the
# engine SDKs compile against). Its BINARY, however, was produced as a
# by-product of bithuman-models' `models/expression-2/sdk/scripts/
# build-xcframework.sh`, which archives the engine SDK — a package that takes
# THIS package as a dependency — and lifts three modules out of one archive.
#
# That arrangement is now impossible, and the impossibility is what this file
# answers. SwiftPM requires target names AND product names to be unique across
# the whole graph, and this manifest publishes an `Expression2` product whose
# name the engine SDK also declares. Measured on echelon 2026-09-11:
#     multiple packages ('homebrew-bithuman', 'sdk') declare targets with a
#     conflicting name: 'Expression2'                 (before the …Binary rename)
#     The workspace contains multiple targets with the same GUID
#     'PACKAGE-PRODUCT:Expression2'                   (after it)
# The only tap revisions the engine SDK can resolve are the ones from before
# a59e0db published those products — all of them older than 41145b6, which is
# the commit that removed the enterprise-only tier name from this source. So the
# shipped BithumanEngineProtocol.xcframework was pinned to tap ef1036e4 and named
# the tier 12 times while the public source it claims to be had read clean for a
# day. A binary that can only be rebuilt from a stale revision is not a build.
#
# So the repo that OWNS the source now builds it. No dependency, no graph, no
# other package's manifest: `xcodebuild archive` of this package's own scheme.
#
# Everything below that is not about the scheme is deliberately IDENTICAL to the
# engine SDK's script, because the two binaries must stay interchangeable:
#   · three slices, arm64 only  (macOS, iOS device, iOS Simulator)
#   · BUILD_LIBRARY_FOR_DISTRIBUTION=YES, and the emitted .swiftinterface is
#     CHECKED per slice — without it the binary is locked to one toolchain
#   · one relocatable object -> `libtool -static` -> the framework's binary
#   · ditto -c -k --keepParent --norsrc --noextattr   (NOT --sequesterRsrc: on
#     macOS 26 xcodebuild stamps com.apple.provenance on every file, and the
#     sequestered form writes a second `__MACOSX` root the distribution gate
#     refuses)
#   · the checksum comes from `swift package compute-checksum`, written to a
#     .sha256 sidecar — never typed by a human
#
# Usage:  scripts/build-protocol-xcframework.sh <version> [outdir]
#   <version>  the release tag this zip will be attached to, minus the leading
#              "v". It is stamped into every slice's Info.plist, so a zip on tag
#              v2.6.1 says 2.6.1 and nothing else can.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"
OUT="${2:-$REPO_ROOT/.protocol-xcframework-build}"
MODULE=BithumanEngineProtocol
SCHEME=BithumanEngineProtocol

log() { printf '\033[1;36m[protocol]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[protocol]\033[0m %s\n' "$*" >&2; exit 1; }

[ -n "$VERSION" ] || die "usage: $0 <version, e.g. 2.6.1> [outdir]"
printf '%s' "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || die "version '$VERSION' is not X.Y.Z — it is stamped into every Info.plist."
[ "$(uname -s)" = Darwin ] || die "macOS host required (xcodebuild)."
command -v xcodebuild >/dev/null || die "xcodebuild not found — run xcode-select -s."
[ -d "$REPO_ROOT/Sources/$MODULE" ] || die "no Sources/$MODULE in $REPO_ROOT"

rm -rf "$OUT"; mkdir -p "$OUT/archives"

SLICES=(
  "macos:generic/platform=macOS"
  "ios:generic/platform=iOS"
  "iossimulator:generic/platform=iOS Simulator"
)

FWARGS=()
for s in "${SLICES[@]}"; do
  label="${s%%:*}"; dest="${s#*:}"
  log "archiving slice $label  ($dest)"
  xcodebuild archive \
    -workspace "$REPO_ROOT" -scheme "$SCHEME" \
    -destination "$dest" \
    -archivePath "$OUT/archives/$label.xcarchive" \
    -derivedDataPath "$OUT/dd-$label" \
    SKIP_INSTALL=NO BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    > "$OUT/archives/$label.log" 2>&1 \
    || { tail -40 "$OUT/archives/$label.log"; die "archive FAILED for slice $label — see $OUT/archives/$label.log"; }

  arch="$OUT/archives/$label.xcarchive"
  # The BuildProductsPath leaf is platform-suffixed (Release, Release-iphoneos,
  # Release-iphonesimulator), so it is DISCOVERED, never hardcoded.
  bpp="$(find "$OUT/dd-$label/Build/Intermediates.noindex/ArchiveIntermediates/$SCHEME/BuildProductsPath" \
           -maxdepth 1 -type d -name 'Release*' | sort | head -1)"
  [ -n "$bpp" ] && [ -d "$bpp" ] \
    || die "slice $label: no Release* BuildProductsPath under $OUT/dd-$label — the derived-data layout changed."

  stage="$OUT/stage/$label"; rm -rf "$stage"
  FW="$stage/${MODULE}.framework"
  mkdir -p "$FW/Modules" "$FW/Headers"

  obj="$(find "$arch/Products" -name "${MODULE}.o" | head -1)"
  [ -n "$obj" ] || die "slice $label produced no ${MODULE}.o under $arch/Products — the archive layout changed."
  libtool -static -o "$FW/$MODULE" "$obj" 2>/dev/null \
    || die "libtool -static FAILED for slice $label"

  [ -d "$bpp/${MODULE}.swiftmodule" ] \
    || die "slice $label has no ${MODULE}.swiftmodule in $bpp — nothing would be importable."
  cp -R "$bpp/${MODULE}.swiftmodule" "$FW/Modules/"
  ls "$FW/Modules/${MODULE}.swiftmodule/"*.swiftinterface >/dev/null 2>&1 \
    || die "slice $label has no .swiftinterface — BUILD_LIBRARY_FOR_DISTRIBUTION did not take effect; the binary would be toolchain-locked."

  cat > "$FW/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$MODULE</string>
  <key>CFBundleIdentifier</key><string>ai.bithuman.$MODULE</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$MODULE</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
</dict></plist>
PLIST
  FWARGS+=(-framework "$FW")
done

log "creating $MODULE.xcframework"
rm -rf "$OUT/$MODULE.xcframework"
xcodebuild -create-xcframework "${FWARGS[@]}" -output "$OUT/$MODULE.xcframework" \
  > "$OUT/create-$MODULE.log" 2>&1 \
  || { tail -40 "$OUT/create-$MODULE.log"; die "-create-xcframework FAILED — see $OUT/create-$MODULE.log"; }

( cd "$OUT" && rm -f "$MODULE.xcframework.zip" \
  && ditto -c -k --keepParent --norsrc --noextattr "$MODULE.xcframework" "$MODULE.xcframework.zip" )

# ★ THE ZIP IS GRADED BEFORE ITS CHECKSUM IS EVEN PRINTED, and by this repo's own
# vocabulary rules — the whole reason this script exists is a name that reached a
# published binary. Raw bytes on stdin: handed a path, Apple's strings(1) walks an
# ar archive's members and reads almost nothing of it.
log "grading every file of every slice"
python3 - "$REPO_ROOT" "$OUT" <<'GRADE'
import importlib.util, pathlib, re, subprocess, sys, tempfile
repo, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("g", str(repo / "scripts" / "guard-public-vocabulary.py"))
g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
rules = {r[0]: re.compile(r[1], re.I) for r in (g.TIER1 + g.TIER2) if r[0] in ("V12", "V13")}
assert sorted(rules) == ["V12", "V13"], rules
assert rules["V12"].search("essence" + "-2-" + "max") and rules["V13"].search("essence" + "2_" + "quality")

def read(p):
    with open(p, "rb") as fh:
        return subprocess.run(["strings", "-a"], stdin=fh, capture_output=True, check=True).stdout.decode("utf-8", "replace")

d = pathlib.Path(tempfile.mkdtemp())
(d / "red.bin").write_bytes(b"\xd7\xff\xfe" * 8 + b"\x00" + ("essence" + "-2-" + "max").encode() + b"\x00")
assert len(rules["V12"].findall(read(d / "red.bin"))) >= 1, "the reading path is BLIND"

files = sorted(p for p in (out / "BithumanEngineProtocol.xcframework").rglob("*") if p.is_file())
assert len(files) >= 3, f"only {len(files)} files in the xcframework"
red = 0
for f in files:
    s = read(f)
    for k, rx in rules.items():
        n = len(rx.findall(s))
        if n:
            red += n
            print(f"  RED {n:>3}  {k}  {f.relative_to(out)}")
print(f"  {len(files)} files read, {red} banned-name occurrence(s)")
sys.exit(1 if red else 0)
GRADE

CK="$(swift package compute-checksum "$OUT/$MODULE.xcframework.zip")"
printf '%s\n' "$CK" > "$OUT/$MODULE.xcframework.zip.sha256"
log "$MODULE.xcframework.zip  $(du -h "$OUT/$MODULE.xcframework.zip" | cut -f1)  checksum $CK"
log "done: $OUT"
