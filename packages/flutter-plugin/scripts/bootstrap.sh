#!/usr/bin/env bash
# bootstrap.sh — provision the bitHuman avatar UMBRELLA Flutter plugin (Layer 2).
#
# This repo (bithuman-avatar-plugin) is the app's SINGLE Flutter dependency. It
# is engine-agnostic glue (BithumanAvatarPlugin + RealtimeAudioIO + Converse* +
# the FlutterTexture) + the on-device brain libconverse, and it AGGREGATES N
# engine SDKs (each a Layer-1 sdk/ in its own repo) statically (design §2.2).
#
# What it provisions:
#   • libconverse.xcframework — the on-device conversation brain (llama.cpp +
#     Supertonic). The ONE module-map xcframework (INVARIANT #1). Not an avatar
#     engine — it stays the umbrella's own dependency, fetched here.
#   • Each engine SDK, via the N-ENGINE LOOP: locate <engine>/sdk (a
#     BITHUMAN_<ENGINE>_DIR dev override, a sibling checkout, or a gh clone), run
#     its own bootstrap (which fetches/extracts its native deps), then STAGE its
#     surfaces under <plat>/Engines/<engine>/ so the podspec picks them up:
#       Engines/<engine>/Classes/*.swift  ← compiled into the pod (one umbrella module)
#       Engines/<engine>/include/*.h       ← folded into the pod umbrella (e.g. be_essence2.h)
#       Engines/<engine>/Vendor/lib*.a     ← s.vendored_libraries (PLAIN STATIC LIB)
#       Engines/<engine>/Vendor/*-resources ← s.resources
#     INVARIANT #1: an engine's native core is a PLAIN STATIC .a, NEVER a 2nd
#     module-map xcframework (libconverse keeps the single slot).
#
# Engines (M2): expression2 (REQUIRED — the default embody engine, source-only) +
# essence2 (OPTIONAL on-device Essence2; a missing SDK / download degrades to
# embody-only via the ESSENCE2_AVAILABLE gate). A 3rd engine = one line in ENGINES.
#
# expression2 is SOURCE-ONLY: its bootstrap fetches the embody CoreML MODEL bundle
# (no static lib), which the umbrella stages to <plat>/Assets/embody — the FROZEN landing
# Expression2Runtime/Expression2Engine probes via Bundle subdirectory "embody" and
# the app's Runner "Bundle embody models" phase reads.
#
# Two modes:
#   • SELF-CONTAINED (default): download + sha256-verify the libconverse vendor
#     bundle from the embody Release, then run each engine SDK's bootstrap.
#   • DEV override: BITHUMAN_SDK_DIR=/path/to/bithuman-models/models/essence-1
#     symlinks libconverse from that checkout's sdk/swift/vendor surface; embody
#     models load from ~/embody-ane at runtime; each engine SDK bootstrap runs
#     in its own DEV mode.
#
# Nothing under <plat>/Frameworks/, <plat>/Engines/, or <plat>/Assets/embody/ is
# committed. Re-running is safe. Apache-2.0; (c) bitHuman.

set -euo pipefail

PLUGIN_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

EXPRESSION2_VENDOR_TAG="${EXPRESSION2_VENDOR_TAG:-expression2-vendor-v1}"
EXPRESSION2_VENDOR_REPO="${EXPRESSION2_VENDOR_REPO:-bithuman-product/bithuman-models}"

# The STATIC, non-SME2 ONNX Runtime 1.26.0 the essence2 (a2x) decoder's le_a2x
# GEMM runs on. Built from source so it never emits SME2 instructions (those
# SIGILL on the A19 / iPhone 17 CPU). The iOS pod vendors it as
# Frameworks/onnxruntime.xcframework; macOS resolves ORT from libconverse's
# bundled dylibs, so it is staged to the iOS Frameworks dir ONLY. Published as a
# GitHub release (onnxruntime.xcframework.zip + .sha256). A dev override
# (ORT_XCFRAMEWORK_DIR=/path/to/onnxruntime.xcframework) skips the download.
ORT_VENDOR_TAG="${ORT_VENDOR_TAG:-essence2-ort-vendor-1.26.0}"
ORT_VENDOR_REPO="${ORT_VENDOR_REPO:-bithuman-product/bithuman-models}"

# ======================================================= THE APPLE ENGINE PIN
# ★ A TAG OF THIS REPO MUST NAME AN ENGINE. The Android half already works this
# way — android/build.gradle names `ai.bithuman:essence2-android:0.5.8`, an
# immutable Maven coordinate committed beside the code that uses it, so
# `flutter-plugin-v2.6.1` names exactly one Android engine forever. The Apple
# half named none, and it cost us twice:
#
#   • THE BINARY. Until 2026-09-16 this script ran the engine SDK's own
#     bootstrap with no engine coordinate, so the tag came from a DEFAULT in
#     the PRIVATE repo — `LIBESSENCE2_RELEASE="${LIBESSENCE2_RELEASE-essence2-v1.2.0}"`,
#     last rolled 2026-09-06 and never moved again. essence2-v1.2.0 is a
#     PRE-RELEASE whose own title reads "superseded by essence2-v1.5.0", while
#     Package.swift (the SwiftPM path, same repo, same engine) served
#     essence2-v1.7.0. Two Apple paths, five releases apart, no gate between
#     them. Measured on the published bytes 2026-09-16: the v1.2.0 slices carry
#     0 `DriverCursor` and 0 `decoded IN PLACE`; the v1.7.0 slices carry 257 and
#     1. Nothing that ran on a device that day linked v1.2.0 — every Apple build
#     overrode the default by hand — but the pod's own committed assumptions
#     were written for it: `s.resources` globbed `a2x_w2v.*.onnx`, a name only
#     the v1.2.0-era archive ships, so the app carried no audio encoder at all
#     and `be_essence2_create` returned -2 on the first macOS run that day.
#
#   • THE SOURCE. `locate_engine_sdk` takes a ref and both call sites omitted
#     it, so the engine adapter Swift compiled into this pod came from
#     bithuman-models main HEAD **at bootstrap time**, into gitignored
#     directories, with no revision recorded anywhere. Two developers building
#     the same tag a week apart got different engine code and neither could
#     tell.
#
# So the coordinates live HERE, committed, immutable, beside the Android ones.
# The digests are the sha256 of the release assets and are checked by the
# engine SDK's bootstrap before anything is installed. `essence2Tag` in
# Package.swift and `LIBESSENCE2_RELEASE` below name the SAME release, and
# `scripts/check-apple-engine-pin.sh` refuses a commit where they do not — it
# also refuses a `BITHUMAN_MODELS_REF` that is not a full commit sha, because a
# branch name is not a pin. Roll the two together, never one alone.
#
# Env overrides stay honoured for development; the committed values are what a
# tag ships.

