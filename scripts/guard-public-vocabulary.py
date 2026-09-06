#!/usr/bin/env python3
"""guard-public-vocabulary.py — this repo is PUBLIC; keep internal words out of it.

WHY THIS EXISTS
---------------
This repository is world-readable (verified 2026-09-05 by unauthenticated
fetch: raw.githubusercontent.com/.../Sources/BithumanEngineProtocol/Bhci.swift
-> HTTP 200, against a control path that returns 404). Until this guard landed
there was NO vocabulary check in this repo at all -- `scripts/` held only
release/signing helpers, and the naming guard that exists in the PRIVATE
engine monorepo is a DIFFERENT check (ultralight naming) that never ran here.
So the internal model name and the implementation vocabulary that reached the
published tree were unguarded, and a text-only fix without a guard would be a
backfill rather than a fix.

SCOPE -- READ THIS BEFORE COPYING THE FILE
------------------------------------------
This guard is for the PUBLIC repo only. The internal vocabulary it rejects is
LEGITIMATE inside the private engine monorepo, in internal docs and in internal
symbols. Do NOT copy this file there: it would fire on correct code.

TWO TIERS
---------
  TIER 1 (forbidden, hard zero, no exception is representable)
      The internal-only model family name. Owner ruling 2026-09-05:
      internal-only, so it may appear in NO customer-facing artifact, and a
      public repo is the most customer-facing artifact there is. There is
      deliberately NO baseline mechanism for tier 1 -- a hit is always red.

  TIER 2 (implementation vocabulary, ratcheted)
      The banned customer-facing words. The tree did not start clean, so each
      surviving occurrence is pinned in public-vocabulary-baseline.json with a
      MEASURED COUNT and a REASON. An unmeasured exclusion would be the defect,
      not the fix, so there is no way to silence a file without recording both.

NO PATH IS EXCLUDED FROM THE SCAN -- INCLUDING THIS FILE
--------------------------------------------------------
A vocabulary guard that skips itself, or skips its own baseline, is a guard
with a hole exactly where the vocabulary lives. So both files are scanned like
any other, and both must read ZERO. That is why the patterns below are
assembled from fragments ("bo" "rrow") and why the baseline keys on the codes
V1..V11 rather than on the words: it lets the mechanism describe the ban
without ever spelling it, so no self-exclusion is needed. If you edit the
patterns, keep them fragmented or this file will fail its own scan.

PATTERN PRECISION -- EVERY NARROWING BELOW WAS MEASURED, NOT GUESSED
--------------------------------------------------------------------
Matching is per-word rather than one blanket rule because a blanket rule is
wrong in BOTH directions, measured on this tree at b0829b249:

  * word-boundary matching UNDERCOUNTS. `grep -w` scores the brew caveats at
    ZERO for V1, while the customer-visible text there carries V1 twice -- once
    with a trailing "s" and once with a trailing "_state". Both `s` and `_` are
    word characters, so the boundary form misses the very leak it exists to
    catch. V1/V2/V3/V4 therefore match as SUBSTRINGS.
  * substring matching OVERCOUNTS, badly. As substrings, V8 scores 117 because
    it is a prefix of "directory", and V7 scores 249 because it occurs inside
    hex digests. V5..V11 therefore require word boundaries.

Two further narrowings, each with its measured count:
  * V10 skips Docker's own command and file name (measured: 34 occurrences of
    the command form + 4 of the file form). Those are a third party's
    vocabulary in customer instructions, not ours.
  * V11 skips a leading "." (measured: 5), which is the mathematical constant
    in the Swift and Dart sample code, not our term.
Both are PATTERN-level, not path-level, on purpose: a pattern narrowing cannot
hide an unrelated leak elsewhere in the same file, whereas skipping a path can.

RATCHET DIRECTION
-----------------
An INCREASE over baseline, or ANY occurrence in a file with no baseline entry,
is red. A DECREASE is green and prints a tighten hint: a guard that fails the
person who REMOVED a banned word teaches people to disable it. Re-tighten with
`--update`. The known slack this leaves is stated in --help.

USAGE
    guard-public-vocabulary.py            scan the tree, exit 1 on violation
    guard-public-vocabulary.py --selftest prove the matcher fires (both ways)
    guard-public-vocabulary.py --update   rewrite the baseline from the tree
    guard-public-vocabulary.py --legend   print the code -> meaning table
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BASELINE = os.path.join(HERE, "public-vocabulary-baseline.json")

# --------------------------------------------------------------------------
# The vocabulary. Patterns are built from fragments so that this file contains
# none of the words it bans and can therefore be scanned like every other file.
# `desc` is a neutral description used in output; it also avoids the words.
# --------------------------------------------------------------------------

TIER1 = [
    # The internal-only model family, plus the hyphenless / underscored spellings
    # and the alias form. Hard zero -- the baseline cannot represent tier 1.
    ("F1", "d" + "ream" + r"[-_ ]?1\b", "internal-only model family name"),
]

TIER2 = [
    # code, pattern, human description
    ("V1", "bo" + "rrow", "acquisition verb for the teeth path"),
    ("V2", "tess" + "era", "internal subsystem name"),
    ("V3", r"pass[-_ ]?through", "internal stamp state"),
    ("V4", "don" + "or", "internal source-identity term"),
    ("V5", r"\b" + "ban" + r"ks?\b", "internal store term"),
    ("V6", r"\b" + "arm" + r"(?:ing|ed)\b", "internal readiness term"),
    ("V7", r"\b" + "w" + r"0\b", "internal tap symbol"),
    ("V8", r"\b" + "direct" + r"ors?\b", "internal graph term"),
    ("V9", r"\b" + "plan" + r"es?\b", "internal target term"),
    # V10: not Docker's command ("docker compose") nor its file ("compose.yml").
    ("V10", r"(?<!docker )(?<!docker-)\b" + "compos" + r"(?:e|es|ed|ing|ite)\b(?!\.ya?ml)",
     "internal blend stage"),
    # V11: not the mathematical constant, which is always dot-prefixed here.
    ("V11", r"(?<![.\w])" + "p" + r"i\b", "internal deriver symbol"),
]

TIER1_RE = [(c, re.compile(p, re.I), d) for c, p, d in TIER1]
TIER2_RE = [(c, re.compile(p, re.I), d) for c, p, d in TIER2]

CODES = {c: d for c, _, d in TIER1} | {c: d for c, _, d in TIER2}


def scan_text(text: str) -> dict[str, int]:
    """Count occurrences per code in one blob. The single matching primitive --
    the self-test exercises exactly this function, so a pass here is a pass of
    the code the tree scan actually uses."""
    out: dict[str, int] = {}
    for code, rx, _ in TIER1_RE + TIER2_RE:
        n = len(rx.findall(text))
        if n:
            out[code] = n
    return out


def tracked_files(root: str) -> list[str]:
    """Tracked REAL files, symlinks excluded -- measured, not stylistic.

    This tree carries 28 tracked symlinks: Aliases/bithuman, and 27 under
    packages/flutter-plugin/{ios,macos}/Classes that each point at the one
    real copy in ../../shared/Classes. `git ls-files` lists all of them, and
    opening a link FOLLOWS it, so the single source file would be read three
    times and every count over it inflated 3x. Filtering on the index mode
    (120000 = symlink) rather than on os.path.islink keeps the answer the
    same on a checkout that never materialised the links.
    """
    r = subprocess.run(["git", "-C", root, "ls-files", "-s", "-z"],
                       check=True, capture_output=True)
    out: list[str] = []
    for ent in r.stdout.decode().split("\0"):
        if not ent:
            continue
        meta, _, rel = ent.partition("\t")
        if not rel or meta.split(" ", 1)[0] == "120000":
            continue
        out.append(rel)
    return out


def read_text(path: str) -> str | None:
    """Return decoded text, or None for a binary file. Binaries are skipped
    because a hex digest reliably contains short tokens by chance -- but they
    are skipped by CONTENT, never by name, so no path can opt out."""
    try:
        with open(path, "rb") as fh:
            blob = fh.read()
    except OSError:
        return None
    if b"\0" in blob:
        return None
    try:
        return blob.decode("utf-8")
    except UnicodeDecodeError:
        return None


def scan_tree(root: str) -> dict[str, dict[str, int]]:
    found: dict[str, dict[str, int]] = {}
    for rel in tracked_files(root):
        text = read_text(os.path.join(root, rel))
        if text is None:
            continue
        hits = scan_text(text)
        if hits:
            found[rel] = hits
    return found


def load_baseline() -> dict:
    if not os.path.exists(BASELINE):
        return {"files": {}}
    with open(BASELINE) as fh:
        return json.load(fh)


def selftest() -> int:
    """Prove the matcher can FAIL as well as pass, in-process.

    Deliberately does NOT re-invoke this program: a positive control that
    re-runs itself is how a self-test becomes a fork bomb. It calls scan_text
    directly, which is the same primitive scan_tree uses.
    """
    checks: list[tuple[str, bool, str]] = []

    # must FIRE
    checks.append(("tier1 plain", "F1" in scan_text("model: dr" + "eam-1 here"), "F1"))
    checks.append(("tier1 hyphenless", "F1" in scan_text("slug dr" + "eam1"), "F1"))
    checks.append(("tier2 substring form", "V1" in scan_text("reports " + "bo" + "rrow_state"),
                   "V1 must match inside a longer token"))
    checks.append(("tier2 plural form", "V2" in scan_text("the " + "tess" + "era ban" + "k"), "V2"))
    checks.append(("tier2 boundary word", "V8" in scan_text("the " + "direct" + "or graph"), "V8"))

    # must NOT fire (the narrowings)
    checks.append(("no false hit on directory", "V8" not in scan_text("a directory of files"),
                   "V8 must not match 'directory'"))
    checks.append(("no false hit on docker cmd", "V10" not in scan_text("run docker " + "compos" + "e up"),
                   "V10 must not match Docker's command"))
    checks.append(("no false hit on constant",
                   "V11" not in scan_text("angle * 180 / ." + "p" + "i"),
                   "V11 must not match the math constant"))
    checks.append(("no false hit on arch", "V6" not in scan_text("built for arm64 darwin"),
                   "V6 must not match arm64"))
    checks.append(("clean text is clean", scan_text("a perfectly ordinary sentence") == {},
                   "clean input must score zero"))

    # This file AND the baseline must themselves be clean.
    #
    # These checks are appended UNCONDITIONALLY. They used to be guarded by
    # os.path.exists, and that hole cost a bad push on 2026-09-05: the baseline
    # did not exist yet, so its check silently vanished, the run still printed
    # a confident "11/11", and a baseline whose reasons SPELLED the banned
    # words went out green. A self-test whose denominator moves on its own
    # cannot be read as coverage. An absent baseline is now a visible FAIL,
    # not a skipped line -- write reasons that name the V-codes instead of the
    # words and both files stay clean without any self-exclusion.
    for p in (os.path.abspath(__file__), BASELINE):
        name = os.path.basename(p)
        if not os.path.exists(p):
            checks.append((f"self-clean {name}", False,
                           f"{name} is missing -- run --update to write it"))
            continue
        t = read_text(p)
        checks.append((f"self-clean {name}",
                       t is not None and scan_text(t) == {},
                       "the guard and its baseline must not need a self-exclusion; "
                       "write baseline reasons with the V-codes, never the words"))

    bad = [(n, w) for n, ok, w in checks if not ok]
    for name, ok, _ in checks:
        print(f"  {'ok  ' if ok else 'FAIL'}  {name}")
    if bad:
        print(f"\nself-test FAILED ({len(bad)} of {len(checks)})")
        for n, w in bad:
            print(f"  - {n}: {w}")
        return 1
    print(f"\nself-test passed: {len(checks)}/{len(checks)} "
          f"(it both fires and refuses to fire)")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Keep internal vocabulary out of this PUBLIC repo.",
        epilog=("Known slack, stated on purpose: a count BELOW baseline is "
                "accepted (so that removing a banned word never fails the "
                "build), which leaves room to re-add up to the pinned count in "
                "a file that already has an entry. A NEW file, a NEW word, or "
                "any INCREASE is rejected. Run --update after a cleanup to "
                "take that slack back."))
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--update", action="store_true")
    ap.add_argument("--legend", action="store_true")
    ap.add_argument("--root", default=os.path.dirname(HERE))
    args = ap.parse_args()

    if args.legend:
        for c, d in CODES.items():
            tier = 1 if c.startswith("F") else 2
            print(f"  {c:4s} tier{tier}  {d}")
        return 0

    if args.selftest:
        return selftest()

    root = os.path.abspath(args.root)
    found = scan_tree(root)
    base = load_baseline().get("files", {})

    if args.update:
        keep = {}
        for path in sorted(found):
            keep[path] = {}
            for code in sorted(found[path]):
                prev = base.get(path, {}).get(code, {})
                keep[path][code] = {
                    "n": found[path][code],
                    "why": prev.get("why", "TODO: measured count needs a reason"),
                }
        doc = {
            "_": ("Pinned occurrences of internal vocabulary in this PUBLIC repo. "
                  "Codes are defined by scripts/guard-public-vocabulary.py --legend; "
                  "they are codes rather than words so that this file needs no "
                  "self-exclusion from the scan. Every entry carries a measured "
                  "count and a reason; an entry without a real reason is a defect."),
            "files": keep,
        }
        with open(BASELINE, "w") as fh:
            json.dump(doc, fh, indent=2, sort_keys=True)
            fh.write("\n")
        print(f"baseline rewritten: {len(keep)} files")
        return 0

    errors: list[str] = []
    notices: list[str] = []

    # ---- tier 1: hard zero, baseline is not consulted at all ----
    for path in sorted(found):
        for code, _, desc in TIER1_RE:
            n = found[path].get(code)
            if n:
                errors.append(
                    f"{path}: {n} occurrence(s) of {code} ({desc}). "
                    f"TIER 1 is a hard zero -- owner ruling: internal-only, so it "
                    f"may not appear in this public repo. There is no baseline "
                    f"entry that can permit it.")

    # ---- tier 2: ratchet against measured baseline ----
    for path in sorted(found):
        for code in sorted(found[path]):
            if code.startswith("F"):
                continue
            n = found[path][code]
            entry = base.get(path, {}).get(code)
            if entry is None:
                errors.append(
                    f"{path}: {n} occurrence(s) of {code} ({CODES[code]}) with no "
                    f"baseline entry. Remove the word, or pin it with a measured "
                    f"count AND a reason.")
            elif n > int(entry["n"]):
                errors.append(
                    f"{path}: {code} ({CODES[code]}) rose {entry['n']} -> {n}. "
                    f"This is a new leak, not a pinned one.")
            elif n < int(entry["n"]):
                notices.append(f"{path}: {code} fell {entry['n']} -> {n} "
                               f"(good; run --update to take the slack back)")

    for path in sorted(base):
        for code, entry in base[path].items():
            if found.get(path, {}).get(code, 0) == 0:
                notices.append(f"{path}: {code} pinned at {entry['n']} but now 0 "
                               f"(good; run --update to drop the entry)")

    scanned = len(tracked_files(root))
    print(f"scanned {scanned} tracked files under {root}")
    for n in notices:
        print(f"  note: {n}")

    if errors:
        print(f"\nREFUSED: {len(errors)} vocabulary violation(s)\n")
        for e in errors:
            print(f"  * {e}")
        print("\nThis repo is public. See the header of "
              "scripts/guard-public-vocabulary.py for the two tiers and for why "
              "an unmeasured exclusion is not an acceptable fix.")
        return 1

    print(f"OK: no new internal vocabulary "
          f"({len(base)} file(s) pinned in the baseline, tier 1 at zero)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
