#!/usr/bin/env bash
#
# Developer ID sign every Mach-O in a staged macOS CLI tree, with the
# hardened runtime, so the result can be NOTARIZED.
#
# Usage:  scripts/sign-macos.sh <stage-dir>
#
# Why this exists
# ---------------
# Every macOS `bithuman` binary published up to and including cli-v2.4.2 was
# AD-HOC signed:
#
#     CodeDirectory ... flags=0x2(adhoc)
#     Signature=adhoc
#     TeamIdentifier=not set
#     $ spctl -a -vv -t install bithuman
#     bithuman: rejected                                    (rc=3)
#
# An ad-hoc signature is internally valid (`codesign --verify` passes) but it
# carries no identity, so Gatekeeper refuses it. That is invisible to most
# `brew install` users -- Homebrew fetches with curl, which does not set
# com.apple.quarantine, and Gatekeeper only evaluates quarantined files. It is
# NOT invisible to anyone who downloads the tarball from the Releases page in a
# browser: macOS propagates com.apple.quarantine from the .tar.gz onto every
# extracted member (measured: plain `tar -xzf` does this, not just Archive
# Utility), and the extracted binary is then killed on exec with SIGKILL and no
# diagnostic at all.
#
# bitHuman has held `Developer ID Application: bitHuman Inc. (G64NFNZX84)` the
# whole time. This script uses it.
#
# Design: DISCOVER the Mach-O set, never hand-list it
# ---------------------------------------------------
# a31d727 ("the essence-2 payload was dropped at FOUR independent hand-written
# lists") is the precedent. A hand-written list of things to sign is a fifth
# such list, and an unsigned dylib does not announce itself -- it fails
# notarization forty minutes later, or worse, passes because the notary service
# only looks at what it can find. So this script walks the stage tree and signs
# whatever is actually Mach-O, deepest path first. Add a dylib to the bundle and
# it gets signed with no edit here.
#
# Environment
#   MACOS_SIGN_IDENTITY  signing identity (default: the bitHuman Developer ID)
#   MACOS_KEYCHAIN       optional keychain to sign from (CI uses a temp keychain)
#
set -euo pipefail

STAGE="${1:?usage: sign-macos.sh <stage-dir>}"
[ -d "$STAGE" ] || { echo "sign-macos: not a directory: $STAGE" >&2; exit 2; }

IDENTITY="${MACOS_SIGN_IDENTITY:-Developer ID Application: bitHuman Inc. (G64NFNZX84)}"
ENTITLEMENTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bithuman-cli.entitlements"
[ -f "$ENTITLEMENTS" ] || { echo "sign-macos: missing $ENTITLEMENTS" >&2; exit 2; }

echo "sign-macos: identity   = $IDENTITY"
echo "sign-macos: stage      = $STAGE"
echo "sign-macos: entitlements = $ENTITLEMENTS"

# ---- discover every Mach-O in the tree -------------------------------------
# `file` is the oracle. Note embody.model is a zip of .mlpackage and the
# engines/*.engine blobs are opaque data -- neither is Mach-O, so neither is
# signed, and neither needs to be: the notary service only requires that every
# executable/dylib it can find is signed with the hardened runtime.
LIST="$(mktemp -t signmacos)"
trap 'rm -f "$LIST"' EXIT
find "$STAGE" -type f ! -name '._*' | LC_ALL=C sort -r | while IFS= read -r f; do
  case "$(file -b "$f")" in
    *Mach-O*) printf '%s\n' "$f" ;;
  esac
done > "$LIST"

COUNT="$(wc -l < "$LIST" | tr -d ' ')"
[ "$COUNT" -gt 0 ] || { echo "sign-macos: no Mach-O files under $STAGE" >&2; exit 2; }
echo "sign-macos: $COUNT Mach-O files to sign"

# ---- sign, deepest path first (dylibs before the executables that load them)-
while IFS= read -r f; do
  codesign --force --timestamp --options runtime \
           --entitlements "$ENTITLEMENTS" \
           ${MACOS_KEYCHAIN:+--keychain "$MACOS_KEYCHAIN"} \
           --sign "$IDENTITY" "$f"
done < "$LIST"
echo "sign-macos: signed $COUNT files"

# ---- verify every one of them ----------------------------------------------
# Not "the build succeeded" -- assert the property we actually want on each
# file: a real Developer ID signature, hardened runtime on, no ad-hoc left.
fail=0
while IFS= read -r f; do
  if ! codesign --verify --strict "$f" 2>/dev/null; then
    echo "sign-macos: FAILED --verify: $f" >&2; fail=1; continue
  fi
  desc="$(codesign -dvvv "$f" 2>&1)"
  case "$desc" in
    *"flags=0x2(adhoc)"*|*"Signature=adhoc"*)
      echo "sign-macos: STILL AD-HOC: $f" >&2; fail=1 ;;
  esac
  case "$desc" in
    *"TeamIdentifier=not set"*)
      echo "sign-macos: NO TEAM ID: $f" >&2; fail=1 ;;
  esac
  case "$desc" in
    *runtime*) : ;;
    *) echo "sign-macos: NO HARDENED RUNTIME: $f" >&2; fail=1 ;;
  esac
done < "$LIST"
[ "$fail" -eq 0 ] || { echo "sign-macos: verification FAILED" >&2; exit 1; }

echo "sign-macos: all $COUNT Mach-O files carry a hardened-runtime Developer ID signature"