# The bithuman-models revision whose engine ADAPTER SOURCE (models/*/sdk/Classes)
# this pod compiles. A full 40-hex commit sha — never a branch.
# 05e443da9 = 2026-09-22, the tree the essence2-v1.10.0 Apple build ran on
# — bithuman-models #1082: libessence2.a stops carrying the UnifiedModelHeader
# objects, which is what made an app taking both published Apple products
# collide on 112 duplicate symbols. VERIFIED, not assumed: the annotated tag
# essence2-apple-v1.10.0 dereferences to exactly this commit, and the release it
# cut reads `UnifiedModelHeader defined=0` on all three slices.
# ★THIS SHA IS WHY THE UnifiedModelHeader STAGING BELOW IS NOT OPTIONAL: the
# archive this tree produces REFERENCES that module (14 symbols on ios-arm64 and
# macos-arm64, 6 on the simulator) instead of defining it.
# (It read 92d9d9d56 — the essence2-v1.9.0 tree — until this bump. That pin is
# what decides which engine ADAPTER SOURCE the pod compiles, so it moves with
# the engine or the pod compiles one release's Swift against another's bytes.)
# ★MOVED 2026-09-23 to ec9a3ab83 — the tree Expression2 v2.6.5 was built from, which also
# carries the essence2-v1.11.0 engine sources (essence2-apple-v1.11.0 = 295e3aaf2, an
# ancestor; no Apple-engine source changed between them): the first Apple session meter
# for Expression 2 (#1165), talking-time billing + the 300 s online grace on both engines,
# the BITHUMAN_API_KEY alias (#1144), and create() naming a metering refusal (#1183).
# ★MOVED 2026-09-23 to 6ff1fd069 — the tree essence2-apple-v1.12.0 was built from (essence2-v1.12.0: the Swift Essence2Kit
# engine's C half, be_essence2_last_refusal, clean slices — bithuman-models #1224).
# ★MOVED 2026-09-23 to 8bae6d8f3 — the tree essence2-apple-v1.12.1 was built from (essence2-v1.12.1: slices without module
# breadcrumbs — bithuman-models #1263).
# ★MOVED 2026-09-23 to fd37bdfb7: the tree Expression2 v2.7.0 was built from (the x2 lip-sync hold, #1279;
# Expression2Download). The essence-2 adapter sources are unchanged since essence2-apple-v1.12.1 (8bae6d8f3).
BITHUMAN_MODELS_REF="${BITHUMAN_MODELS_REF:-fd37bdfb78ceffa8f1a64233e0215501f77ca169}"

# ★MOVED 2026-09-26 to essence2-v1.14.1 (bithuman-models #1516 @ b4a331443): a Release engine cannot be switched
# unmetered or pointed at another meter endpoint. The C interface is unchanged; BITHUMAN_MODELS_REF stays.
# ★MOVED 2026-09-26 to essence2-v1.14.0 (bithuman-models #1473, essence2-apple-v1.14.0 @ 3485848d2): the engine's
# meter names the install (a UUIDv4 in Application Support, not ""), and the C interface gains two ADDITIVE calls
# (be_essence2_end_utterance, be_essence2_last_frame_kind) the adapter does not need, so BITHUMAN_MODELS_REF stays.
# ★MOVED 2026-09-25 to essence2-v1.13.0 (bithuman-models #1461, essence2-apple-v1.13.0 @ 2cc2a334f): the
# engine carries NO MLX, so an app with its own MLX pod links beside it under CocoaPods' -ObjC; the resources
# archive has no .bundle any more (the *.bundle glob in the podspecs is empty, correctly). The C interface is
# unchanged, so BITHUMAN_MODELS_REF (the engine ADAPTER source) stays where Expression2 v2.7.0 put it.
# The essence-2 Apple ENGINE + its runtime RESOURCES. One release carries both.
# Must equal `essence2Tag` in Package.swift; the digests must equal that file's
# `libessence2.xcframework.zip` binaryTarget checksum and the release's own
# resources sidecar. Passed to the engine SDK bootstrap explicitly below.
LIBESSENCE2_RELEASE="${LIBESSENCE2_RELEASE:-essence2-v1.14.1}"
LIBESSENCE2_SHA256="${LIBESSENCE2_SHA256:-e999f6aabd5be8e958cb1b3ddccaf4c55d4e52e282380afe8b7af6707f39b1bd}"
LIBESSENCE2_RESOURCES_RELEASE="${LIBESSENCE2_RESOURCES_RELEASE:-essence2-v1.14.1}"
LIBESSENCE2_RESOURCES_SHA256="${LIBESSENCE2_RESOURCES_SHA256:-6a133791471ea92220bc296076eedebb259d5c2b72e20e5d121f0273b56ac6db}"

