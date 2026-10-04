#!/bin/sh
# Offline test for install.sh's release origin and download mirror (no network): a fake `curl` on
# PATH plays the release origin (https://origin.test/homebrew-bithuman/...: latest.json,
# releases.json, <tag>/<asset>) and the bitHuman mirror (https://mirror.test/...). Any other URL is
# logged as OTHER and refused. Run from the repo root:
#   sh tests/install-sh-mirror.sh
# Covers: the version comes from latest.json and the bytes from the mirror when it has them; a
# pinned install with a healthy mirror asks nothing else; mirror down / version not mirrored ->
# the origin; a tampered mirror is REFUSED; BITHUMAN_MIRROR=off never asks the mirror; origin down
# -> the mirror's metadata names the version; origin rate-limited -> the mirror still decides; a latest.json that names a pre-release is not
# trusted (the index picks the newest real release); a minified, reordered index with escaped
# quotes still parses; and NO case ever makes a request to any other host (GitHub included).
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
installer="$here/install.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
fail=0
# The tarball this host's installer asks for (runs on Linux and on macOS alike).
case "$(uname -s)" in Darwin) _os=apple-darwin ;; *) _os=unknown-linux-gnu ;; esac
case "$(uname -m)" in arm64|aarch64) _arch=aarch64 ;; *) _arch=x86_64 ;; esac
T="bithuman-${_arch}-${_os}.tar.gz"

mkdir -p "$work/pkg"
cat > "$work/pkg/bithuman" <<'BIN'
#!/bin/sh
printf 'libessence 9.9.9 ABI 7\nbithuman    9.9.9\nbuild       test\n'
BIN
chmod 755 "$work/pkg/bithuman"
tar -czf "$work/tarball.tgz" -C "$work/pkg" bithuman
sum=$( (sha256sum "$work/tarball.tgz" 2>/dev/null || shasum -a 256 "$work/tarball.tgz") | awk '{print $1}')

mkdir -p "$work/fakebin"
cat > "$work/fakebin/curl" <<'CURL'
#!/bin/sh
# Fake curl: -o <out>, -D <hdr>, -w '%{http_code}'. Files under $FAKE_DIR/{mirror,origin};
# $FAKE_DIR/{mirror,origin}_down = connection refused; $FAKE_DIR/origin_ratelimited = every origin
# request answers 429 with Retry-After: 300 (beyond the installer's wait cap).
hdr=""; out=""; url=""; w=""
while [ $# -gt 0 ]; do
  case "$1" in
    -D) hdr=$2; shift ;; -o) out=$2; shift ;; -w) w=$2; shift ;;
    -H|--connect-timeout|--max-time|--speed-limit|--speed-time) shift ;;
    -*) ;; *) url=$1 ;;
  esac; shift
done
case "$url" in
  https://mirror.test/ai/bithuman/bithuman-cli/*) side=mirror; rel=${url#https://mirror.test/ai/bithuman/bithuman-cli/} ;;
  https://origin.test/homebrew-bithuman/*)        side=origin; rel=${url#https://origin.test/homebrew-bithuman/} ;;
  *) printf 'OTHER %s\n' "$url" >> "$FAKE_DIR/log"; exit 7 ;;
esac
printf '%s %s\n' "$side" "$url" >> "$FAKE_DIR/log"
[ -f "$FAKE_DIR/${side}_down" ] && { [ -n "$w" ] && printf '000'; exit 7; }
f="$FAKE_DIR/$side/$rel"
if [ -f "$f" ]; then code=200; else code=404; fi
[ "$side" = origin ] && [ -f "$FAKE_DIR/origin_ratelimited" ] && code=429
[ -n "$hdr" ] && printf 'HTTP/2 %s\r\n' "$code" > "$hdr"
[ -n "$hdr" ] && [ "$code" = 429 ] && printf 'retry-after: 300\r\n' >> "$hdr"
if [ "$code" = 200 ]; then if [ -n "$out" ]; then cp "$f" "$out"; else cat "$f"; fi; fi
[ -n "$w" ] && printf '%s' "$code"
[ "$code" = 200 ] && exit 0
exit 22
CURL
chmod 755 "$work/fakebin/curl"

