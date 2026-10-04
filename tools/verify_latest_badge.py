#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""verify_latest_badge.py -- DOES latest.json STILL NAME THE CLI?

★2026-10: releases moved to https://downloads.bithuman.ai.  The "Latest badge" is now
`https://downloads.bithuman.ai/homebrew-bithuman/latest.json` (GitHub's /releases/latest
shape), derived by the downloads publisher.  Only a `cli-v*` release may be it
(RELEASE.md): that file is what the installers and the CLI's update notice read to
learn the CLI version, so a non-CLI release there hands a reader the wrong version
and the wrong downloads, quietly and with a 200.  The publisher's --latest auto and
scripts/downloads-publish.py (--latest false for every non-CLI family) make a theft
unlikely; this detector is what proves it, every day.

THE GITHUB HISTORY BELOW is why the detector exists; the mechanics it describes
(`make_latest`, `gh release create`) no longer apply.

WHY THIS EXISTS (both thefts measured 2026-09-15)
─────────────────────────────────────────────────
`gh release create` sets `make_latest=true` unless told otherwise, so EVERY
non-CLI publish in this repo takes the badge, whatever the dates say.  It was
taken twice in fourteen hours: `essence2-v1.6.3` held it over the newer
`cli-v2.6.20`, then the hand-cut `flutter-plugin-vendor-v1` took it again.

★A FLAG ON THE PUBLISHER CANNOT CLOSE THIS, which is why the control is a
 detector and not another guard:
 1. `--latest=false` does not undo a theft that already happened.  With the
    flag merely cleared, GitHub falls back to the newest non-draft,
    non-prerelease release by `created_at` -- which was still the thief.  Only
    an explicit `make_latest=true` re-pin on the CLI release moved it back.
 2. No workflow publishes `flutter-plugin-vendor-v*` or the tap's bare `v2.x`
    releases.  They are cut BY HAND, so there is no workflow to add a flag to.
    Commit 626d828 added `--latest=false` to `publish-essence2-apple.yml` and
    closed exactly one of the ways in.

THE THREE OUTCOMES, WHICH ARE NEVER COLLAPSED
─────────────────────────────────────────────
  exit 0  PASS         -- Latest is a `cli-v*` tag.
  exit 1  REFUSED      -- it is not.  Names the thief, names the CLI release
                          that should hold it, prints the remedy, and says so
                          differently when there is no `cli-v*` release to
                          re-pin at all.
  exit 2  CANNOT CHECK -- the API did not answer.  ★A network failure that
                          returns 0 is a control an outage disarms, and "I
                          could not look" is a failure you can see.

★WHAT IT CANNOT SEE.  `install.sh` cross-checks latest.json (a non-cli-v* or
 pre-release answer is not trusted; it picks from releases.json instead), so it is
 safe either way.  This grades the file, not the installer.

`--selftest` feeds the checker synthetic API answers in-process (never a
re-exec, which is how a positive control becomes a fork bomb).  It needs no
network, so the instrument is provable on exactly the runs where the network
is what broke.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

REPO = "homebrew-bithuman"
BASE = os.environ.get("BITHUMAN_DOWNLOADS_BASE", "https://downloads.bithuman.ai").rstrip("/")
PUBLISH = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                       "scripts", "downloads-publish.py")
CLI = "cli-v"
ARMS = 12  # ★a denominator that moves on its own is not coverage


class Refusal(Exception):
    """exit 1 -- I looked, and the badge is wrong."""


class CannotCheck(Exception):
    """exit 2 -- I could not look.  Never 0."""


class NotFound(Exception):
    """HTTP 404: an answer from the API, not an outage."""


def live(repo: str):
    """The public downloads index, as one `get(path)` so --selftest can substitute
    for it: "releases/latest" is latest.json, "releases..." is releases.json."""
    def get(path: str):
        name = "latest.json" if path.startswith("releases/latest") else "releases.json"
        req = urllib.request.Request("%s/%s/%s" % (BASE, repo, name),
                                     headers={"User-Agent": "bithuman-latest-badge-gate"})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.loads(r.read().decode())
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                raise NotFound("HTTP 404 on /%s" % path) from None
            raise CannotCheck("HTTP %d on /%s" % (exc.code, path)) from None
        except Exception as exc:                                # noqa: BLE001
            raise CannotCheck("%s on /%s: %s"
                              % (type(exc).__name__, path, exc)) from None
    return get