# The UnifiedModelHeader module, as a plain static .a per slice.
#
# ★WHY A POD THAT NEVER WRITES `import UnifiedModelHeader` HAS TO STAGE IT.
# From essence2-v1.10.0 `libessence2.a` no longer DEFINES the UnifiedModelHeader
# symbols — it was libtool'd from the engine's whole Swift closure and that
# closure carried them, which made any app that linked BOTH published Apple
# products collide on 112 duplicate symbols. The archive now REFERENCES them
# (14 on ios-arm64 / macos-arm64, 6 on the simulator), so whatever links
# libessence2.a must also link something that defines them, or the Runner app
# fails at its FINAL link with
#     "static UnifiedModelHeader.EngineLoaderRegistry.shared.getter : …",
#       referenced from: libessence2.a[5](UnifiedEngineDispatch.o)
# — a failure this pod's own build never shows, because a pod is compiled, not
# linked.
#
# It goes in beside libessence2.a as a PLAIN STATIC LIB, which is exactly what
# INVARIANT #1 in both podspecs demands and what their
# `Engines/*/Vendor/*.a` glob already picks up — so neither podspec changes.
# The bytes come from the same public tap release the SwiftPM
# `UnifiedModelHeaderBinary` binaryTarget pins, at `expression2Tag`; the digest
# below is that binaryTarget's checksum, and a mismatch is a refusal.
# ★It read v2.6.3 (a8bf748c…) after Package.swift had moved to v2.6.4 (the Swift
# SDK tag v2.14.1), so the plugin tag and the SDK tag named different
# UnifiedModelHeader bytes — nothing compared them. scripts/check-apple-engine-pin.sh
# now does (A6): these two values must equal `expression2Tag` and the
# UnifiedModelHeaderBinary checksum in Package.swift.
# ★THE EXPRESSION 2 ENGINE IS LINKED AS THE PUBLISHED BINARY (2026-09-26). Until 2.6.18 this script
# cloned the PRIVATE bithuman-models repo for the engine adapters' Swift source, so the iOS/macOS half
# of every published plugin tag failed with a 404 for anyone outside the company. The plugin now links
# the three xcframeworks the Swift package's `Expression2` product ships (Expression2,
# BithumanEngineProtocol, UnifiedModelHeader), from the same tap release and checked against the same
# checksums Package.swift pins; the Essence 2 adapter is the plugin's own (shared/Classes). No engine
# source is fetched, from anywhere. X2_XCF_DIR=<dir holding the three zips> stages a candidate build.
EXPRESSION2_RELEASE="${EXPRESSION2_RELEASE:-v2.8.0}"
EXPRESSION2_SHA256="${EXPRESSION2_SHA256:-__X2_SHA__}"
BEP_SHA256="${BEP_SHA256:-__BEP_SHA__}"
UMH_RELEASE="${UMH_RELEASE:-v2.8.0}"
UMH_SHA256="${UMH_SHA256:-__UMH_SHA__}"

# ---------------------------------------------------------------- PUBLIC vendor
# The build outputs above also live on a PUBLIC, versioned, immutable release, so
# a clone with no credential can fetch them. Digests are PINNED HERE, not read
# from beside the download: a 200 means a server answered, not that the bytes are
# the bytes, and a sidecar fetched from the same place as the asset is not an
# independent check. The release also ships manifest.json (size + sha256 per
# asset + the tar's full member list) for a human to verify against; this script
# trusts the pin below.
PUBLIC_VENDOR_TAG="${PUBLIC_VENDOR_TAG:-flutter-plugin-vendor-v1}"
PUBLIC_VENDOR_BASE="${PUBLIC_VENDOR_BASE:-https://github.com/bithuman-product/homebrew-bithuman/releases/download/$PUBLIC_VENDOR_TAG}"
PUBLIC_SHA_embody_models="c224f7174479db913fabe8823029e9bdeb70bde6efc49f11bfd0495010b8031f"
PUBLIC_SHA_onnxruntime="7d631c161ae0d9c6f01095bcb5556d0b4f0205dc5111e6d2ddae82cc7050a7ed"

# fetch_public <asset-name> <expected-sha256> <dest-dir> -> 0 on success
# Anonymous (no gh, no token). Verifies the PINNED digest and REFUSES on mismatch
# rather than installing bytes it cannot account for.
fetch_public() {
    local name="$1" want="$2" dir="$3"
    command -v curl >/dev/null 2>&1 || return 1
    curl -fsSL --retry 2 -o "$dir/$name" "$PUBLIC_VENDOR_BASE/$name" || return 1
    local got; got="$(shasum -a 256 "$dir/$name" | cut -d' ' -f1)"
    if [ "$got" != "$want" ]; then
        die "sha256 MISMATCH for $name from $PUBLIC_VENDOR_TAG — refusing to install
  expected $want
  actual   $got"
    fi
    log "  $name verified against the pinned digest ($got)"
    return 0
}

log()  { printf '\033[1;36m[bootstrap]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[bootstrap]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[bootstrap]\033[0m %s\n' "$*" >&2; exit 1; }

