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

THE SECOND SURFACE: PUBLISHED RELEASE NOTES
-------------------------------------------
The tree scan's corpus is `git ls-files`, and a release note is NOT a file. It
lives only in GitHub's database, it is world-readable at the same URL as the
tarballs it ships, and it is the first English a customer reads after
`brew upgrade`. That text was therefore never EXEMPTED from this guard -- it
was INVISIBLE to it, which is worse, because a green over the tree then reads
as a green over the repo.

Measured 2026-09-06 over all 70 releases of this repo: 3 carried internal
vocabulary and 67 did not. `--releases` grades every release TITLE plus NOTES
through the same `scan_text` the tree scan uses -- ONE matching primitive, so
the two surfaces can never disagree about what a word is -- and ratchets
against `public-vocabulary-releases-baseline.json`: keyed by TAG instead of by
path, same format, same rule, and itself scanned by the tree scan like every
other file.

★A RELEASE NOTE IS A DATED RECORD, so two things in one must never be
rewritten: a MEASUREMENT quoting literal tokens found in a shipped binary
(rewriting it would make the measurement false), and a path, key or flag a
reader resolves by exact match. Those are exactly what the baseline is for.
Only prose that names the mechanism as though it were the product is edited.

USAGE
    guard-public-vocabulary.py            scan the tree, exit 1 on violation
    guard-public-vocabulary.py --selftest prove the matcher fires (both ways)
    guard-public-vocabulary.py --update   rewrite the baseline from the tree
    guard-public-vocabulary.py --legend   print the code -> meaning table
    guard-public-vocabulary.py --releases        scan every release title+notes
    guard-public-vocabulary.py --update-releases rewrite the release baseline
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
BASELINE = os.path.join(HERE, "public-vocabulary-baseline.json")
RELEASES_BASELINE = os.path.join(HERE, "public-vocabulary-releases-baseline.json")
GITHUB_API = "https://api.github.com"

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


def load_releases_baseline() -> dict:
    if not os.path.exists(RELEASES_BASELINE):
        return {"releases": {}}
    with open(RELEASES_BASELINE) as fh:
        return json.load(fh)


# ---------------------------------------------------------------------------
# THE ONE RATCHET RULE, shared by both surfaces.
#
# It used to live inline in main() and therefore covered the tree only. A
# second surface graded by a SECOND copy of the rule is how two surfaces come
# to disagree about what counts as a leak, so the rule is a function and both
# callers pass it their own key space -- a path for the tree, a tag for a
# release -- and their own re-tighten flag.
# ---------------------------------------------------------------------------
def ratchet(found: dict, base: dict, update_flag: str) -> tuple[list[str], list[str]]:
    errors: list[str] = []
    notices: list[str] = []

    # ---- tier 1: hard zero, the baseline is not consulted at all ----
    for key in sorted(found):
        for code, _, desc in TIER1_RE:
            n = found[key].get(code)
            if n:
                errors.append(
                    f"{key}: {n} occurrence(s) of {code} ({desc}). "
                    f"TIER 1 is a hard zero -- owner ruling: internal-only, so it "
                    f"may not appear in this public repo. There is no baseline "
                    f"entry that can permit it.")

    # ---- tier 2: ratchet against the measured baseline ----
    for key in sorted(found):
        for code in sorted(found[key]):
            if code.startswith("F"):
                continue
            n = found[key][code]
            entry = base.get(key, {}).get(code)
            if entry is None:
                errors.append(
                    f"{key}: {n} occurrence(s) of {code} ({CODES[code]}) with no "
                    f"baseline entry. Remove the word, or pin it with a measured "
                    f"count AND a reason.")
            elif n > int(entry["n"]):
                errors.append(
                    f"{key}: {code} ({CODES[code]}) rose {entry['n']} -> {n}. "
                    f"This is a new leak, not a pinned one.")
            elif n < int(entry["n"]):
                notices.append(f"{key}: {code} fell {entry['n']} -> {n} "
                               f"(good; run {update_flag} to take the slack back)")

    for key in sorted(base):
        for code, entry in base[key].items():
            if found.get(key, {}).get(code, 0) == 0:
                notices.append(f"{key}: {code} pinned at {entry['n']} but now 0 "
                               f"(good; run {update_flag} to drop the entry)")
    return errors, notices


def merge_baseline(found: dict, base: dict) -> dict:
    """Rewrite a baseline from a measurement, carrying every existing reason
    forward. A reason is the half a machine cannot supply, so it is never
    silently regenerated -- only a missing one gets the TODO marker."""
    keep: dict = {}
    for key in sorted(found):
        keep[key] = {}
        for code in sorted(found[key]):
            prev = base.get(key, {}).get(code, {})
            keep[key][code] = {
                "n": found[key][code],
                "why": prev.get("why", "TODO: measured count needs a reason"),
            }
    return keep


# ---------------------------------------------------------------------------
# SURFACE 2: PUBLISHED RELEASE NOTES.  See the module header.
# ---------------------------------------------------------------------------
_TOKEN_CACHE: list = []


