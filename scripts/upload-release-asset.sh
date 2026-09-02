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
# Environment
#   OVERWRITE_PUBLISHED=true   allow replacing an asset that already exists
#   ASSET_REPO                 repo holding the release (default: this tap)
#   GH_TOKEN                   as usual
#
set -euo pipefail

TAG="${1:?usage: upload-release-asset.sh <release-tag> <file> [file...]}"
shift
[ "$#" -gt 0 ] || { echo "upload-release-asset: no files given" >&2; exit 2; }

REPO="${ASSET_REPO:-bithuman-product/homebrew-bithuman}"
OVERWRITE="${OVERWRITE_PUBLISHED:-false}"

for f in "$@"; do
  [ -f "$f" ] || { echo "upload-release-asset: no such file: $f" >&2; exit 2; }
done

# ---- what is already on this release ---------------------------------------
# Read it ONCE, from the API, and fail loudly if the read itself fails: an
# empty asset list because `gh` errored would read as "nothing to overwrite"
# and wave the clobber straight through.
# Portable form: GNU mktemp rejects `-t <prefix>` ("too few X's in template"),
# and this script runs on BOTH the macOS and the Linux runner.
EXISTING="$(mktemp "${TMPDIR:-/tmp}/relassets.XXXXXX")"
trap 'rm -f "$EXISTING"' EXIT
if ! gh release view "$TAG" --repo "$REPO" \
      --json assets --jq '.assets[] | [.name, (.size|tostring), .updatedAt, (.downloadCount|tostring)] | @tsv' \
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

if [ "$CLASH" -eq 1 ] && [ "$OVERWRITE" != "true" ]; then
  cat >&2 <<EOF
::error::refusing to overwrite a published release asset on $TAG.

The asset(s) listed above are already on the $TAG release and customers may be
installing them right now — the Homebrew formula pins a sha256 against that
exact URL, so replacing the bytes breaks \`brew install\` until the formula is
re-pinned.

If you meant to cut a NEW release, dispatch against a NEW tag.
If you meant to REPLACE these bytes, re-dispatch with overwrite_published=true
and re-pin Formula/bithuman-cli.rb afterwards (see 2a7cd37).
EOF
  exit 1
fi

if [ "$CLASH" -eq 1 ]; then
  echo "::warning::overwrite_published=true — replacing published asset(s) on $TAG"
  gh release upload "$TAG" --repo "$REPO" --clobber "$@"
else
  # No --clobber: nothing to clobber, and without the flag a surprise
  # collision (an asset uploaded between the read above and this line) fails
  # instead of silently winning the race.
  gh release upload "$TAG" --repo "$REPO" "$@"
fi

echo "upload-release-asset: uploaded $# asset(s) to $TAG"