# Symlink target -> destination (relative), replacing existing links/dirs.
relink() {
    local target="$1" dest="$2"
    [ -e "$target" ] || { warn "missing $target"; return 1; }
    rm -rf "$dest"
    mkdir -p "$(dirname "$dest")"
    local rel_target
    rel_target=$(python3 -c \
        "import os, sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" \
        "$target" "$(dirname "$dest")")
    ln -s "$rel_target" "$dest"
}

# ------------------------------------------------- generic engine SDK locator
# Every engine's Layer-1 sdk/ lives in the PRIVATE engine monorepo
# bithuman-product/bithuman-models under models/<engine>/sdk. Locate one
# engine's sdk/ by: (1) BITHUMAN_<ENGINE>_DIR dev override, (2) a sibling
# bithuman-models checkout next to this repo, (3) ONE shared shallow clone of
# the monorepo into a cache AT $ref (serves every engine).
# Sets ENGINE_SDK to the resolved sdk/ path (empty if not found), and
# ENGINE_SDK_REV to the revision it actually resolved (or "unpinned: <reason>"
# for 1 and 2, which are developer paths this script cannot pin).
#   $1 = slug (EXPRESSION2|ESSENCE2)  $2 = models/ dir name (expression-2|essence-2)
#   $3 = override env VALUE           $4 = ref (REQUIRED — the committed pin)
MODELS_REPO="${BITHUMAN_MODELS_REPO:-bithuman-product/bithuman-models}"
MODELS_CACHE="$HOME/.cache/bithuman/bithuman-models"
ENGINE_SDK=""
ENGINE_SDK_REV=""
# Print the revision of a checkout, or a reason it has none.
sdk_rev_of() {  # $1 = any path inside a git work tree
    ( cd "$1" && git rev-parse HEAD 2>/dev/null ) || echo "not-a-git-checkout"
}
locate_engine_sdk() {
    local slug="$1" model="$2" override="$3" ref="${4:-}"
    local cache="$MODELS_CACHE"
    ENGINE_SDK=""; ENGINE_SDK_REV=""
    [ -n "$ref" ] || die "locate_engine_sdk $slug called with no ref — the engine adapter source must be pinned (BITHUMAN_MODELS_REF)"
    # 1. explicit dev override (engine dir root OR its sdk/). A DEVELOPER path:
    # it wins over the pin by design, so say out loud what it resolved to —
    # the whole defect this pin fixes was an unrecorded revision.
    if [ -n "$override" ]; then
        if [ -f "$override/scripts/bootstrap.sh" ]; then
            ENGINE_SDK="$override"; ENGINE_SDK_REV="OVERRIDE BITHUMAN_${slug}_DIR @ $(sdk_rev_of "$override")"; return 0; fi
        if [ -f "$override/sdk/scripts/bootstrap.sh" ]; then
            ENGINE_SDK="$override/sdk"; ENGINE_SDK_REV="OVERRIDE BITHUMAN_${slug}_DIR @ $(sdk_rev_of "$override")"; return 0; fi
        warn "BITHUMAN_${slug}_DIR=$override has no (sdk/)scripts/bootstrap.sh"
    fi
    # 2. sibling bithuman-models checkout next to this umbrella repo. Also a
    # DEVELOPER path and also unpinned: whatever that tree is checked out at,
    # dirty or not, is what compiles into the pod. Named, for the same reason.
    if [ -f "$PLUGIN_ROOT/../bithuman-models/models/$model/sdk/scripts/bootstrap.sh" ]; then
        ENGINE_SDK="$(cd "$PLUGIN_ROOT/../bithuman-models/models/$model/sdk" && pwd)"
        ENGINE_SDK_REV="SIBLING CHECKOUT $PLUGIN_ROOT/../bithuman-models @ $(sdk_rev_of "$PLUGIN_ROOT/../bithuman-models")"
        return 0
    fi
    # 3. one shared shallow clone of the monorepo into a cache, checked out AT
    # THE PIN. This is the reproducible path — the one a clean clone takes.
    if [ ! -d "$cache/models" ]; then
        mkdir -p "$(dirname "$cache")"; rm -rf "$cache"
        log "Cloning $MODELS_REPO → $cache"
        # No `-b $ref`: the pin is a COMMIT SHA and `clone -b` takes only branch
        # and tag names. Clone the default branch shallow, then fetch the pin
        # itself below — `git fetch origin <sha>` is served for any commit
        # reachable from a ref, which a pin on main always is.
        if command -v gh >/dev/null 2>&1; then
            gh repo clone "$MODELS_REPO" "$cache" -- --depth 1 >/dev/null 2>&1 \
              || git clone --depth 1 "https://github.com/$MODELS_REPO.git" "$cache" >/dev/null 2>&1 || true
        else
            git clone --depth 1 "https://github.com/$MODELS_REPO.git" "$cache" >/dev/null 2>&1 || true
        fi
    fi
    if [ -d "$cache/.git" ]; then
        # Move the cache ONTO THE PIN. This must FAIL LOUD: the cache holds the
        # engine adapter SOURCE compiled into the pod, and a silently-stale
        # cache pins it forever while every log line reads success (found
        # 2026-07-06: an echelon cache frozen at a pre-dec_P2 Expression2Engine
        # because the plain-git refresh of the PRIVATE repo had no credentials
        # and the old `|| true` swallowed the failure). gh's credential helper
        # carries the auth (gh auth login / GH_TOKEN); plain git is the fallback
        # for public/credential-cached setups. Cheap to re-run: a cache already
        # at the pin fetches one commit it already has.
        if ! ( cd "$cache" && { \
                 if command -v gh >/dev/null 2>&1; then \
                     git -c credential.helper='!gh auth git-credential' fetch -q --depth 1 origin "$ref"; \
                 else \
                     git fetch -q --depth 1 origin "$ref"; \
                 fi; } && git checkout -q FETCH_HEAD ) >/dev/null 2>&1; then
            die "engine SDK checkout of the PIN FAILED ($MODELS_REPO @ $ref, cache $cache) — refusing to stage an engine adapter this script cannot name.
  Fix: gh auth login (or export GH_TOKEN), or rm -rf $cache to re-clone, or set BITHUMAN_${slug}_DIR / place a sibling bithuman-models checkout."
        fi
    fi
    if [ -f "$cache/models/$model/sdk/scripts/bootstrap.sh" ]; then
        ENGINE_SDK="$cache/models/$model/sdk"; ENGINE_SDK_REV="PINNED $(sdk_rev_of "$cache")"; return 0
    fi
    return 1
}