mirror_with() { # <case> <version> <sha-to-publish>  -> a mirror holding that version
  m="$work/$1/mirror"; mkdir -p "$m/$2"
  printf '<metadata><versioning><latest>%s</latest><release>%s</release></versioning></metadata>\n' "$2" "$2" > "$m/maven-metadata.xml"
  cp "$work/tarball.tgz" "$m/$2/$T"
  printf '%s  %s\n' "$3" "$T" > "$m/$2/$T.sha256"
}
rel_json() { # <tag> <prerelease true|false>  -> one pretty release object
  cat <<J
  {
    "tag_name": "$1",
    "name": "bithuman CLI $1",
    "draft": false,
    "prerelease": $2,
    "published_at": "2026-10-04T00:00:00Z",
    "body": "notes for $1",
    "assets": [
      { "name": "$T", "size": 1, "browser_download_url": "https://origin.test/homebrew-bithuman/$1/$T" },
      { "name": "$T.sha256", "size": 1, "browser_download_url": "https://origin.test/homebrew-bithuman/$1/$T.sha256" },
      { "name": "bithuman-aarch64-apple-darwin.tar.gz", "size": 1, "browser_download_url": "https://origin.test/homebrew-bithuman/$1/bithuman-aarch64-apple-darwin.tar.gz" }
    ]
  }
J
}
origin_with() { # <case> <latest-tag> [<latest-is-prerelease>]  -> an origin holding cli-v9.9.9 + cli-v9.9.8
  o="$work/$1/origin"; mkdir -p "$o/cli-v9.9.9" "$o/cli-v9.9.8" "$o/cli-v10.0.0-rc1"
  for t in cli-v9.9.9 cli-v9.9.8 cli-v10.0.0-rc1; do
    cp "$work/tarball.tgz" "$o/$t/$T"; printf '%s  %s\n' "$sum" "$T" > "$o/$t/$T.sha256"
  done
  { printf '[\n'; rel_json cli-v10.0.0-rc1 true; printf ',\n'; rel_json cli-v9.9.9 false; printf ',\n'
    rel_json cli-v9.9.8 false; printf ']\n'; } > "$o/releases.json"
  if [ "${3:-false}" = true ]; then rel_json cli-v10.0.0-rc1 true > "$o/latest.json"; else rel_json "$2" false > "$o/latest.json"; fi
}
run_case() { # <name> [BITHUMAN_VERSION] [BITHUMAN_MIRROR]
  d="$work/$1"; mkdir -p "$d/bin"; : > "$d/log"
  env -i PATH="$work/fakebin:/usr/bin:/bin" HOME="$d" FAKE_DIR="$d" \
    BITHUMAN_INSTALL_DIR="$d/bin" BITHUMAN_NO_MODIFY_PATH=1 \
    BITHUMAN_DOWNLOADS=https://origin.test/homebrew-bithuman \
    BITHUMAN_MIRROR="${3:-https://mirror.test/ai/bithuman/bithuman-cli}" \
    BITHUMAN_INSTALL_MAX_TRIES=1 \
    ${2:+BITHUMAN_VERSION=$2} \
    sh "$installer" > "$d/out" 2>&1
  echo $? > "$d/rc"
}
check() { if [ "$2" = 0 ]; then printf '  PASS  %s\n' "$1"; else printf '  FAIL  %s\n' "$1"; fail=1; fi; }
rc() { cat "$work/$1/rc"; }
has() { grep -qF -- "$2" "$work/$1/out"; }
n_of() { grep -c "^$2 " "$work/$1/log"; }

# 1) healthy origin + mirror: version from latest.json, bytes from the mirror.
origin_with m1 cli-v9.9.9; mirror_with m1 9.9.9 "$sum"; run_case m1
check "latest: exit 0"                                 "$( [ "$(rc m1)" = 0 ]; echo $?)"
check "latest: version from latest.json"               "$(has m1 'latest release: cli-v9.9.9'; echo $?)"
check "latest: bytes from the mirror, sha256 verified" "$(has m1 'downloading https://mirror.test/' && has m1 'sha256 ok'; echo $?)"
check "latest: binary installed"                       "$( [ -x "$work/m1/bin/bithuman" ]; echo $?)"

# 2) pinned, healthy mirror: nothing but the mirror is asked.
origin_with m2 cli-v9.9.9; mirror_with m2 9.9.9 "$sum"; run_case m2 cli-v9.9.9
check "pinned: exit 0, the origin is never asked"      "$( [ "$(rc m2)" = 0 ] && [ "$(n_of m2 origin)" = 0 ]; echo $?)"

# 3) mirror down -> the origin resolves + downloads.
origin_with m3 cli-v9.9.9; mkdir -p "$work/m3"; : > "$work/m3/mirror_down"; run_case m3
check "★mirror down: the origin serves it, exit 0"     "$( [ "$(rc m3)" = 0 ] && grep -q '^origin .*/cli-v9.9.9/'"$T"'$' "$work/m3/log"; echo $?)"
check "mirror down: says it is using the origin"       "$(has m3 '(or is unreachable); using the release origin'; echo $?)"

