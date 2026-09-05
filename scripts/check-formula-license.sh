#!/usr/bin/env bash
# =============================================================================
# check-formula-license.sh — the formula may not claim an open-source licence
# for a proprietary binary.
#
# ★THE DEFECT THIS EXISTS FOR, FOUND LIVE 2026-09-05. `Formula/bithuman-cli.rb`
# declared `license "Apache-2.0"`. That string is what `brew info bithuman-cli`
# prints to every customer and what every SPDX/licence scanner in their build
# pipeline records. The tarball it installs statically links `libessence.a`
# from the PRIVATE bithuman-models, vendors proprietary model weights, and —
# per this repo's own docs/CONSOLIDATION.md §H — statically links LGPL-2.1
# FFmpeg into a "shipped proprietary binary". It ships 37 members and not one
# LICENSE or NOTICE file. Nothing in the toolchain read that field: `brew
# audit` accepts any valid SPDX identifier, and Apache-2.0 is valid.
#
# ★WHAT IT GRADES. The formula's `license` field must be one of the values that
# can honestly describe a closed binary — `:cannot_represent`, or an explicit
# proprietary/commercial marker — and must NOT be an open-source SPDX id.
#
# ★AND ITS MUTATION ARMS RUN BOTH DIRECTIONS (`--self-test`): the real formula
# must pass, and a formula carrying each of the open-source ids we might
# plausibly regress to must FAIL. A guard that only ever passes has proved
# nothing.
#
# Exit: 0 honest   1 a misstatement   2 could not run (never a silent pass)
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# SPDX identifiers that assert an OPEN-SOURCE grant. None of them can be true
# of a binary whose engine has no public source.
OPEN_SPDX='Apache-2\.0|MIT|BSD-[23]-Clause|GPL-[23]\.0[^"]*|LGPL-[23]\.[01][^"]*|MPL-2\.0|ISC|Unlicense|Zlib|AGPL-3\.0[^"]*'

license_line() { grep -E '^[[:space:]]*license[[:space:]]' "$1" | grep -vE '^[[:space:]]*#' | head -1; }

grade() {
  local f="$1" line
  [ -f "$f" ] || { echo "  FATAL  no such formula: $f — CANNOT-MEASURE, not a pass" >&2; return 2; }
  line="$(license_line "$f")"
  if [ -z "$line" ]; then
    echo "  FATAL  $(basename "$f") declares no license at all — CANNOT-MEASURE" >&2
    return 2
  fi
  if printf '%s' "$line" | grep -qE "\"($OPEN_SPDX)\""; then
    echo "  ★FAIL   $(basename "$f") claims an OPEN-SOURCE licence for a proprietary binary:" >&2
    echo "         $line" >&2
    echo "         The tarball links libessence.a from a private repo and vendors" >&2
    echo "         model weights. Use \`license :cannot_represent\` and point at" >&2
    echo "         https://www.bithuman.ai/terms." >&2
    return 1
  fi
  echo "  honest  $(basename "$f"):$(printf '%s' "$line" | sed 's/^[[:space:]]*/ /')"
  return 0
}

if [ "${1:-}" = "--self-test" ]; then
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  fails=0
  arm() { if [ "$2" = "1" ]; then echo "  PASS  $1"; else echo "  FAIL  $1"; fails=1; fi; }

  printf 'class F < Formula\n  license :cannot_represent\nend\n' > "$tmp/ok.rb"
  grade "$tmp/ok.rb" >/dev/null 2>&1; [ "$?" = "0" ] && arm ":cannot_represent passes" 1 || arm ":cannot_represent passes" 0

  # ★THE CONTROL, AND IT IS THE WHOLE POINT — every open-source id must go RED.
  for id in Apache-2.0 MIT BSD-3-Clause GPL-3.0-only LGPL-2.1-or-later MPL-2.0 ISC; do
    printf 'class F < Formula\n  license "%s"\nend\n' "$id" > "$tmp/bad.rb"
    grade "$tmp/bad.rb" >/dev/null 2>&1
    [ "$?" = "1" ] && arm "★control FIRES on license \"$id\"" 1 || arm "★control FIRES on license \"$id\"" 0
  done

  # ★A COMMENT THAT MENTIONS THE OLD STRING MUST NOT COUNT — the corrected
  # formula explains what it used to say, and a guard that fires on its own
  # explanation is a guard somebody deletes.
  printf 'class F < Formula\n  # it used to read license "Apache-2.0"\n  license :cannot_represent\nend\n' > "$tmp/cmt.rb"
  grade "$tmp/cmt.rb" >/dev/null 2>&1; [ "$?" = "0" ] && arm "★the explanation in a comment does not fire the guard" 1 || arm "★the explanation in a comment does not fire the guard" 0

  # ★NO LICENCE AT ALL, AND A MISSING FILE, ARE BOTH CANNOT-MEASURE — never 0.
  printf 'class F < Formula\nend\n' > "$tmp/none.rb"
  grade "$tmp/none.rb" >/dev/null 2>&1; [ "$?" = "2" ] && arm "★a formula with no license exits 2, not 0" 1 || arm "★a formula with no license exits 2, not 0" 0
  grade "$tmp/absent.rb" >/dev/null 2>&1; [ "$?" = "2" ] && arm "★an absent formula exits 2, not 0" 1 || arm "★an absent formula exits 2, not 0" 0

  echo
  [ "$fails" = "0" ] && { echo "SELF-TEST PASSED"; exit 0; } || { echo "SELF-TEST FAILED"; exit 1; }
fi

rc=0
for f in "$ROOT"/Formula/*.rb; do
  grade "$f" || rc=$?
done
exit "$rc"