# ---------------------------------------------- engine #1: expression2 (REQUIRED)
# Source-only (pure Swift/CoreML). Its bootstrap fetches the embody CoreML model
# bundle into its Vendor/embody (no static lib); the umbrella stages Classes into
# Engines/expression2/Classes and the models into Assets/embody (FROZEN landing).
# $1 = extra env to pass the engine bootstrap (e.g. EMBODY_VENDOR_SRC=...).
# fetch_tap_zip <release> <file> <sha256> <dest dir>: a public tap release asset, sha256-checked.
fetch_tap_zip() {
    local rel="$1" name="$2" want="$3" dir="$4"
    local url="https://github.com/bithuman-product/homebrew-bithuman/releases/download/$rel/$name"
    curl -fsSL --retry 2 -o "$dir/$name" "$url" || die "could not fetch $url"
    local got; got="$(shasum -a 256 "$dir/$name" | cut -d' ' -f1)"
    [ "$got" = "$want" ] || die "sha256 MISMATCH for $name ($rel) — refusing to install
  expected $want
  actual   $got"
}

# The Expression 2 engine: the three binary xcframeworks the Swift package vends, into
# {macos,ios}/Frameworks, plus the identity-agnostic embody graphs into {macos,ios}/Assets/embody.
stage_expression2() {
    local embody_src="${1:-}" dl z
    dl="$(mktemp -d)"
    if [ -n "${X2_XCF_DIR:-}" ]; then
        log "Staging Expression 2 from X2_XCF_DIR=$X2_XCF_DIR (candidate)"
        for z in Expression2 BithumanEngineProtocol UnifiedModelHeader; do
            cp "$X2_XCF_DIR/$z.xcframework.zip" "$dl/" || die "X2_XCF_DIR has no $z.xcframework.zip"
        done
    else
        log "Fetching Expression 2 $EXPRESSION2_RELEASE (Expression2 + BithumanEngineProtocol + UnifiedModelHeader) …"
        fetch_tap_zip "$EXPRESSION2_RELEASE" Expression2.xcframework.zip "$EXPRESSION2_SHA256" "$dl"
        fetch_tap_zip "$EXPRESSION2_RELEASE" BithumanEngineProtocol.xcframework.zip "$BEP_SHA256" "$dl"
        fetch_tap_zip "$UMH_RELEASE" UnifiedModelHeader.xcframework.zip "$UMH_SHA256" "$dl"
    fi
    for z in Expression2 BithumanEngineProtocol UnifiedModelHeader; do
        ( cd "$dl" && unzip -q -o "$z.xcframework.zip" ) || die "could not unzip $z.xcframework.zip"
        [ -d "$dl/$z.xcframework" ] || die "$z.xcframework.zip did not contain $z.xcframework/"
        for fw in "$MAC_FW" "$IOS_FW"; do
            mkdir -p "$fw"; rm -rf "$fw/$z.xcframework"; cp -R "$dl/$z.xcframework" "$fw/$z.xcframework"
        done
    done
    rm -rf "$dl" "$PLUGIN_ROOT/macos/Engines/expression2" "$PLUGIN_ROOT/ios/Engines/expression2"
    log "  staged Expression2 / BithumanEngineProtocol / UnifiedModelHeader xcframeworks → {macos,ios}/Frameworks"
    if [ -n "$embody_src" ] && [ -d "$embody_src" ]; then
        for plat in macos ios; do
            rm -rf "$PLUGIN_ROOT/$plat/Assets/embody"; mkdir -p "$PLUGIN_ROOT/$plat/Assets"
            cp -R "$embody_src" "$PLUGIN_ROOT/$plat/Assets/embody"
        done
        log "  staged the identity-agnostic embody graphs → {macos,ios}/Assets/embody"
    fi
}

