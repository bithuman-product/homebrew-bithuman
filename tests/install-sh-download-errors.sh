#!/bin/sh
# Offline test for install.sh's download error handling (no network, no real
# downloads): a fake `curl` on PATH plays the release origin
# (https://origin.test/homebrew-bithuman). Run from the repo root:
#   sh tests/install-sh-download-errors.sh
# Covers: a 429 on the tarball is retried (honouring Retry-After) and then
# installs; a Retry-After beyond the cap stops at once with an honest
# "rate-limiting" message; a real 404 says the asset is missing; a 403 with an
# exhausted quota during version resolution says "rate-limiting"; and no
# credential is ever sent (a GITHUB_TOKEN in the environment is ignored and never
# printed). Nothing may ever say "may not be published" for a rate limit.
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

# ── fixtures: a tarball whose `bithuman` prints the real --version layout ──
mkdir -p "$work/pkg"
cat > "$work/pkg/bithuman" <<'BIN'
#!/bin/sh
printf 'libessence 9.9.9 ABI 7\nbithuman    9.9.9\nbuild       test\n'
BIN
chmod 755 "$work/pkg/bithuman"
tar -czf "$work/tarball.tgz" -C "$work/pkg" bithuman

mkdir -p "$work/fakebin"
cat > "$work/fakebin/curl" <<'CURL'
#!/bin/sh
# Fake curl: honours -D <hdr> -o <out> -w '%{http_code}' and -H; plays the
# scenario in $FAKE_DIR. Codes are consumed one per call from
# $FAKE_DIR/<kind>.codes (kind = api | tarball | sha); api = latest.json / releases.json.
hdr=""; out=""; url=""; w=""; auth=""
while [ $# -gt 0 ]; do
  case "$1" in
    -D) hdr=$2; shift ;;
    -o) out=$2; shift ;;
    -w) w=$2; shift ;;
    -H) case "$2" in Authorization:*) auth=1 ;; esac; shift ;;
    -*) ;;
    *) url=$1 ;;
  esac
  shift
done
case "$url" in
  https://origin.test/homebrew-bithuman/latest.json|https://origin.test/homebrew-bithuman/releases.json) kind=api ;;
  https://origin.test/homebrew-bithuman/*.sha256) kind=sha ;;
  https://origin.test/homebrew-bithuman/*/*) kind=tarball ;;
  *) kind=other ;;
esac
printf '%s %s auth=%s\n' "$kind" "$url" "${auth:-0}" >> "$FAKE_DIR/log"
codes="$FAKE_DIR/$kind.codes"
code=200
if [ -s "$codes" ]; then
  code=$(head -1 "$codes")
  if [ "$(wc -l < "$codes")" -gt 1 ]; then sed -i.bak 1d "$codes" 2>/dev/null || { tail -n +2 "$codes" > "$codes.t"; mv "$codes.t" "$codes"; }; fi
fi
[ -n "$hdr" ] && {
  printf 'HTTP/2 %s\r\n' "$code" > "$hdr"
  [ -f "$FAKE_DIR/$kind.headers" ] && [ "$code" != 200 ] && cat "$FAKE_DIR/$kind.headers" >> "$hdr"
}
body=""
if [ "$code" = 200 ]; then
  case "$kind" in
    tarball) [ -n "$out" ] && cp "$FAKE_DIR/tarball.tgz" "$out" ;;
    # One release; install.sh reads it as latest.json and as a one-entry releases.json.
    api) body='{
  "tag_name": "cli-v9.9.9",
  "draft": false,
  "prerelease": false,
  "assets": [
    { "name": "bithuman-x86_64-unknown-linux-gnu.tar.gz" },
    { "name": "bithuman-aarch64-unknown-linux-gnu.tar.gz" },
    { "name": "bithuman-aarch64-apple-darwin.tar.gz" }
  ]
}' ;;
    sha) body="" ;;
  esac
else
  body='{"message": "fake error"}'
fi
if [ -n "$body" ]; then
  if [ -n "$out" ]; then printf '%s\n' "$body" > "$out"; else printf '%s\n' "$body"; fi
fi
[ -n "$w" ] && printf '%s' "$code"
case "$code" in 2??) exit 0 ;; *) exit 22 ;; esac
CURL
chmod 755 "$work/fakebin/curl"

run_case() { # <name> ; scenario files already in $work/$name
  d="$work/$1"
  cp "$work/tarball.tgz" "$d/tarball.tgz"
  mkdir -p "$d/bin"
  env -i PATH="$work/fakebin:/usr/bin:/bin" HOME="$d" FAKE_DIR="$d" \
    BITHUMAN_INSTALL_DIR="$d/bin" BITHUMAN_NO_MODIFY_PATH=1 BITHUMAN_MIRROR=off \
    BITHUMAN_DOWNLOADS=https://origin.test/homebrew-bithuman \
    ${CASE_VERSION:+BITHUMAN_VERSION=$CASE_VERSION} \
    ${CASE_TOKEN:+GITHUB_TOKEN=$CASE_TOKEN} \
    sh "$installer" > "$d/out" 2>&1
  echo $? > "$d/rc"
}
check() { # <label> <condition-result 0|1>
  if [ "$2" = 0 ]; then printf '  PASS  %s\n' "$1"; else printf '  FAIL  %s\n' "$1"; fail=1; fi
}
has() { grep -qF -- "$2" "$work/$1/out"; }