def _ver(tag: str):
    m = re.fullmatch(re.escape(CLI) + r"(\d+)\.(\d+)\.(\d+)", tag or "")
    return tuple(int(x) for x in m.groups()) if m else (-1,)


def newest_cli(index: list):
    """The release that SHOULD be latest.json: the highest `cli-vX.Y.Z` VERSION
    among non-draft, non-prerelease releases -- the order the installers and the
    publisher's --latest auto use (a later patch to an older line never wins)."""
    ok = [r for r in index or []
          if str(r.get("tag_name") or "").startswith(CLI)
          and not r.get("draft") and not r.get("prerelease")]
    return max(ok, key=lambda r: (_ver(r.get("tag_name")), r.get("created_at") or ""), default=None)


def check(get, repo: str = REPO) -> list:
    """Grade the live badge.  Returns the PASS lines, or raises."""
    try:
        latest = get("releases/latest")
    except NotFound:
        latest = None

    if latest is not None:
        tag = str(latest.get("tag_name") or "")
        seen = ("latest.json -> %s  (id %s, draft=%s, prerelease=%s, "
                "created %s)" % (tag or "<no tag_name>", latest.get("id"),
                                 bool(latest.get("draft")),
                                 bool(latest.get("prerelease")),
                                 latest.get("created_at")))
        if tag.startswith(CLI):
            return [seen, "held by a %s* tag, which is the rule (RELEASE.md, "
                          "'Only cli-v* may be latest.json')" % CLI]
        problem = ("latest.json names %r (id %s) -- not a %s* tag"
                   % (tag, latest.get("id"), CLI))
    else:
        problem = ("latest.json answers HTTP 404 -- it names NOTHING, so a "
                   "reader asking it for the CLI version gets an error instead "
                   "of a version")

    # Only a failing check costs a second request: the PASS path is the one
    # that runs every day.
    try:
        index = get("releases?per_page=100")
    except NotFound:
        raise CannotCheck(
            "%s answered 404 for its releases index too, so this caller cannot "
            "read the repository at all -- that is 'I could not look', not a "
            "verdict on the badge" % repo)

    cli = newest_cli(index)
    if cli is None:
        raise Refusal(
            "%s.\n  ★AND THE REMEDY IS A DIFFERENT ONE: this repository has no "
            "published, non-prerelease %s* release at all (%d release(s) read), "
            "so there is nothing to point latest.json at. Cut a CLI release "
            "first (RELEASE.md, 'Releasing'). A re-pin cannot come before it."
            % (problem, CLI, len(index or [])))

    fix = ["    scripts/downloads-publish.py set-latest %s" % cli.get("tag_name")]
    raise Refusal(
        "%s.\n  It belongs to %s (id %s, created %s).\n"
        "  REMEDY (RELEASE.md, 'Only cli-v* may be latest.json'):\n"
        "%s\n"
        "  It rewrites latest.json only; assets and download URLs stay byte-for-"
        "byte intact. Never fix this by deleting, retagging or moving a release."
        % (problem, cli.get("tag_name"), cli.get("id"), cli.get("created_at"),
           "\n".join(fix)))


def heal(get, patch, repo: str = REPO) -> list:
    """★THE DETECTOR CLOSES ITS OWN LOOP (2026-09-26). Red every hour from
    06:45Z to 12:1xZ on 2026-09-26 and nobody acted (lane B's
    cli-engine-expression2-apple-v7 took the badge; every CLI older than
    2.7.8 printed no update notice for those hours). The remedy was always
    mechanical, so the scheduled run now applies it: re-pin the newest
    published cli-v* release (the load-bearing line of the REMEDY), then grade
    AGAIN. Returns the lines of a HEALED run; raises what `check` raises when
    there is nothing to re-pin, when the re-pin is refused, or when the badge
    is still wrong after it."""
    try:
        return check(get, repo)
    except Refusal:
        pass
    index = get("releases?per_page=100")
    cli = newest_cli(index)
    if cli is None:
        return check(get, repo)        # re-raises the "cut a CLI release first" refusal
    try:
        patch(cli.get("tag_name"))
    except CannotCheck as exc:
        raise Refusal("the badge is wrong and the re-pin of %s was refused (%s) "
                      "-- run the REMEDY by hand" % (cli.get("tag_name"), exc)) from None
    lines = check(get, repo)            # the second reading is the proof
    return ["HEALED -- re-pinned %s (id %s) as Latest" % (cli.get("tag_name"),
                                                         cli.get("id"))] + lines