# The Essence 2 engine: its C library (libessence2.a per slice + be_essence2.h) and runtime
# resources from the public tap release. The Swift adapter over it is the plugin's own
# (shared/Classes/Essence2Engine.swift). Optional: without it the plugin builds embody-only.
stage_essence2_plat() {  # $1=plat, $2=xcframework slice dir, $3=headers dir, $4=resources dir
    local plat="$1" slice="$2" hdr="$3" res="$4"
    local base="$PLUGIN_ROOT/$plat/Engines/essence2"
    rm -rf "$base"; mkdir -p "$base/include" "$base/Vendor"
    cp "$slice/libessence2.a" "$base/Vendor/libessence2.a"
    cp "$hdr/be_essence2.h" "$base/include/"
    [ -d "$res" ] && cp -R "$res" "$base/Vendor/essence2-resources"
    log "  staged essence2 → $plat/Engines/essence2 (be_essence2.h + libessence2.a + resources)"
}
stage_essence2() {
    rm -rf "$PLUGIN_ROOT/macos/Engines/essence2" "$PLUGIN_ROOT/ios/Engines/essence2"
    [ "${BITHUMAN_SKIP_ESSENCE2:-0}" = "1" ] && { log "BITHUMAN_SKIP_ESSENCE2=1 — embody-only build"; return 0; }
    local dl; dl="$(mktemp -d)"
    log "Fetching Essence 2 $LIBESSENCE2_RELEASE (${LIBESSENCE2_SHA256:0:16}…, resources ${LIBESSENCE2_RESOURCES_SHA256:0:16}…) …"
    fetch_tap_zip "$LIBESSENCE2_RELEASE" libessence2.xcframework.zip "$LIBESSENCE2_SHA256" "$dl"
    fetch_tap_zip "$LIBESSENCE2_RESOURCES_RELEASE" libessence2-resources.zip "$LIBESSENCE2_RESOURCES_SHA256" "$dl"
    ( cd "$dl" && unzip -q -o libessence2.xcframework.zip && mkdir -p res && unzip -q -o libessence2-resources.zip -d res ) \
        || die "could not unzip the Essence 2 archives"
    local x="$dl/libessence2.xcframework" res="$dl/res"
    [ -d "$res/libessence2-resources" ] && res="$res/libessence2-resources"
    stage_essence2_plat macos "$x/macos-arm64" "$x/macos-arm64/Headers" "$res"
    stage_essence2_plat ios   "$x/ios-arm64"   "$x/ios-arm64/Headers"   "$res"
    rm -rf "$dl"
}

case "$(uname -s)" in
    Darwin) ;;
    Linux)  log "Linux host — the Apple plugin builds on macOS only. Nothing to do."; exit 0 ;;
    *)      die "unsupported host: $(uname -s) — only macOS and Linux are supported" ;;
esac

MAC_FW="$PLUGIN_ROOT/macos/Frameworks"
IOS_FW="$PLUGIN_ROOT/ios/Frameworks"

# ----------------------------------- ORT (essence2 / a2x decoder) for iOS slice
# Stage the static, non-SME2 onnxruntime.xcframework into ios/Frameworks (the iOS
# pod vendors it unconditionally, so a fresh clone MUST have it or `pod install`
# fails). Fetched from the GitHub release (sha256-verified like libconverse), or
# from a local ORT_XCFRAMEWORK_DIR dev override. iOS only — macOS gets ORT from
# libconverse's bundled dylibs. A download failure FAILS LOUD (the iOS pod can't
# build without it); re-running is safe.
stage_onnxruntime_ios() {
    local dest="$IOS_FW/onnxruntime.xcframework"
    if [ -n "${ORT_XCFRAMEWORK_DIR:-}" ] && [ -d "$ORT_XCFRAMEWORK_DIR" ]; then
        log "Staging onnxruntime.xcframework (iOS) from ORT_XCFRAMEWORK_DIR=$ORT_XCFRAMEWORK_DIR"
        rm -rf "$dest"; mkdir -p "$IOS_FW"; cp -R "$ORT_XCFRAMEWORK_DIR" "$dest"; return 0
    fi
    local dl; dl="$(mktemp -d)"
    # PUBLIC first: no credential needed, so a clone works. Falls through to the
    # private release only if the public fetch fails.
    log "Fetching onnxruntime.xcframework from the public $PUBLIC_VENDOR_TAG …"
    if fetch_public onnxruntime.xcframework.zip "$PUBLIC_SHA_onnxruntime" "$dl"; then
        ( cd "$dl" && unzip -q -o onnxruntime.xcframework.zip )
        [ -d "$dl/onnxruntime.xcframework" ] || die "onnxruntime.xcframework.zip did not contain onnxruntime.xcframework/"
        rm -rf "$dest"; mkdir -p "$IOS_FW"; cp -R "$dl/onnxruntime.xcframework" "$dest"
        rm -rf "$dl"
        log "  staged onnxruntime.xcframework → ios/Frameworks (public $PUBLIC_VENDOR_TAG)"
        return 0
    fi
    warn "  public fetch failed — falling back to the private release"
    command -v gh >/dev/null 2>&1 \
        || die "gh CLI required to fetch onnxruntime.xcframework ($ORT_VENDOR_TAG) — or set ORT_XCFRAMEWORK_DIR"
    log "Fetching onnxruntime.xcframework '$ORT_VENDOR_TAG' from $ORT_VENDOR_REPO …"
    gh release download "$ORT_VENDOR_TAG" --repo "$ORT_VENDOR_REPO" \
        --pattern 'onnxruntime.xcframework.zip' --pattern 'onnxruntime.xcframework.zip.sha256' \
        --dir "$dl" --clobber \
        || die "gh release download failed (tag $ORT_VENDOR_TAG, repo $ORT_VENDOR_REPO)"
    [ -f "$dl/onnxruntime.xcframework.zip" ] && [ -f "$dl/onnxruntime.xcframework.zip.sha256" ] \
        || die "release $ORT_VENDOR_TAG missing onnxruntime.xcframework.zip(.sha256)"
    local expect actual
    expect="$(awk '{print $1}' "$dl/onnxruntime.xcframework.zip.sha256")"
    actual="$(shasum -a 256 "$dl/onnxruntime.xcframework.zip" | cut -d' ' -f1)"
    [ "$expect" = "$actual" ] || die "sha256 MISMATCH for onnxruntime.xcframework.zip — refusing to install
  expected $expect
  actual   $actual"
    log "  sha256 verified ($actual)"
    ( cd "$dl" && unzip -q -o onnxruntime.xcframework.zip )
    [ -d "$dl/onnxruntime.xcframework" ] || die "onnxruntime.xcframework.zip did not contain onnxruntime.xcframework/"
    rm -rf "$dest"; mkdir -p "$IOS_FW"; cp -R "$dl/onnxruntime.xcframework" "$dest"
    rm -rf "$dl"
    log "  staged onnxruntime.xcframework → ios/Frameworks (from $ORT_VENDOR_TAG)"
}