def _gh_token():
    """A token when one is reachable, else None.

    ★NEVER PRINTED AND NEVER RETURNED TO OUTPUT. Callers report the BOOLEAN
    `_gh_token() is not None` and nothing else. Unauthenticated reads work on a
    public repo; a token only lifts the 60/hour shared limit, which is what
    keeps a CI run from failing as CANNOT MEASURE on a busy runner."""
    if _TOKEN_CACHE:
        return _TOKEN_CACHE[0]
    tok = None
    for var in ("GITHUB_TOKEN", "GH_TOKEN"):
        v = os.environ.get(var)
        if v:
            tok = v
            break
    if tok is None and shutil.which("gh"):
        r = subprocess.run(["gh", "auth", "token"], capture_output=True, text=True)
        if r.returncode == 0 and r.stdout.strip():
            tok = r.stdout.strip()
    _TOKEN_CACHE.append(tok)
    return tok


def resolve_repo(root: str, explicit: str | None) -> str:
    """OWNER/NAME for the repo whose releases to read: the flag, else CI's own
    GITHUB_REPOSITORY, else this checkout's origin. Guessing a hard-coded name
    would let the guard grade the WRONG repo and still print a green."""
    if explicit:
        return explicit
    env = os.environ.get("GITHUB_REPOSITORY")
    if env:
        return env
    r = subprocess.run(["git", "-C", root, "remote", "get-url", "origin"],
                       capture_output=True, text=True)
    url = r.stdout.strip()
    m = re.search(r"[:/]([^/:]+/[^/]+?)(?:\.git)?$", url)
    if r.returncode != 0 or not m:
        raise RuntimeError("cannot resolve OWNER/NAME -- pass --repo")
    return m.group(1)


def fetch_releases(repo: str, limit: int) -> list[dict]:
    """Every release of `repo`, newest first, as {tag, name, notes, draft}.

    Drafts are graded too, on purpose: a draft is the LAST moment the text can
    be fixed for free, and it becomes world-readable the instant someone clicks
    publish. Any failure raises -- an empty list must never be reachable by
    accident, because an empty corpus prints as a clean surface."""
    tok = _gh_token()
    out: list[dict] = []
    page = 1
    while len(out) < limit:
        url = f"{GITHUB_API}/repos/{repo}/releases?per_page=100&page={page}"
        req = urllib.request.Request(url, headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "guard-public-vocabulary",
        })
        if tok:
            req.add_header("Authorization", "Bearer " + tok)
        with urllib.request.urlopen(req, timeout=30) as fh:
            batch = json.loads(fh.read().decode("utf-8"))
        if not batch:
            break
        for r in batch:
            out.append({
                "tag": r.get("tag_name") or f"id:{r.get('id')}",
                "name": r.get("name") or "",
                "notes": r.get("body") or "",
                "draft": bool(r.get("draft")),
            })
        if len(batch) < 100:
            break
        page += 1
    return out[:limit]


def grade_releases(releases: list[dict]) -> dict[str, dict[str, int]]:
    """{tag: {code: n}} over TITLE + NOTES, through the SAME `scan_text` the
    tree scan uses. The self-test exercises this function directly with an
    injected corpus, so it is graded without a network call."""
    found: dict[str, dict[str, int]] = {}
    for r in releases:
        hits = scan_text((r.get("name") or "") + "\n" + (r.get("notes") or ""))
        if hits:
            found[r["tag"]] = hits
    return found