def live_patch(repo: str):
    """Point latest.json at a tag through the downloads publisher (it needs the
    bucket credentials; see scripts/downloads-publish.py)."""
    def patch(tag: str):
        rc = subprocess.call([sys.executable, PUBLISH, "--repo", repo, "set-latest", tag])
        if rc != 0:
            raise CannotCheck("downloads-publish.py set-latest %s exited %d" % (tag, rc))
    return patch


def verify_heal(repo: str) -> int:
    try:
        lines = heal(live(repo), live_patch(repo), repo)
    except CannotCheck as exc:
        print("::error::CANNOT CHECK -- %s" % exc, file=sys.stderr)
        return 2
    except Refusal as exc:
        print("::error::REFUSED -- %s" % exc, file=sys.stderr)
        return 1
    if lines and lines[0].startswith("HEALED"):
        print("::warning::%s" % lines[0], file=sys.stderr)
    for line in lines:
        print("  ok  " + line)
    print("GREEN -- latest.json names the CLI.")
    return 0


def verify(repo: str, get=None) -> int:
    try:
        lines = check(get or live(repo), repo)
    except CannotCheck as exc:
        print("::error::CANNOT CHECK -- %s" % exc, file=sys.stderr)
        return 2
    except Refusal as exc:
        print("::error::REFUSED -- %s" % exc, file=sys.stderr)
        return 1
    for line in lines:
        print("  ok  " + line)
    print("GREEN -- latest.json names the CLI.")
    return 0


# ── SELF-TEST: EVERY ARM MUST FIRE, IN-PROCESS, WITH NO NETWORK ──────────────
def _rel(tag, rid, created, draft=False, pre=False):
    return {"tag_name": tag, "id": rid, "created_at": created,
            "draft": draft, "prerelease": pre}


# Real shapes, off the live API on 2026-09-15.
C20 = _rel("cli-v2.6.20", 388704408, "2026-09-14T20:53:20Z")
FLU = _rel("flutter-plugin-vendor-v1", 389131686, "2026-09-15T12:12:59Z")
ESS = _rel("essence2-v1.6.3", 388097285, "2026-09-13T21:33:21Z")
# Synthetic, and NEWER than C20 on purpose: a draft and a prerelease that
# GitHub would never serve as Latest must never be named as the re-pin target.
PRE = _rel("cli-v2.6.21", 389200001, "2026-09-15T14:00:00Z", pre=True)
DRF = _rel("cli-v2.6.22", 389200002, "2026-09-15T15:00:00Z", draft=True)


def _api(latest, index=None, down=None):
    def get(path):
        if down:
            raise CannotCheck(down)
        if path.startswith("releases/latest"):
            if latest is None:
                raise NotFound("HTTP 404 on /releases/latest")
            return latest
        if index is None:
            raise NotFound("HTTP 404 on /releases")
        return index
    return get


