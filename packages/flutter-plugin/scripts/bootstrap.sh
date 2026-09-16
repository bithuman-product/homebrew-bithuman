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
# (no static lib), which the umbrella stages to Assets/embody — the FROZEN landing
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
# Nothing under <plat>/Frameworks/, <plat>/Engines/, or Assets/embody/ is
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
# 18e32a7e2 = 2026-09-16, the tree the essence2-v1.7.0 / v2.6.3 Apple builds ran on.
BITHUMAN_MODELS_REF="${BITHUMAN_MODELS_REF:-18e32a7e2ed523d87723a97d7dcc7a37b1f664ab}"

# The essence-2 Apple ENGINE + its runtime RESOURCES. One release carries both.
# Must equal `essence2Tag` in Package.swift; the digests must equal that file's
# `libessence2.xcframework.zip` binaryTarget checksum and the release's own
# resources sidecar. Passed to the engine SDK bootstrap explicitly below.
LIBESSENCE2_RELEASE="${LIBESSENCE2_RELEASE:-essence2-v1.7.0}"
LIBESSENCE2_SHA256="${LIBESSENCE2_SHA256:-ee21342f611d94c7a8a3ef497d8dfc67f146ff6513403b2741d6f6011f805b1f}"
LIBESSENCE2_RESOURCES_RELEASE="${LIBESSENCE2_RESOURCES_RELEASE:-essence2-v1.7.0}"
LIBESSENCE2_RESOURCES_SHA256="${LIBESSENCE2_RESOURCES_SHA256:-3274cf92ef211846cc62116c2aad1cd7015a8f2c9bf5b67677d4912a82e2c656}"

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
stage_expression2() {
    local extra_env="${1:-}"
    rm -rf "$PLUGIN_ROOT/macos/Engines/expression2" "$PLUGIN_ROOT/ios/Engines/expression2"
    if ! locate_engine_sdk EXPRESSION2 "expression-2" "${BITHUMAN_EXPRESSION2_DIR:-}" "$BITHUMAN_MODELS_REF"; then
        die "bithuman-models models/expression-2/sdk not found (set BITHUMAN_EXPRESSION2_DIR, place a sibling bithuman-models checkout, or allow a git clone) — expression2 is the DEFAULT engine and is REQUIRED"
    fi
    local sdk="$ENGINE_SDK"
    log "Staging expression2 (embody) engine SDK from $sdk"
    log "  engine adapter source: $ENGINE_SDK_REV"
    # Run the engine's own bootstrap (fetches the embody models). A nonzero exit
    # is a HARD failure (e.g. sha mismatch) we must not swallow.
    ( cd "$sdk" && env $extra_env bash scripts/bootstrap.sh ) \
        || die "expression2 SDK bootstrap FAILED — aborting"
    # Stage the adapter SOURCE into both platform slices (compiled in-module).
    for plat in macos ios; do
        local base="$PLUGIN_ROOT/$plat/Engines/expression2"
        mkdir -p "$base/Classes"
        cp "$sdk"/Classes/*.swift "$base/Classes/"
    done
    log "  staged expression2 → {macos,ios}/Engines/expression2/Classes"
    # Stage the embody CoreML models to Assets/embody (FROZEN landing) when the
    # engine bootstrap produced them (absent in DEV mode → runtime falls back).
    if [ -d "$sdk/Vendor/embody" ]; then
        rm -rf "$PLUGIN_ROOT/Assets/embody"; mkdir -p "$PLUGIN_ROOT/Assets"
        cp -R "$sdk/Vendor/embody" "$PLUGIN_ROOT/Assets/embody"
        log "  staged embody models → Assets/embody ($(ls "$PLUGIN_ROOT/Assets/embody" | wc -l | tr -d ' ') items)"
    else
        log "  no Vendor/embody (DEV mode) — embody loads from ~/embody-ane at runtime"
    fi
}

# ------------------------------------------------- engine #2: essence2 (OPTIONAL)
# Stage one platform's pod surface from the essence-2 SDK, IF that platform's
# slice (its libessence2.a) exists. Classes + header travel with the slice.
stage_essence2_plat() {  # $1=plat, $2=slice .a path, $3=resources dir, $4=sdk path
    local plat="$1" a="$2" res="$3" sdk="$4"
    [ -f "$a" ] || return 0
    local base="$PLUGIN_ROOT/$plat/Engines/essence2"
    rm -rf "$base"; mkdir -p "$base/Classes" "$base/include" "$base/Vendor"
    cp "$sdk"/Classes/*.swift "$base/Classes/"
    cp "$sdk"/include/*.h      "$base/include/"
    cp "$a" "$base/Vendor/libessence2.a"
    [ -d "$res" ] && cp -R "$res" "$base/Vendor/essence2-resources"
    log "  staged essence2 → $plat/Engines/essence2 (Classes + be_essence2.h + libessence2.a + resources)"
}

stage_essence2() {
    rm -rf "$PLUGIN_ROOT/macos/Engines/essence2" "$PLUGIN_ROOT/ios/Engines/essence2"
    if ! locate_engine_sdk ESSENCE2 "essence-2" "${BITHUMAN_ESSENCE2_DIR:-}" "$BITHUMAN_MODELS_REF"; then
        warn "bithuman-models models/essence-2/sdk not found (set BITHUMAN_ESSENCE2_DIR, place a sibling bithuman-models checkout, or allow a git clone) — essence2 disabled (embody-only)"
        return 0
    fi
    local sdk="$ENGINE_SDK"
    log "Staging essence2 engine SDK from $sdk"
    log "  engine adapter source: $ENGINE_SDK_REV"
    log "  engine binary: $LIBESSENCE2_RELEASE (${LIBESSENCE2_SHA256:0:16}…), resources: $LIBESSENCE2_RESOURCES_RELEASE (${LIBESSENCE2_RESOURCES_SHA256:0:16}…)"
    # ★ THE PIN IS PASSED, NOT INHERITED. The engine SDK's own bootstrap carries
    # a DEFAULT tag of its own, in the private repo, on whatever revision this
    # checkout happens to be — that default is what shipped essence2-v1.2.0 into
    # this pod while Package.swift served v1.7.0. Naming all four coordinates
    # here makes the plugin tag, and only the plugin tag, decide.
    # The engine SDK bootstrap exits 0 (degrade to embody-only) on a download
    # failure / missing release, but `die`s (nonzero) on a sha256 MISMATCH — so a
    # nonzero here is a HARD, loud failure we must NOT swallow.
    ( cd "$sdk" && env \
        LIBESSENCE2_RELEASE="$LIBESSENCE2_RELEASE" \
        LIBESSENCE2_SHA256="$LIBESSENCE2_SHA256" \
        LIBESSENCE2_RESOURCES_RELEASE="$LIBESSENCE2_RESOURCES_RELEASE" \
        LIBESSENCE2_RESOURCES_SHA256="$LIBESSENCE2_RESOURCES_SHA256" \
        bash scripts/bootstrap.sh ) \
        || die "essence2 SDK bootstrap FAILED (e.g. libessence2 sha256 mismatch) — aborting"
    local mac_a="$sdk/Vendor/libessence2-macos.a"
    local ios_a="$sdk/Vendor/libessence2-ios.a"
    local res="$sdk/Vendor/essence2-resources"
    if [ ! -f "$mac_a" ] && [ ! -f "$ios_a" ]; then
        warn "essence2 SDK produced no libessence2.a — essence2 disabled (embody-only)"
        return 0
    fi
    stage_essence2_plat macos "$mac_a" "$res" "$sdk"
    stage_essence2_plat ios   "$ios_a" "$res" "$sdk"   # iOS device slice only when present (human-gated)
}

# ---------------------------------------------------- platform detection
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

# 2. N-engine loop. expression2 reuses the bundle we already downloaded for
# libconverse (EMBODY_VENDOR_SRC → no re-download); essence2 fetches its own
# sha-pinned libessence2 release inside its SDK bootstrap.
stage_expression2 "EMBODY_VENDOR_SRC=$SRC"
stage_essence2

log "Done. Self-contained — no sibling bithuman-sdk required."
log "    the product app lives in the bithuman-jarvis-app repo: github.com/bithuman-product/bithuman-jarvis-app"