def run_releases(root: str, repo_arg: str | None, limit: int, update: bool) -> int:
    try:
        repo = resolve_repo(root, repo_arg)
    except Exception as e:                                      # noqa: BLE001
        print(f"CANNOT MEASURE: {e}", file=sys.stderr)
        return 2
    try:
        rels = fetch_releases(repo, limit)
    except Exception as e:                                      # noqa: BLE001
        print(f"CANNOT MEASURE: could not read the releases of {repo}: {e}",
              file=sys.stderr)
        return 2
    if not rels:
        print(f"CANNOT MEASURE: {repo} returned no releases -- an empty corpus "
              f"would print as a clean surface", file=sys.stderr)
        return 2

    found = grade_releases(rels)
    base = load_releases_baseline().get("releases", {})

    if update:
        doc = {
            "_": ("Pinned occurrences of internal vocabulary in the PUBLISHED "
                  "release titles and notes of this PUBLIC repo -- the surface "
                  "the tree scan cannot see, because a release note is not a "
                  "file. Codes are defined by "
                  "scripts/guard-public-vocabulary.py --legend; they are codes "
                  "rather than words so that this file needs no self-exclusion "
                  "from the tree scan that also reads it. Every entry carries a "
                  "measured count and a reason; an entry without a real reason "
                  "is a defect. Keys are release TAGS."),
            "releases": merge_baseline(found, base),
        }
        with open(RELEASES_BASELINE, "w") as fh:
            json.dump(doc, fh, indent=2, sort_keys=True)
            fh.write("\n")
        print(f"release baseline rewritten: {len(doc['releases'])} release(s)")
        return 0

    errors, notices = ratchet(found, base, "--update-releases")
    drafts = sum(1 for r in rels if r["draft"])
    print(f"scanned {len(rels)} release(s) of {repo} (title + notes; "
          f"{drafts} draft), authenticated: {_gh_token() is not None}")
    for n in notices:
        print(f"  note: {n}")
    if errors:
        print(f"\nREFUSED: {len(errors)} vocabulary violation(s) in published "
              f"release text\n")
        for e in errors:
            print(f"  * {e}")
        print("\nA release note has no parser -- editing the PROSE breaks no "
              "client. A dated MEASUREMENT or an exact-match path/key must be "
              "pinned in scripts/public-vocabulary-releases-baseline.json "
              "instead, with its count and its reason.")
        return 1
    print(f"OK: no new internal vocabulary in release text "
          f"({len(base)} release(s) pinned in the baseline, tier 1 at zero)")
    return 0


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

    # ---- SURFACE 2: release notes. The corpus is INJECTED, so this arm
    #      needs no network and cannot be a fork bomb: it calls grade_releases
    #      and ratchet directly, which are the same functions --releases runs.
    planted = [{"tag": "vX", "name": "", "draft": False,
                "notes": "routed with the " + "tess" + "era teeth " + "bo" + "rrow"}]
    cleanrel = [{"tag": "vX", "draft": False,
                 "name": "bithuman CLI 9.9.9 (macOS + Linux)",
                 "notes": "Signed and notarized. Smaller download. No API change."}]
    checks.append(("release note: planted string FIRES",
                   grade_releases(planted) == {"vX": {"V1": 1, "V2": 1}},
                   "a planted internal word in release text must score"))
    checks.append(("release note: ordinary note scores ZERO",
                   grade_releases(cleanrel) == {},
                   "a clean release note must score nothing -- if this fails the "
                   "green from --releases is meaningless"))
    checks.append(("release note: TITLE is graded too, not only the body",
                   grade_releases([{"tag": "vY", "draft": False, "notes": "",
                                    "name": "the " + "tess" + "era release"}])
                   == {"vY": {"V2": 1}},
                   "the title is the line a customer reads first"))
    e_new, _ = ratchet({"vX": {"V2": 1}}, {}, "--update-releases")
    checks.append(("release ratchet: an unpinned hit is an ERROR", len(e_new) == 1,
                   "a new leak with no baseline entry must be refused"))
    e_pin, _ = ratchet({"vX": {"V2": 1}}, {"vX": {"V2": {"n": 1, "why": "x"}}},
                       "--update-releases")
    checks.append(("release ratchet: a pinned count is accepted", e_pin == [],
                   "a measured, reasoned pin must pass"))
    e_up, _ = ratchet({"vX": {"V2": 2}}, {"vX": {"V2": {"n": 1, "why": "x"}}},
                      "--update-releases")
    checks.append(("release ratchet: an INCREASE over a pin is an ERROR",
                   len(e_up) == 1, "the ratchet must only turn one way"))
    e_t1, _ = ratchet({"vX": {"F1": 1}}, {"vX": {"F1": {"n": 1, "why": "x"}}},
                      "--update-releases")
    checks.append(("release ratchet: tier 1 cannot be pinned away", len(e_t1) == 1,
                   "a baseline entry must not be able to permit tier 1"))

    # This file AND the baselines must themselves be clean.
    #
    # These checks are appended UNCONDITIONALLY. They used to be guarded by
    # os.path.exists, and that hole cost a bad push on 2026-09-05: the baseline
    # did not exist yet, so its check silently vanished, the run still printed
    # a confident "11/11", and a baseline whose reasons SPELLED the banned
    # words went out green. A self-test whose denominator moves on its own
    # cannot be read as coverage. An absent baseline is now a visible FAIL,
    # not a skipped line -- write reasons that name the V-codes instead of the
    # words and both files stay clean without any self-exclusion.
    for p in (os.path.abspath(__file__), BASELINE, RELEASES_BASELINE):
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
    # ---- surface 2: the published release titles + notes ----
    ap.add_argument("--releases", action="store_true",
                    help="grade every release title + notes instead of the tree")
    ap.add_argument("--update-releases", action="store_true",
                    help="rewrite the release baseline from a fresh measurement")
    ap.add_argument("--repo", default=None,
                    help="OWNER/NAME to read releases from "
                         "(default: $GITHUB_REPOSITORY, else this checkout's origin)")
    ap.add_argument("--limit", type=int, default=1000,
                    help="most recent N releases to grade (default: all)")
    args = ap.parse_args()

    if args.legend:
        for c, d in CODES.items():
            tier = 1 if c.startswith("F") else 2
            print(f"  {c:4s} tier{tier}  {d}")
        return 0

    if args.selftest:
        return selftest()

    root = os.path.abspath(args.root)

    if args.releases or args.update_releases:
        return run_releases(root, args.repo, args.limit, args.update_releases)

    found = scan_tree(root)
    base = load_baseline().get("files", {})

    if args.update:
        keep = merge_baseline(found, base)
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

    errors, notices = ratchet(found, base, "--update")

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
