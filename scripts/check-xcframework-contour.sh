#!/usr/bin/env bash
# =============================================================================
# check-xcframework-contour.sh — EVERY SLICE OF libessence2.xcframework.zip
# CARRIES THE LIP-CONTOUR BIND, OR THE TAG IS NOT CUT.
#
#   scripts/check-xcframework-contour.sh <libessence2.xcframework.zip>
#
# ★WHY (2026-09-20, gap #34). The essence-2 mouth is drawn through a mask
# that, since bithuman-models #941, is Min(a, lip_delivery) — the lip contour
# bound at load — and before it was the ellipse baked into the graph. The CLI
# (cli-v2.6.23) and the Android coordinate (essence2-android 0.5.11) both
# shipped the ellipse through every green gate they had, because no rail read
# the SHIPPED bytes for the bind. This is that read for the Apple package: the
# one spelling the bind cannot be built without, `lip_delivery` (the ORT input
# the template is fed through and the `[le] … LIP CONTOUR` load line),
# counted in each libessence2.a slice. A `[borrow] delivery mask: LIP CONTOUR`
# string is NOT that fact — the ellipse cores spell it too (the teeth borrow
# mask, a different mask).
#
# Measured on the PUBLISHED archives of this repo, every slice:
#   essence2-v1.8.0  lip_delivery=0 x3   (the ellipse; REFUSED here)
#   essence2-v1.9.0  lip_delivery=7 x3   (the contour; passes)
#
# `strings -a` reads RAW BYTES ON STDIN, never `strings -a <path>`: handed a
# path, Apple's strings(1) treats a static library as an ar archive, walks its
# members and stops at the first header it dislikes (publish-essence2-apple.yml
# learned this on 2026-09-19). On stdin both Apple's and GNU's scan end to end.
#
# Exit: 0 every slice carries it   1 a slice does not (do NOT cut the tag)
#       2 usage / not a readable archive (never a silent pass)
# =============================================================================
set -uo pipefail
ZIP="${1:-}"
[ -n "$ZIP" ] || { echo "usage: $0 <libessence2.xcframework.zip>" >&2; exit 2; }
[ -s "$ZIP" ] || { echo "check-xcframework-contour: no such archive: $ZIP" >&2; exit 2; }
W="$(mktemp -d "${TMPDIR:-/tmp}/xcfcontour.XXXXXX")"
trap 'rm -rf "$W"' EXIT
if command -v ditto >/dev/null 2>&1; then ditto -x -k "$ZIP" "$W" || exit 2; else unzip -q -o "$ZIP" -d "$W" || exit 2; fi
# The instrument proves it can fire before it grades: bytes shaped like a slice.
printf '!<arch>\n\327\377\376\000lip_delivery\000' > "$W/red.a"
printf '!<arch>\n\327\377\376\000lip_contour_v1.json\000' > "$W/green.a"
[ "$(strings -a < "$W/red.a" | grep -c lip_delivery)" -ge 1 ] || { echo "check-xcframework-contour: the reading path is BLIND (control did not fire)" >&2; exit 2; }
[ "$(strings -a < "$W/green.a" | grep -c lip_delivery)" -eq 0 ] || { echo "check-xcframework-contour: the reading path is INDISCRIMINATE" >&2; exit 2; }
SLICES="$(find "$W" -name libessence2.a -type f | sort)"
N="$(printf '%s\n' "$SLICES" | grep -c . || true)"
[ "$N" -eq 3 ] || { echo "::error::check-xcframework-contour: expected 3 libessence2.a slices, found $N" >&2; exit 1; }
rc=0
while IFS= read -r a; do
  n="$(strings -a < "$a" | grep -c lip_delivery || true)"
  rel="${a#"$W"/}"
  if [ "$n" -ge 1 ]; then echo "  ok      $rel  strings lip_delivery=$n"
  else echo "::error::  ★REFUSED $rel spells 'lip_delivery' 0 times — this slice draws the graph's ELLIPSE (pre-#941; essence2-v1.8.0 shipped exactly this). Not a tag to cut." >&2; rc=1; fi
done <<< "$SLICES"
[ "$rc" -eq 0 ] && echo "  ok      every slice carries the lip-contour bind (lip_delivery)"
exit $rc