# 4) mirror up but without this (pinned) version -> the origin.
origin_with m4 cli-v9.9.9; mirror_with m4 9.9.7 "$sum"; run_case m4 cli-v9.9.8
check "version not mirrored: the origin, exit 0"       "$( [ "$(rc m4)" = 0 ] && grep -q '^origin .*/cli-v9.9.8/'"$T"'$' "$work/m4/log"; echo $?)"

# 5) mirror bytes do not match the mirror's sidecar -> refused, nothing installed.
origin_with m5 cli-v9.9.9; mirror_with m5 9.9.9 0000000000000000000000000000000000000000000000000000000000000000; run_case m5
check "★mirror sha mismatch: exit 1, refused"          "$( [ "$(rc m5)" = 1 ] && has m5 'sha256 mismatch'; echo $?)"
check "mirror sha mismatch: nothing installed"         "$( [ ! -e "$work/m5/bin/bithuman" ]; echo $?)"

# 6) BITHUMAN_MIRROR=off -> the mirror is never asked.
origin_with m6 cli-v9.9.9; mirror_with m6 9.9.9 "$sum"; run_case m6 "" off
check "BITHUMAN_MIRROR=off: exit 0, mirror never asked" "$( [ "$(rc m6)" = 0 ] && [ "$(n_of m6 mirror)" = 0 ]; echo $?)"

# 7) origin down -> the mirror's metadata names the version and serves it.
mkdir -p "$work/m7"; : > "$work/m7/origin_down"; mirror_with m7 9.9.9 "$sum"; run_case m7
check "★origin down: the mirror names + serves it"     "$( [ "$(rc m7)" = 0 ] && has m7 'latest release (bitHuman mirror;'; echo $?)"

# 7b) the origin RATE-LIMITS the lookup -> the mirror still names + serves the version.
origin_with m7b cli-v9.9.9; : > "$work/m7b/origin_ratelimited"; mirror_with m7b 9.9.9 "$sum"; run_case m7b
check "★origin rate-limited: the mirror names + serves it" "$( [ "$(rc m7b)" = 0 ] && has m7b 'latest release (bitHuman mirror;' && [ -x "$work/m7b/bin/bithuman" ]; echo $?)"
check "origin rate-limited, mirror answers: no rate-limit error" "$(! has m7b 'is rate-limiting downloads'; echo $?)"

# 7c) the origin rate-limits and the mirror is off -> exit 1 naming the rate limit.
origin_with m7c cli-v9.9.9; : > "$work/m7c/origin_ratelimited"; run_case m7c "" off
check "origin rate-limited, no mirror: exit 1, names the rate limit" "$( [ "$(rc m7c)" = 1 ] && has m7c 'is rate-limiting downloads from this network (HTTP 429)'; echo $?)"

# 8) latest.json names a PRE-RELEASE -> not trusted; the index picks cli-v9.9.9.
origin_with m8 cli-v9.9.9 true; run_case m8 "" off
check "★latest.json naming a pre-release is not trusted" "$( [ "$(rc m8)" = 0 ] && has m8 'latest release: cli-v9.9.9' && ! has m8 'cli-v10.0.0-rc1'; echo $?)"

# 9) a MINIFIED index, keys reordered, escaped quotes in the body: still parses.
origin_with m9 cli-v9.9.9
printf '[{"body":"a \\"quoted\\" {brace} \\\\","assets":[{"browser_download_url":"x","name":"%s","size":1},{"name":"%s.sha256","size":1}],"prerelease":false,"tag_name":"cli-v9.9.9","draft":false}]' "$T" "$T" > "$work/m9/origin/releases.json"
printf '{"assets":[],"draft":false,"tag_name":"cli-v9.9.9","body":"x \\" y","prerelease":false}' > "$work/m9/origin/latest.json"
run_case m9 "" off
check "★minified, reordered, escaped index: resolves"  "$( [ "$(rc m9)" = 0 ] && has m9 'latest release: cli-v9.9.9'; echo $?)"
check "★...and the asset list is read (no SKIP)"       "$(! has m9 'availability check SKIPPED'; echo $?)"

# 10) no request to any other host, in any case.
others=$(cat "$work"/m*/log | grep -c '^OTHER' || true)
check "★no case asked any host but the origin and the mirror (GitHub included)" "$( [ "$others" = 0 ]; echo $?)"

if [ "$fail" = 0 ]; then echo "install-sh-mirror: ALL PASS"; else echo "install-sh-mirror: FAILED"; for c in m1 m2 m3 m4 m5 m6 m7 m8 m9; do echo "--- $c (rc $(rc $c))"; cat "$work/$c/out"; cat "$work/$c/log"; done; exit 1; fi