def selftest() -> int:
    ran = []

    def arm(name, want, get, must=(), never=()):
        try:
            text, rc = "\n".join(check(get, REPO)), 0
        except Refusal as exc:
            text, rc = str(exc), 1
        except CannotCheck as exc:
            text, rc = str(exc), 2
        why = ""
        if rc != want:
            why = "exit %d, demanded %d" % (rc, want)
        elif [m for m in must if m not in text]:
            why = "exit %d but never names %s" % (rc, [m for m in must if m not in text])
        elif [n for n in never if n in text]:
            why = "exit %d but wrongly names %s" % (rc, [n for n in never if n in text])
        ran.append((name, why))
        print("  %-5s exit %d  %-56s | %s"
              % ("ok" if not why else "★BAD", rc, name,
                 text.splitlines()[0][:78] if text else "<no message>"))
        if why:
            print("        ★%s" % why)

    arm("PASS: a cli-v* tag holds the badge", 0, _api(C20), ["cli-v2.6.20"])
    arm("PASS holds with a NEWER non-cli release present (today)", 0,
        _api(C20, [FLU, C20]), ["cli-v2.6.20"])
    arm("★theft 2: flutter-plugin-vendor-v1 holds it", 1, _api(FLU, [FLU, C20]),
        ["flutter-plugin-vendor-v1", "cli-v2.6.20", "389131686",
         "set-latest cli-v2.6.20"])
    arm("★theft 1: essence2-v1.6.3 holds it", 1, _api(ESS, [ESS, C20]),
        ["essence2-v1.6.3", "cli-v2.6.20", "set-latest cli-v2.6.20"])
    arm("a newer DRAFT/PRERELEASE cli-v* is not the re-pin target", 1,
        _api(FLU, [FLU, DRF, PRE, C20]), ["cli-v2.6.20"],
        ["cli-v2.6.21", "cli-v2.6.22"])
    arm("★no cli-v* release exists at all -> a DIFFERENT remedy", 1,
        _api(FLU, [FLU, DRF, PRE]),
        ["no published, non-prerelease cli-v* release at all",
         "Cut a CLI release first"], ["set-latest"])
    arm("the badge resolves to nothing (latest.json 404)", 1,
        _api(None, [C20]), ["404", "cli-v2.6.20", "set-latest cli-v2.6.20"])
    arm("★an unreachable API is CANNOT CHECK, never a pass", 2,
        _api(C20, down="URLError: [Errno -3] name resolution failed"),
        ["name resolution failed"])
    arm("the repo itself 404s (bad token) is CANNOT CHECK, not a verdict", 2,
        _api(FLU, None), ["I could not look"])

    # ★THE HEAL ARMS: the re-pin is applied to the NEWEST published cli-v*, the
    # second reading is what makes it green, and a refused PATCH is red.
    def healed_api(start, index):
        state = {"latest": start}
        def get(path):
            if path.startswith("releases/latest"):
                return state["latest"]
            return index
        def patch(tag):
            state["latest"] = next(r for r in index if r["tag_name"] == tag)
            state["patched"] = state["latest"]["id"]
        return get, patch, state

    def heal_arm(name, want, get, patch, must=()):
        try:
            text, rc = "\n".join(heal(get, patch, REPO)), 0
        except Refusal as exc:
            text, rc = str(exc), 1
        except CannotCheck as exc:
            text, rc = str(exc), 2
        why = "" if rc == want and not [m for m in must if m not in text] else \
            "exit %d (demanded %d) text %r" % (rc, want, text[:120])
        ran.append((name, why))
        print("  %-5s exit %d  %-56s | %s" % ("ok" if not why else "★BAD", rc, name,
                                              text.splitlines()[0][:78] if text else ""))

    g, p, st = healed_api(FLU, [FLU, DRF, PRE, C20])
    heal_arm("HEAL: a theft is re-pinned to the newest cli-v*, then passes", 0, g, p,
             ["HEALED -- re-pinned cli-v2.6.20", "cli-v2.6.20"])
    ran[-1] = (ran[-1][0], ran[-1][1] or ("" if st.get("patched") == 388704408
                                          else "patched %r" % st.get("patched")))

    def refused_patch(tag):
        raise CannotCheck("downloads-publish.py set-latest %s exited 2" % tag)
    heal_arm("HEAL: a refused re-pin is RED, never green", 1, _api(FLU, [FLU, C20]),
             refused_patch, ["re-pin of cli-v2.6.20 was refused"])
    heal_arm("HEAL: nothing to re-pin keeps the cut-a-release refusal", 1,
             _api(FLU, [FLU, DRF, PRE]), refused_patch, ["Cut a CLI release first"])

    bad = [n for n, why in ran if why]
    if len(ran) != ARMS:
        print("\n★SELF-TEST FAILED: %d arm(s) ran, %d demanded -- an arm that "
              "stops running silently is how a self-test becomes decoration"
              % (len(ran), ARMS))
        return 1
    if bad:
        print("\n★SELF-TEST FAILED: %d of %d arm(s) misbehaved: %s"
              % (len(bad), ARMS, bad))
        return 1
    print("\nself-test OK -- %d/%d arms fired: the badge passes only for a "
          "cli-v* tag, every theft is refused BY NAME with its remedy, and an "
          "API that cannot be read exits 2 rather than green." % (ARMS, ARMS))
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--selftest", action="store_true",
                    help="run the arms in-process against synthetic API "
                         "answers (no network, no re-exec)")
    ap.add_argument("--heal", action="store_true",
                    help="when latest.json is wrong, point it at the newest "
                         "cli-v* release (downloads-publish.py set-latest; needs "
                         "the bucket credentials) and grade again")
    a = ap.parse_args(argv)
    if a.selftest:
        return selftest()
    return verify_heal(REPO) if a.heal else verify(REPO)


if __name__ == "__main__":
    sys.exit(main())
