#!/usr/bin/env bash
# mirror-cli-release.sh — copy one published CLI release (cli-vX.Y.Z) from the release origin,
# https://downloads.bithuman.ai/homebrew-bithuman/ (scripts/downloads-publish.py), to the bitHuman
# download mirror, https://maven.bithuman.ai/ai/bithuman/bithuman-cli/: the second copy
# install.sh / install.ps1 download from first, and fall back to when the origin cannot be read.
#
# WHERE: the existing public-read object-storage bucket `maven`, served by the existing
# Cloudflare Worker bithuman-maven-proxy (platform deploy/cloudflare/maven-proxy.mjs). That
# Worker keeps versioned files in OUR edge cache for a year (each location pulls a file from
# the origin about once) and `maven-metadata.xml` for 300 s. No new bucket, Worker or DNS.
#
# LAYOUT (Maven2-shaped, so the Worker's caching rules apply unchanged):
#   ai/bithuman/bithuman-cli/<X.Y.Z>/<asset>            the release's tarballs/zip, byte for byte
#   ai/bithuman/bithuman-cli/<X.Y.Z>/<asset>.sha256     the release's own sidecars, byte for byte
#   ai/bithuman/bithuman-cli/maven-metadata.xml         <release> = newest mirrored version
# The "latest" pointer is maven-metadata.xml rather than a latest.json because the Worker
# gives every other name a 1-year immutable edge TTL and no token on the account can purge.
#
# RULES: write-once (a key already holding DIFFERENT bytes is refused; identical bytes are
# skipped); only a published, non-draft, non-pre-release cli-v* tag; every asset is checked
# against its .sha256 before upload and read back through maven.bithuman.ai after.
#
# Usage:  scripts/mirror-cli-release.sh cli-v2.8.6            # dry run: download + verify only
#         scripts/mirror-cli-release.sh cli-v2.8.6 --execute  # upload + metadata + read-back
# Needs: curl, python3, sha256sum|shasum; SUPABASE_URL and
# SUPABASE_SERVICE_ROLE_KEY in the environment (never printed), e.g.
#   set -a; eval "$(/usr/bin/grep -E '^(SUPABASE_URL|SUPABASE_SERVICE_ROLE_KEY)=' ~/.env)"; set +a
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PUBLISH=(python3 "$HERE/downloads-publish.py" --repo homebrew-bithuman)
ORIGIN="${BITHUMAN_DOWNLOADS_BASE:-https://downloads.bithuman.ai}/homebrew-bithuman"
BUCKET="maven"
PREFIX="ai/bithuman/bithuman-cli"
PUBLIC="https://maven.bithuman.ai/${PREFIX}"
IMMUTABLE_CC="max-age=31536000"   # the Worker sets its own headers; this is the origin's object TTL
META_CC="max-age=60"

tag="${1:?usage: $0 cli-vX.Y.Z [--execute]}"
mode="${2:-dry}"
case "$tag" in cli-v[0-9]*.[0-9]*.[0-9]*) ;; *) echo "refuse: '$tag' is not a cli-vX.Y.Z tag" >&2; exit 2 ;; esac
ver="${tag#cli-v}"

sha() { if command -v sha256sum >/dev/null; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
mime() { case "$1" in *.xml) echo application/xml ;; *.sha256) echo text/plain ;; *.zip) echo application/zip ;; *) echo application/octet-stream ;; esac; }

state=$("${PUBLISH[@]}" view "$tag" --json \
  | python3 -c 'import json,sys; r=json.load(sys.stdin); print(str(bool(r["draft"])).lower(), str(bool(r["prerelease"])).lower())')
[ "$state" = "false false" ] || { echo "refuse: $tag is a draft or pre-release ($state)" >&2; exit 2; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "mirror: downloading $tag assets from $ORIGIN"
"${PUBLISH[@]}" download "$tag" -D "$work" -p 'bithuman-*.tar.gz' -p 'bithuman-*.zip' -p 'bithuman-*.sha256'
assets=()
for f in "$work"/bithuman-*; do
  case "$f" in *.sha256) continue ;; esac
  n=$(basename "$f")
  [ -f "$f.sha256" ] || { echo "refuse: $n has no .sha256 sidecar on the release" >&2; exit 1; }
  want=$(awk '{print $1}' "$f.sha256"); got=$(sha "$f")
  [ "$want" = "$got" ] || { echo "refuse: $n sha256 $got != sidecar $want" >&2; exit 1; }
  echo "  ok  $n  $got"
  assets+=("$n" "$n.sha256")