# 1) tarball 429 (Retry-After: 1) then 200 -> retried, installed.
mkdir -p "$work/c1"; printf '429\n200\n' > "$work/c1/tarball.codes"; printf 'retry-after: 1\r\n' > "$work/c1/tarball.headers"; printf '404\n' > "$work/c1/sha.codes"
CASE_VERSION=cli-v9.9.9 CASE_TOKEN= run_case c1
check "429 then 200: exit 0"                          "$( [ "$(cat "$work/c1/rc")" = 0 ]; echo $?)"
check "429 then 200: says it is retrying a rate limit" "$(has c1 'rate-limiting this network (HTTP 429); retrying in 1s'; echo $?)"
check "429 then 200: final line names the CLI version" "$(has c1 'installed: bithuman 9.9.9'; echo $?)"
check "429 then 200: never says 'may not be published'" "$(! has c1 'may not be published'; echo $?)"

# 2) tarball 429 with Retry-After: 300 (beyond the 120 s cap) -> stop now, honest.
mkdir -p "$work/c2"; printf '429\n' > "$work/c2/tarball.codes"; printf 'retry-after: 300\r\n' > "$work/c2/tarball.headers"
t0=$(date +%s); CASE_VERSION=cli-v9.9.9 CASE_TOKEN= run_case c2; t1=$(date +%s)
check "429 retry-after 300: exit 1"                    "$( [ "$(cat "$work/c2/rc")" = 1 ]; echo $?)"
check "429 retry-after 300: 'retry in about 300s'"     "$(has c2 'rate-limiting downloads from this network (HTTP 429); retry in about 300s'; echo $?)"
check "429 retry-after 300: no sleep past the cap"     "$( [ $((t1 - t0)) -lt 10 ]; echo $?)"
check "429 retry-after 300: not 'may not be published'" "$(! has c2 'may not be published'; echo $?)"
check "429 retry-after 300: offers a pin"              "$(has c2 'BITHUMAN_VERSION=cli-vX.Y.Z sh'; echo $?)"

# 3) a real 404 on the tarball -> says the release has no such asset, no retry.
mkdir -p "$work/c3"; printf '404\n' > "$work/c3/tarball.codes"
CASE_VERSION=cli-v9.9.9 CASE_TOKEN= run_case c3
check "404: exit 1"                                    "$( [ "$(cat "$work/c3/rc")" = 1 ]; echo $?)"
check "404: names HTTP 404 and the missing asset"      "$(has c3 "download failed (HTTP 404): cli-v9.9.9 has no $T"; echo $?)"
check "404: not called a rate limit"                   "$(! has c3 'rate-limiting'; echo $?)"
check "404: fetched once (no retry)"                   "$( [ "$(grep -c '^tarball' "$work/c3/log")" = 1 ]; echo $?)"

# 4) the index answers 403 with the quota spent, while resolving the latest release.
mkdir -p "$work/c4"; printf '403\n' > "$work/c4/api.codes"
printf 'x-ratelimit-remaining: 0\r\nx-ratelimit-reset: %s\r\n' "$(( $(date +%s) + 900 ))" > "$work/c4/api.headers"
CASE_VERSION= CASE_TOKEN= run_case c4
check "api 403 quota spent: exit 1"                    "$( [ "$(cat "$work/c4/rc")" = 1 ]; echo $?)"
check "api 403 quota spent: says rate-limiting (HTTP 403)" "$(has c4 'rate-limiting downloads from this network (HTTP 403)'; echo $?)"

# 5) a GITHUB_TOKEN in the environment is ignored: no Authorization header, never printed.
mkdir -p "$work/c5"; printf '404\n' > "$work/c5/sha.codes"
CASE_VERSION= CASE_TOKEN=tok-fake-123 run_case c5
check "token present: install ok (latest resolved)"    "$( [ "$(cat "$work/c5/rc")" = 0 ] && grep -q '^api ' "$work/c5/log"; echo $?)"
check "★token present: no Authorization header sent"  "$(! grep -q 'auth=1' "$work/c5/log"; echo $?)"
check "token present: never printed"                   "$(! has c5 'tok-fake-123'; echo $?)"
check "★no request left the origin, in any case"      "$(! cat "$work"/c*/log | grep -q '^other '; echo $?)"

if [ "$fail" = 0 ]; then echo "install-sh-download-errors: ALL PASS"; else echo "install-sh-download-errors: FAILED"; for c in c1 c2 c3 c4 c5; do echo "--- $c (rc $(cat "$work/$c/rc"))"; cat "$work/$c/out"; done; exit 1; fi
