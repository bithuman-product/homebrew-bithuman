#!/usr/bin/env bash
#
# Verify a macOS CLI tarball the way a CUSTOMER receives it: quarantined.
#
# Usage:  scripts/verify-macos-release.sh <tarball.tar.gz>
#
# Why quarantine is the only honest test
# --------------------------------------
# Gatekeeper does not evaluate a file that carries no com.apple.quarantine
# attribute. Homebrew fetches with curl, which sets none, so a `brew install`
# runs an ad-hoc binary perfectly happily -- which is precisely how bitHuman
# shipped ad-hoc binaries for its whole history without a single support
# ticket. Testing an un-quarantined copy proves nothing at all.
#
# A browser download DOES set com.apple.quarantine on the .tar.gz, and macOS
# propagates it onto every extracted member -- with plain `tar -xzf`, not just
# with Archive Utility. Measured on macOS 26.6.2 against cli-v2.4.2:
#
#     $ xattr -w com.apple.quarantine "0083;...;Safari;..." bithuman-...tar.gz
#     $ tar -xzf bithuman-...tar.gz -C out && out/bithuman --version
#     $ echo $?
#     137                      <- SIGKILL. No message. No prompt. Nothing.
#
# So this script quarantines the tarball first and asserts on what comes out.
#
set -euo pipefail

TGZ="${1:?usage: verify-macos-release.sh <tarball.tar.gz>}"
[ -f "$TGZ" ] || { echo "verify-macos: no such file: $TGZ" >&2; exit 2; }

WORK="$(mktemp -d -t verifymacos)"
trap 'rm -rf "$WORK"' EXIT

cp "$TGZ" "$WORK/dl.tar.gz"
# A Safari-shaped quarantine record: flags;timestamp;agent;UUID.
xattr -w com.apple.quarantine \
      "0083;$(printf '%x' "$(date +%s)");Safari;$(uuidgen)" "$WORK/dl.tar.gz"

mkdir -p "$WORK/out"
tar -xzf "$WORK/dl.tar.gz" -C "$WORK/out"
BIN="$WORK/out/bithuman"
[ -f "$BIN" ] || { echo "verify-macos: tarball has no ./bithuman" >&2; exit 2; }

echo "== quarantine actually present on the extracted binary =="
if ! xattr -p com.apple.quarantine "$BIN" >/dev/null 2>&1; then
  echo "verify-macos: FAIL -- quarantine did not propagate; this test is void" >&2
  exit 2
fi
xattr -p com.apple.quarantine "$BIN"

fail=0

echo "== codesign -dv =="
DESC="$(codesign -dvvv "$BIN" 2>&1)"
echo "$DESC" | grep -E 'flags=|Authority=|TeamIdentifier=|Signature=' || true
case "$DESC" in
  *"Signature=adhoc"*|*"flags=0x2(adhoc)"*)
    echo "verify-macos: FAIL -- binary is AD-HOC signed" >&2; fail=1 ;;
esac
case "$DESC" in
  *"Developer ID Application: bitHuman Inc. (G64NFNZX84)"*) ;;
  *) echo "verify-macos: FAIL -- not signed by the bitHuman Developer ID" >&2; fail=1 ;;
esac
case "$DESC" in
  *"flags=0x10000(runtime)"*) ;;
  *) echo "verify-macos: FAIL -- hardened runtime not enabled" >&2; fail=1 ;;
esac

echo "== codesign --verify --deep --strict =="
if codesign --verify --deep --strict --verbose=2 "$BIN"; then
  echo "verify-macos: codesign --verify OK"
else
  echo "verify-macos: FAIL -- codesign --verify" >&2; fail=1
fi

echo "== spctl -a -vv -t install =="
if spctl -a -vv -t install "$BIN" 2>&1; then
  echo "verify-macos: spctl install ACCEPTED"
else
  echo "verify-macos: FAIL -- spctl -t install rejected" >&2; fail=1
fi

echo "== spctl -a -vv -t exec (informational -- see note) =="
# `-t exec` asks "is this a launchable APPLICATION". A bare CLI executable is
# not an app, so a correctly signed and notarized `bithuman` still comes back
#
#     rejected (the code is valid but does not seem to be an app)
#     origin=Developer ID Application: bitHuman Inc. (G64NFNZX84)
#
# That is the right answer to the wrong question, and asserting on it would be
# calling correct behaviour a defect. Note how different it is from the ad-hoc
# build's bare `rejected` with no origin at all. The load-bearing assertions
# for a command-line tool are `-t install` above and the actual launch below;
# this block only fails if `-t exec` rejects for some OTHER reason.
set +e
EXEC_OUT="$(spctl -a -vv -t exec "$BIN" 2>&1)"
EXEC_RC=$?
set -e
echo "$EXEC_OUT"
if [ "$EXEC_RC" -ne 0 ]; then
  case "$EXEC_OUT" in
    *"does not seem to be an app"*)
      echo "verify-macos: -t exec n/a for a bare executable (expected)" ;;
    *)
      echo "verify-macos: FAIL -- spctl -t exec rejected for an unexpected reason" >&2
      fail=1 ;;
  esac
else
  echo "verify-macos: spctl exec ACCEPTED"
fi

echo "== run the quarantined binary (the customer's first launch) =="
# This is the assertion that actually matters. An ad-hoc binary dies here with
# rc=137 (SIGKILL) and prints nothing.
set +e
OUT="$("$BIN" --version 2>&1)"
RC=$?
set -e
echo "$OUT"
echo "run rc=$RC"
if [ "$RC" -ne 0 ]; then
  echo "verify-macos: FAIL -- quarantined binary did not run (rc=$RC)" >&2
  fail=1
fi

[ "$fail" -eq 0 ] || { echo "verify-macos: FAILED" >&2; exit 1; }
echo "verify-macos: PASS -- Developer ID, notarized, and runs under quarantine"