done
[ "${#assets[@]}" -gt 0 ] || { echo "refuse: $tag carries no CLI assets" >&2; exit 1; }

if [ "$mode" != "--execute" ]; then echo "DRY RUN: verified ${#assets[@]} files; pass --execute to upload"; exit 0; fi
: "${SUPABASE_URL:?}" "${SUPABASE_SERVICE_ROLE_KEY:?}"
API="${SUPABASE_URL%/}/storage/v1"
auth=(-H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}")

upload() { # <file> <key> <cache-control> <upsert true|false> -> HTTP code
  curl -sS -o "$work/up.out" -w '%{http_code}' -X POST "$API/object/$BUCKET/$2" "${auth[@]}" \
    -H "Content-Type: $(mime "$2")" -H "cache-control: $3" -H "x-upsert: $4" --upload-file "$1"
}

for n in "${assets[@]}"; do
  key="$PREFIX/$ver/$n"
  code=$(upload "$work/$n" "$key" "$IMMUTABLE_CC" false)
  case "$code" in
    200) echo "  up  $key" ;;
    400|409)  # already there: identical bytes are fine, different bytes are refused (write-once)
      curl -sS -o "$work/existing" "${auth[@]}" "$API/object/$BUCKET/$key"
      if [ "$(sha "$work/existing")" = "$(sha "$work/$n")" ]; then echo "  =   $key (already mirrored, same bytes)"
      else echo "refuse: $key already holds DIFFERENT bytes (write-once; publish a new version)" >&2; exit 1; fi ;;
    *) echo "upload failed for $key (HTTP $code): $(head -c 200 "$work/up.out")" >&2; exit 1 ;;
  esac
done

# maven-metadata.xml: every mirrored version, newest as <release>/<latest>.
curl -sS "${auth[@]}" -H 'Content-Type: application/json' -X POST "$API/object/list/$BUCKET" \
  -d "{\"prefix\":\"$PREFIX/\",\"limit\":1000}" > "$work/list.json"
python3 - "$work/list.json" "$ver" > "$work/maven-metadata.xml" <<'PY'
import json, re, sys, time
names = {o["name"] for o in json.load(open(sys.argv[1])) if o.get("id") is None}  # folders
names.add(sys.argv[2])
vs = sorted((n for n in names if re.fullmatch(r"\d+\.\d+\.\d+", n)), key=lambda v: tuple(map(int, v.split("."))))
print('<?xml version="1.0" encoding="UTF-8"?>')
print("<metadata>\n  <groupId>ai.bithuman</groupId>\n  <artifactId>bithuman-cli</artifactId>\n  <versioning>")
print(f"    <latest>{vs[-1]}</latest>\n    <release>{vs[-1]}</release>\n    <versions>")
for v in vs: print(f"      <version>{v}</version>")
print(f"    </versions>\n    <lastUpdated>{time.strftime('%Y%m%d%H%M%S', time.gmtime())}</lastUpdated>\n  </versioning>\n</metadata>")
PY
code=$(upload "$work/maven-metadata.xml" "$PREFIX/maven-metadata.xml" "$META_CC" true)
[ "$code" = 200 ] || { echo "metadata upload failed (HTTP $code)" >&2; exit 1; }
echo "  up  $PREFIX/maven-metadata.xml (release $(sed -n 's:.*<release>\(.*\)</release>.*:\1:p' "$work/maven-metadata.xml"))"

# Read-back through the public host, anonymously.
echo "mirror: read-back through $PUBLIC"
for n in "${assets[@]}"; do
  curl -fsS -o "$work/rb" "$PUBLIC/$ver/$n"
  [ "$(sha "$work/rb")" = "$(sha "$work/$n")" ] || { echo "READ-BACK FAIL: $n" >&2; exit 1; }
  echo "  rb  $n"
done
echo "MIRRORED $tag -> $PUBLIC/$ver/ (metadata may take up to 300 s to show it at every edge)"
