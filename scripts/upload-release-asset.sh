#!/usr/bin/env bash
#
# Upload release assets, REFUSING by default to overwrite one that is already
# published.
#
# Usage:  scripts/upload-release-asset.sh <release-tag> <file> [file...]
#
# Why this exists
# ---------------
# Both jobs in release-cli.yml used to end in a bare
#
#     gh release upload "$RELEASE_TAG" --repo ... --clobber "$TGZ" "$TGZ.sha256"
#
# `--clobber` DELETES the existing asset and uploads the new one in its place.
# The release tag is a free-text workflow input, so a dispatch aimed at an
# ALREADY-PUBLISHED tag silently replaces the bytes customers are installing:
#
#   * the Homebrew formula pins a sha256 for that exact URL, so the replacement
#     breaks `brew install` for everyone on that formula revision — the URL still
#     resolves, the checksum no longer matches, and brew aborts mid-install;
#   * the mac lane refuses to publish an unsigned tarball, but the LINUX lane had
#     no gate of any kind, so a dispatch made purely to exercise the mac signing
#     path would still rebuild and overwrite the published Linux tarball;
#   * and it happens with no prompt, no diff and no record of the bytes that were
#     there before.
#
# Replacing a published asset is a legitimate operation (2a7cd37 did exactly that
# on purpose, re-pinning the formula afterwards). It just has to be DECLARED,
# never a silent default — the same shape as `allow_unsigned` and
# BITHUMAN_TARBALL_NO_ESSENCE2 elsewhere in this workflow.
#
# ★2026-10: releases live on https://downloads.bithuman.ai (<repo>/<tag>/<asset>,
# releases.json, latest.json), written through scripts/downloads-publish.py. Assets there
# are IMMUTABLE (the edge caches them for a year), so the declared-overwrite escape hatch is
# gone: OVERWRITE_PUBLISHED=true is refused with the same explanation. Cut a new tag instead.
# Adding NEW assets to an existing release is allowed and never moves latest.json.
#
# Environment
#   OVERWRITE_PUBLISHED=true   (refused: published assets are immutable)
#   ASSET_REPO                 repo name on the downloads host (default: homebrew-bithuman)
#   bucket credentials         read by the downloads publisher (dlhost.py), never printed
#
set -euo pipefail

TAG="${1:?usage: upload-release-asset.sh <release-tag> <file> [file...]}"
shift
[ "$#" -gt 0 ] || { echo "upload-release-asset: no files given" >&2; exit 2; }

REPO="${ASSET_REPO:-homebrew-bithuman}"
# Until the move ASSET_REPO took OWNER/NAME (a GitHub repo); only the last segment names the repo
# on the downloads host, so an old export (bithuman-product/homebrew-bithuman) keeps working.
REPO="${REPO##*/}"
PUBLISH=(python3 "$(cd "$(dirname "$0")" && pwd)/downloads-publish.py" --repo "$REPO")
OVERWRITE="${OVERWRITE_PUBLISHED:-false}"

for f in "$@"; do
  [ -f "$f" ] || { echo "upload-release-asset: no such file: $f" >&2; exit 2; }
done

# ---- what is already on this release ---------------------------------------
# Read it ONCE, from the bucket's index, and fail loudly if the read itself
# fails: an empty asset list because the read errored would read as "nothing to
# overwrite" and wave the clobber straight through.
# Portable form: GNU mktemp rejects `-t <prefix>` ("too few X's in template"),
# and this script runs on BOTH the macOS and the Linux runner.
EXISTING="$(mktemp "${TMPDIR:-/tmp}/relassets.XXXXXX")"
trap 'rm -f "$EXISTING"' EXIT
if ! "${PUBLISH[@]}" view "$TAG" --json \
      | python3 -c 'import json,sys; [print("%s\t%s\t%s\t-" % (a["name"], a["size"], a.get("updated_at") or "-")) for a in json.load(sys.stdin)["assets"]]' \
      > "$EXISTING"; then
  echo "upload-release-asset: cannot read release $TAG on $REPO (does the tag exist?)" >&2
  exit 2
fi

CLASH=0
for f in "$@"; do
  name="$(basename "$f")"
  if row="$(awk -F'\t' -v n="$name" '$1==n {print; exit}' "$EXISTING")" && [ -n "$row" ]; then
    IFS=$'\t' read -r _ size updated downloads <<< "$row"
    echo "upload-release-asset: ALREADY PUBLISHED on $TAG: $name" >&2
    echo "    size=$size bytes  updated=$updated  downloads=$downloads" >&2
    CLASH=1
  fi
done

if [ "$CLASH" -eq 1 ]; then
  cat >&2 <<EOF
::error::refusing to overwrite a published release asset on $TAG.

The asset(s) listed above are already on the $TAG release and customers may be
installing them right now — the Homebrew formula pins a sha256 against that
exact URL, so replacing the bytes breaks \`brew install\` until the formula is
re-pinned. On the downloads host published assets are immutable, so
OVERWRITE_PUBLISHED=$OVERWRITE changes nothing.

Cut a NEW tag (and re-pin Formula/bithuman-cli.rb to it).
EOF
  exit 1
fi

# New assets only; adding files to a release never moves latest.json.
"${PUBLISH[@]}" publish "$TAG" --latest false "$@"

echo "upload-release-asset: uploaded $# asset(s) to $TAG"
