#!/usr/bin/env bash
#
# Notarize the signed macOS CLI staging tree with Apple, then verify.
#
# Usage:  scripts/notarize-macos.sh <stage-dir>
#
# Run scripts/sign-macos.sh FIRST. Notarization only accepts binaries that are
# Developer ID signed with the hardened runtime; an ad-hoc binary is rejected by
# the service, and a Developer ID binary that has NOT been through this script
# is still refused by Gatekeeper:
#
#     $ spctl -a -vv -t install bithuman       # signed, not notarized
#     bithuman: rejected
#     source=Unnotarized Developer ID
#
# That "source=" line is the whole reason this script exists. Signing alone does
# not clear Gatekeeper on any macOS since 10.15 -- only a notarization ticket
# does.
#
# STAPLING -- read this before "fixing" the staple step
# ----------------------------------------------------
# `xcrun stapler` can only attach a ticket to a DISK IMAGE, an INSTALLER
# PACKAGE, or a BUNDLE. It cannot staple a bare Mach-O executable, which is
# exactly what the CLI tarball ships. So the tarball's binaries carry no stapled
# ticket, and Gatekeeper resolves their tickets ONLINE by CDHash on first
# launch. That is the normal, supported arrangement for a loose-executable
# distribution; the staple step below therefore reports rather than fails.
# The practical consequence, stated honestly: a first run on a machine with no
# network path to Apple can still be refused. Shipping a stapled artifact would
# mean shipping a .dmg or .pkg instead of a .tar.gz -- a distribution change,
# not a signing change.
#
# Authentication (first match wins)
#   NOTARY_KEYCHAIN_PROFILE   notarytool profile in the login keychain
#                             (local dev: `bithuman-notary` already exists)
#   NOTARY_KEY + NOTARY_KEY_ID + NOTARY_ISSUER
#                             App Store Connect API key -- the CI path
#   NOTARY_APPLE_ID + NOTARY_TEAM_ID + NOTARY_PASSWORD
#                             Apple ID + app-specific password -- CI fallback
#
set -euo pipefail

STAGE="${1:?usage: notarize-macos.sh <stage-dir>}"
[ -d "$STAGE" ] || { echo "notarize-macos: not a directory: $STAGE" >&2; exit 2; }

# ---- resolve credentials ----------------------------------------------------
if [ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]; then
  AUTH_DESC="keychain profile '$NOTARY_KEYCHAIN_PROFILE'"
  set -- --keychain-profile "$NOTARY_KEYCHAIN_PROFILE"
elif [ -n "${NOTARY_KEY:-}" ] && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER:-}" ]; then
  AUTH_DESC="App Store Connect API key $NOTARY_KEY_ID"
  set -- --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER"
elif [ -n "${NOTARY_APPLE_ID:-}" ] && [ -n "${NOTARY_TEAM_ID:-}" ] && [ -n "${NOTARY_PASSWORD:-}" ]; then
  AUTH_DESC="Apple ID $NOTARY_APPLE_ID (app-specific password)"
  set -- --apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD"
else
  cat >&2 <<'EOF'
notarize-macos: no notarization credentials.

Set ONE of:
  NOTARY_KEYCHAIN_PROFILE=bithuman-notary                     (local dev)
  NOTARY_KEY=<path.p8> NOTARY_KEY_ID=<id> NOTARY_ISSUER=<uuid>  (CI, preferred)
  NOTARY_APPLE_ID=<email> NOTARY_TEAM_ID=<team> NOTARY_PASSWORD=<app-specific>
EOF
  exit 2
fi
echo "notarize-macos: authenticating with $AUTH_DESC"

# ---- build a code-only submission zip ---------------------------------------
# Notarization tickets are keyed by CDHash, not by path, so the ticket issued
# for a binary here is the ticket Gatekeeper finds when that same binary sits in
# the shipped tarball. Only Mach-O files need to go up; embody.model (a zip of
# CoreML .mlpackages) and engines/*.engine (opaque data) carry no code, and
# leaving out ~300MB of weights makes the upload minutes shorter.
WORK="$(mktemp -d -t notarizemacos)"
trap 'rm -rf "$WORK"' EXIT
PAYLOAD="$WORK/payload"
mkdir -p "$PAYLOAD"

COUNT=0
while IFS= read -r f; do
  rel="${f#"$STAGE"/}"
  mkdir -p "$PAYLOAD/$(dirname "$rel")"
  cp -p "$f" "$PAYLOAD/$rel"
  COUNT=$((COUNT + 1))
done < <(find "$STAGE" -type f ! -name '._*' -exec sh -c 'file -b "$1" | grep -q Mach-O && echo "$1"' _ {} \;)

[ "$COUNT" -gt 0 ] || { echo "notarize-macos: no Mach-O files under $STAGE" >&2; exit 2; }
echo "notarize-macos: submitting $COUNT Mach-O files"

ZIP="$WORK/notarize.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$PAYLOAD" "$ZIP"
echo "notarize-macos: payload $(du -h "$ZIP" | cut -f1)"

# ---- submit -----------------------------------------------------------------
SUBMIT_LOG="$WORK/submit.json"
set +e
xcrun notarytool submit "$ZIP" "$@" --wait --timeout 45m --output-format json > "$SUBMIT_LOG" 2>&1
SUBMIT_RC=$?
set -e
cat "$SUBMIT_LOG"

STATUS="$(/usr/bin/python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("status",""))
except Exception: print("")' "$SUBMIT_LOG")"
SUB_ID="$(/usr/bin/python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("id",""))
except Exception: print("")' "$SUBMIT_LOG")"

if [ "$STATUS" != "Accepted" ]; then
  echo "notarize-macos: status='$STATUS' rc=$SUBMIT_RC -- fetching the notary log" >&2
  [ -n "$SUB_ID" ] && xcrun notarytool log "$SUB_ID" "$@" >&2 || true
  exit 1
fi
echo "notarize-macos: ACCEPTED (submission $SUB_ID)"

# ---- staple (reports; see the STAPLING note at the top) ---------------------
# Bare Mach-O executables cannot carry a stapled ticket. Try anyway so the log
# records the real answer from this toolchain rather than an assumption.
while IFS= read -r f; do
  if xcrun stapler staple "$f" >/dev/null 2>&1; then
    echo "notarize-macos: stapled $f"
  else
    echo "notarize-macos: not stapleable (expected for a bare Mach-O): ${f#"$STAGE"/}"
  fi
done < <(find "$STAGE" -maxdepth 1 -type f ! -name '._*' -exec sh -c 'file -b "$1" | grep -q "Mach-O.*executable" && echo "$1"' _ {} \;)

echo "notarize-macos: done"