# ------------------------------------------------- Layer-0 protocol refresh (M0)
# The shared engine interface (BithumanEngine + EngineId/EngineCapabilities/
# AvatarRef) is committed IN-TREE at shared/Classes/Protocol/BithumanEngine.swift
# (so the load-bearing protocol always builds offline). Its canonical home is the
# bithuman-engine-protocol package; this best-effort hook refreshes the in-tree
# copy from a dev checkout when one is provided. No-op otherwise.
refresh_engine_protocol() {
    local src=""
    if [ -n "${BITHUMAN_PROTOCOL_DIR:-}" ]; then
        src="$BITHUMAN_PROTOCOL_DIR/Sources/BithumanEngineProtocol/BithumanEngine.swift"
    elif [ -f "$PLUGIN_ROOT/../bithuman-engine-protocol/Sources/BithumanEngineProtocol/BithumanEngine.swift" ]; then
        src="$PLUGIN_ROOT/../bithuman-engine-protocol/Sources/BithumanEngineProtocol/BithumanEngine.swift"
    fi
    [ -n "$src" ] && [ -f "$src" ] || return 0
    cp "$src" "$PLUGIN_ROOT/shared/Classes/Protocol/BithumanEngine.swift" \
        && log "Refreshed Layer-0 BithumanEngine.swift from $src"
}
refresh_engine_protocol

# ===================================================================== DEV mode
if [ -n "${BITHUMAN_SDK_DIR:-}" ]; then
    # BITHUMAN_SDK_DIR points at a bithuman-models models/essence-1 checkout dir
    # (its sdk/swift/vendor surface is populated by a dev build).
    SDK_VENDOR="$BITHUMAN_SDK_DIR/sdk/swift/vendor"
    [ -d "$SDK_VENDOR" ] || die "BITHUMAN_SDK_DIR set but vendor surface not found at $SDK_VENDOR (expected a bithuman-models models/essence-1 checkout with a built sdk/swift/vendor)"
    log "DEV mode — symlinking libconverse from $BITHUMAN_SDK_DIR (embody models come from ~/embody-ane/build_A42)"
    relink "$SDK_VENDOR/libconverse.xcframework" "$MAC_FW/libconverse.xcframework"
    relink "$SDK_VENDOR/libconverse.xcframework" "$IOS_FW/libconverse.xcframework"
    stage_onnxruntime_ios   # essence2 a2x decoder ORT for the iOS pod

    # N-engine loop (DEV): each engine SDK runs in its own DEV mode
    # (BITHUMAN_SDK_DIR propagates). expression2 models → ~/embody-ane at runtime;
    # essence2 libessence2 extracted from the SAME sibling SDK vendor surface.
    stage_expression2
    stage_essence2

    log "Done (dev mode). Expression2Runtime will load models from ~/embody-ane/build_A42."
    exit 0
fi

# ============================================================ SELF-CONTAINED mode
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SRC="$TMP/embody-vendor"
mkdir -p "$SRC"

# 1a. The embody CoreML models — PUBLIC, digest-pinned, no credential.
log "Fetching embody models from the public $PUBLIC_VENDOR_TAG …"
if fetch_public embody-models.tar.gz "$PUBLIC_SHA_embody_models" "$TMP"; then
    tar -xzf "$TMP/embody-models.tar.gz" -C "$SRC"
    [ -d "$SRC/embody-models" ] || die "embody-models.tar.gz did not contain embody-models/"
else
    # Private fallback: the combined bundle, which also carries libconverse.
    command -v gh >/dev/null 2>&1 \
        || die "public fetch failed and gh is unavailable — cannot obtain the embody models"
    log "  public fetch failed — falling back to '$EXPRESSION2_VENDOR_TAG' on $EXPRESSION2_VENDOR_REPO"
    gh release download "$EXPRESSION2_VENDOR_TAG" --repo "$EXPRESSION2_VENDOR_REPO" \
        --pattern 'embody-vendor.tar.gz*' --dir "$TMP" --clobber \
        || die "gh release download failed (tag $EXPRESSION2_VENDOR_TAG, repo $EXPRESSION2_VENDOR_REPO)"
    [ -f "$TMP/embody-vendor.tar.gz" ] && [ -f "$TMP/embody-vendor.tar.gz.sha256" ] \
        || die "release $EXPRESSION2_VENDOR_TAG is missing embody-vendor.tar.gz(.sha256)"
    EXPECT="$(tr -d '[:space:]' < "$TMP/embody-vendor.tar.gz.sha256")"
    ACTUAL="$(shasum -a 256 "$TMP/embody-vendor.tar.gz" | cut -d' ' -f1)"
    [ "$EXPECT" = "$ACTUAL" ] || die "sha256 MISMATCH for embody-vendor.tar.gz — refusing to install
  expected $EXPECT
  actual   $ACTUAL"
    log "  sha256 verified ($ACTUAL)"
    tar -xzf "$TMP/embody-vendor.tar.gz" -C "$TMP"
    [ -d "$SRC/embody-models" ] || die "bundle missing embody-models/"
fi

