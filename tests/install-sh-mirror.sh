#!/bin/sh
# Offline test for install.sh's bitHuman download mirror (no network): a fake `curl` on PATH
# plays both the mirror (https://mirror.test/...) and GitHub. Run from the repo root:
#   sh tests/install-sh-mirror.sh
# Covers: a healthy mirror installs with ZERO GitHub requests (latest and pinned); a mirror that
# is down, or lacks the version, falls back to GitHub and installs; a mirror whose bytes do not
# match its sidecar is REFUSED (never installed, never silently swapped); BITHUMAN_MIRROR=off
# never touches the mirror.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
installer="$here/install.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
fail=0
T=bithuman-x86_64-unknown-linux-gnu.tar.gz

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
# Fake curl: -o <out>, -D <hdr>, -w '%{http_code}'. Mirror URLs are files under $FAKE_DIR/mirror
# ($FAKE_DIR/mirror_down = connection refused); GitHub always answers 200 (sidecar 404).
hdr=""; out=""; url=""; w=""
while [ $# -gt 0 ]; do
  case "$1" in
    -D) hdr=$2; shift ;; -o) out=$2; shift ;; -w) w=$2; shift ;;
    -H|--connect-timeout|--max-time|--speed-limit|--speed-time) shift ;;
    -*) ;; *) url=$1 ;;
  esac; shift
done
case "$url" in
  https://mirror.test/*)
    printf 'mirror %s\n' "$url" >> "$FAKE_DIR/log"
    [ -f "$FAKE_DIR/mirror_down" ] && exit 7
    f="$FAKE_DIR/mirror/${url#https://mirror.test/ai/bithuman/bithuman-cli/}"
    [ -f "$f" ] || exit 22
    if [ -n "$out" ]; then cp "$f" "$out"; else cat "$f"; fi; exit 0 ;;
esac
printf 'github %s\n' "$url" >> "$FAKE_DIR/log"
[ -n "$hdr" ] && printf 'HTTP/2 200\r\n' > "$hdr"
code=200; body=""
case "$url" in
  *.sha256) code=404 ;;
  *releases/download/*) [ -n "$out" ] && cp "$FAKE_DIR/../tarball.tgz" "$out" ;;
  *api.github.com*) body='{
  "tag_name": "cli-v9.9.9",
  "draft": false,
  "prerelease": false,
  "assets": [
    { "name": "bithuman-x86_64-unknown-linux-gnu.tar.gz" },
    { "name": "bithuman-aarch64-unknown-linux-gnu.tar.gz" },
    { "name": "bithuman-aarch64-apple-darwin.tar.gz" }
  ]
}' ;;
esac
[ -n "$hdr" ] && printf 'HTTP/2 %s\r\n' "$code" > "$hdr"
if [ -n "$body" ]; then if [ -n "$out" ]; then printf '%s\n' "$body" > "$out"; else printf '%s\n' "$body"; fi; fi
[ -n "$w" ] && printf '%s' "$code"
case "$code" in 2??) exit 0 ;; *) exit 22 ;; esac
CURL
chmod 755 "$work/fakebin/curl"

mirror_with() { # <case> <version> <sha-to-publish>  -> a mirror holding that version
  m="$work/$1/mirror"; mkdir -p "$m/$2"
  printf '<metadata><versioning><latest>%s</latest><release>%s</release></versioning></metadata>\n' "$2" "$2" > "$m/maven-metadata.xml"
  cp "$work/tarball.tgz" "$m/$2/$T"
  printf '%s  %s\n' "$3" "$T" > "$m/$2/$T.sha256"
}
run_case() { # <name> [BITHUMAN_VERSION] [BITHUMAN_MIRROR]
  d="$work/$1"; mkdir -p "$d/bin"; : > "$d/log"
  env -i PATH="$work/fakebin:/usr/bin:/bin" HOME="$d" FAKE_DIR="$d" \
    BITHUMAN_INSTALL_DIR="$d/bin" BITHUMAN_NO_MODIFY_PATH=1 \
    BITHUMAN_MIRROR="${3:-https://mirror.test/ai/bithuman/bithuman-cli}" \
    ${2:+BITHUMAN_VERSION=$2} \
    sh "$installer" > "$d/out" 2>&1
  echo $? > "$d/rc"
}
check() { if [ "$2" = 0 ]; then printf '  PASS  %s\n' "$1"; else printf '  FAIL  %s\n' "$1"; fail=1; fi; }
rc() { cat "$work/$1/rc"; }
has() { grep -qF -- "$2" "$work/$1/out"; }
gh_n() { grep -c '^github' "$work/$1/log"; }

# 1) healthy mirror, latest: resolves + downloads + verifies with ZERO GitHub requests.
mirror_with m1 9.9.9 "$sum"; run_case m1
check "mirror latest: exit 0"                         "$( [ "$(rc m1)" = 0 ]; echo $?)"
check "mirror latest: version from maven-metadata.xml" "$(has m1 'latest release (bitHuman mirror): cli-v9.9.9'; echo $?)"
check "mirror latest: sha256 verified"                "$(has m1 'sha256 ok'; echo $?)"
check "★mirror latest: no GitHub request at all"      "$( [ "$(gh_n m1)" = 0 ]; echo $?)"
check "mirror latest: binary installed"               "$( [ -x "$work/m1/bin/bithuman" ]; echo $?)"

# 2) healthy mirror, pinned version: no GitHub request.
mirror_with m2 9.9.9 "$sum"; run_case m2 cli-v9.9.9
check "mirror pinned: exit 0, no GitHub request"      "$( [ "$(rc m2)" = 0 ] && [ "$(gh_n m2)" = 0 ]; echo $?)"

# 3) mirror down -> GitHub resolves + downloads, install succeeds.
mkdir -p "$work/m3"; : > "$work/m3/mirror_down"; run_case m3
check "★mirror down: falls back to GitHub, exit 0"    "$( [ "$(rc m3)" = 0 ] && [ "$(gh_n m3)" -ge 1 ]; echo $?)"
check "mirror down: says it is using GitHub"          "$(has m3 '(or is unreachable); using GitHub'; echo $?)"

# 4) mirror up but without this (pinned) version -> GitHub.
mirror_with m4 9.9.8 "$sum"; run_case m4 cli-v9.9.9
check "version not mirrored: GitHub, exit 0"          "$( [ "$(rc m4)" = 0 ] && grep -q '^github .*releases/download/cli-v9.9.9/' "$work/m4/log"; echo $?)"

# 5) mirror bytes do not match the mirror's sidecar -> refused, nothing installed.
mirror_with m5 9.9.9 0000000000000000000000000000000000000000000000000000000000000000; run_case m5
check "★mirror sha mismatch: exit 1, refused"         "$( [ "$(rc m5)" = 1 ] && has m5 'sha256 mismatch'; echo $?)"
check "mirror sha mismatch: nothing installed"        "$( [ ! -e "$work/m5/bin/bithuman" ]; echo $?)"

# 6) BITHUMAN_MIRROR=off -> the mirror is never asked.
mirror_with m6 9.9.9 "$sum"; run_case m6 "" off
check "BITHUMAN_MIRROR=off: exit 0, mirror never asked" "$( [ "$(rc m6)" = 0 ] && ! grep -q '^mirror' "$work/m6/log"; echo $?)"

if [ "$fail" = 0 ]; then echo "install-sh-mirror: ALL PASS"; else echo "install-sh-mirror: FAILED"; for c in m1 m2 m3 m4 m5 m6; do echo "--- $c (rc $(rc $c))"; cat "$work/$c/out"; cat "$work/$c/log"; done; exit 1; fi