# 1b. libconverse.xcframework — the on-device conversation BRAIN. It is SDK and is
# NOT published, so a clone without access simply does not get it. That is a
# SUPPORTED configuration since the pod decides CONVERSE_AVAILABLE from the staged
# bytes: the cloud realtime path, the avatar, both engines, lipsync, barge-in and
# the idle loop all work without it; only localAudioStart/Stop/PushText are
# unavailable, and they refuse by name.
if [ -d "$SRC/libconverse.xcframework" ]; then
    log "Installing libconverse.xcframework → macos/Frameworks (ios → symlink)"
    mkdir -p "$MAC_FW" "$IOS_FW"
    rm -rf "$MAC_FW/libconverse.xcframework"
    cp -R "$SRC/libconverse.xcframework" "$MAC_FW/libconverse.xcframework"
    relink "$MAC_FW/libconverse.xcframework" "$IOS_FW/libconverse.xcframework"
elif command -v gh >/dev/null 2>&1 && gh release download "$EXPRESSION2_VENDOR_TAG" \
        --repo "$EXPRESSION2_VENDOR_REPO" --pattern 'embody-vendor.tar.gz' --dir "$TMP" --clobber >/dev/null 2>&1; then
    tar -xzf "$TMP/embody-vendor.tar.gz" -C "$TMP"
    if [ -d "$SRC/libconverse.xcframework" ]; then
        log "Installing libconverse.xcframework → macos/Frameworks (ios → symlink)"
        mkdir -p "$MAC_FW" "$IOS_FW"
        rm -rf "$MAC_FW/libconverse.xcframework"
        cp -R "$SRC/libconverse.xcframework" "$MAC_FW/libconverse.xcframework"
        relink "$MAC_FW/libconverse.xcframework" "$IOS_FW/libconverse.xcframework"
    fi
else
    warn "libconverse.xcframework unavailable — building WITHOUT the on-device brain."
    warn "  Unaffected: cloud realtime, the avatar, both engines, lipsync, barge-in, idle."
    warn "  Unavailable: localAudioStart / localAudioStop / localPushText."
fi

# 1c. onnxruntime.xcframework (static, non-SME2) — the essence2 a2x decoder
# runtime the iOS pod vendors. Staged to ios/Frameworks (sha256-verified).
stage_onnxruntime_ios

# 1d. Keep ONLY the identity-agnostic graphs of the embody bundle.
#
# ★THE VENDOR BUNDLE CARRIES A FACE THE PINNED ENGINE CANNOT START. Both vendor
# releases this script reads (the public flutter-plugin-vendor-v1 tarball and
# its private twin expression2-vendor-v1) were cut on 2026-07-01 from the A42
# demo: w2v_frontend + audiotokenizer (shared) PLUS student_v4 + canon + idle.mp4
# (one identity) + taehv_decode_T10 (the floor decoder retired 2026-08-11). They
# carry NO dec_p2_v3_all, and since the 2026-08-11 taehv retirement the engine
# at BITHUMAN_MODELS_REF refuses an identity without it. So the engine SDK's
# startability gate refused this bundle on every run, `die`d, and stage_expression2
# stopped AFTER `rm -rf Engines/expression2` and BEFORE copying the adapter
# source — measured 2026-09-23 from a clean clone at flutter-plugin-v2.6.9:
#     the staged embody bundle CANNOT START the current engine — missing: dec_p2_v3_all.mlpackage
# and the app build then failed at `cannot find 'Expression2Engine' in scope`
# (EngineRegistry.swift). That error is not an API mismatch between this pod and
# the published Swift SDK: the engine source was never staged at all.
#
# The fix is the shape the gate already recognises as correct: the IDENTITY-FREE
# bundle — the two identity-agnostic graphs and no face. Every identity reaches
# the engine as a downloaded or app-bundled `.avatar`, which carries its own
# student / dec_p2_v3_all / canon.f32 / idle.mp4 (the engine resolves those from
# `activeAgentDir` first). The bundled A42 face could not render on this engine
# anyway, so nothing that worked stops working; the app loses ~108 MB of bytes
# it could never use (student 88.5 MB, taehv 19.7 MB). The tarball's digest pin
# is unchanged — the bytes are still verified before anything is removed.
reduce_to_shared_graphs() {  # $1 = extracted embody-models dir
    local d="$1" m kept=0 dropped=""
    for m in w2v_frontend_cpuAndNE.mlpackage audiotokenizer_cpuAndNE.mlpackage; do
        [ -e "$d/$m" ] && kept=$((kept + 1))
    done
    [ "$kept" -eq 2 ] || die "the embody vendor bundle lacks an identity-agnostic graph (w2v_frontend / audiotokenizer) — $d holds: $(ls "$d" | tr '\n' ' ')"
    for m in "$d"/*; do
        case "$(basename "$m")" in
            w2v_frontend_cpuAndNE.mlpackage|audiotokenizer_cpuAndNE.mlpackage|warm.wav) ;;
            *) dropped="$dropped $(basename "$m")"; rm -rf "$m" ;;
        esac
    done
    log "  embody bundle reduced to the identity-agnostic graphs (w2v_frontend + audiotokenizer)"
    [ -z "$dropped" ] || log "    dropped (one identity the pinned engine cannot start, or retired):$dropped"
}
reduce_to_shared_graphs "$SRC/embody-models"

# 2. N-engine loop. expression2 reuses the bundle we already downloaded for
# libconverse (EMBODY_VENDOR_SRC → no re-download); essence2 fetches its own
# sha-pinned libessence2 release inside its SDK bootstrap.
stage_expression2 "$SRC/embody-models"
stage_essence2

log "Done. Self-contained — no sibling bithuman-sdk required."
log "    the product app lives in bithuman-apps at apps/jarvis (it pins this plugin by tag)"
