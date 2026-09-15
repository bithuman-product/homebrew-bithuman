#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""verify_latest_badge.py -- DOES /releases/latest STILL RESOLVE TO THE CLI?

`https://github.com/bithuman-product/homebrew-bithuman/releases/latest`, and a
bare `gh release view`, resolve to whichever release carries GitHub's Latest
flag.  Only a `cli-v*` release may carry it (RELEASE.md, "The Latest badge is a
separate, sticky flag"): that URL is what a tool or a human reads to learn the
CLI version, and it answers with a release's tag, assets and notes -- so a
non-CLI release holding it hands a reader the wrong version and the wrong
downloads, quietly and with a 200.

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

★WHAT IT CANNOT SEE.  `install.sh` is unaffected either way -- it resolves
 `cli-v*` through its own `pick_latest_real_release()` and never reads this
 endpoint.  This grades the badge, not the installer.

`--selftest` feeds the checker synthetic API answers in-process (never a
re-exec, which is how a positive control becomes a fork bomb).  It needs no
network, so the instrument is provable on exactly the runs where the network
is what broke.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request

REPO = "bithuman-product/homebrew-bithuman"
CLI = "cli-v"
ARMS = 9  # ★a denominator that moves on its own is not coverage


class Refusal(Exception):
    """exit 1 -- I looked, and the badge is wrong."""


class CannotCheck(Exception):
    """exit 2 -- I could not look.  Never 0."""


class NotFound(Exception):
    """HTTP 404: an answer from the API, not an outage."""


def live(repo: str):
    """The real API, as one `get(path)` so --selftest can substitute for it."""
    def get(path: str):
        req = urllib.request.Request(
            "https://api.github.com/repos/%s/%s" % (repo, path),
            headers={"Accept": "application/vnd.github+json",
                     "User-Agent": "bithuman-latest-badge-gate"})
        tok = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
        if tok:
            req.add_header("Authorization", "Bearer %s" % tok)
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


def newest_cli(index: list):
    """The release that SHOULD hold the badge: newest `cli-v*` by `created_at`
    among non-draft, non-prerelease releases.  GitHub will not serve a draft or
    a prerelease as Latest, so re-pinning one would be a remedy that does
    nothing -- and `created_at` is the order GitHub's own fallback uses."""
    ok = [r for r in index or []
          if str(r.get("tag_name") or "").startswith(CLI)
          and not r.get("draft") and not r.get("prerelease")]
    return max(ok, key=lambda r: r.get("created_at") or "", default=None)


def check(get, repo: str = REPO) -> list:
    """Grade the live badge.  Returns the PASS lines, or raises."""
    try:
        latest = get("releases/latest")
    except NotFound:
        latest = None

    if latest is not None:
        tag = str(latest.get("tag_name") or "")
        seen = ("/releases/latest -> %s  (id %s, draft=%s, prerelease=%s, "
                "created %s)" % (tag or "<no tag_name>", latest.get("id"),
                                 bool(latest.get("draft")),
                                 bool(latest.get("prerelease")),
                                 latest.get("created_at")))
        if tag.startswith(CLI):
            return [seen, "held by a %s* tag, which is the rule (RELEASE.md, "
                          "'The Latest badge is a separate, sticky flag')" % CLI]
        problem = ("the Latest badge is held by %r (id %s) -- not a %s* tag"
                   % (tag, latest.get("id"), CLI))
    else:
        problem = ("/releases/latest answers HTTP 404 -- the badge resolves to "
                   "NOTHING, so a reader asking it for the CLI version gets an "
                   "error instead of a version")

    # Only a failing badge costs a second request: the PASS path is the one
    # that runs every day, and the anonymous budget is 60/hour per address.
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
            "so there is nothing to re-pin. Cut a CLI release first "
            "(RELEASE.md, 'Releasing'). A re-pin cannot come before it."
            % (problem, CLI, len(index or [])))

    fix = ["    gh api -X PATCH repos/%s/releases/%s -f make_latest=true"
           % (repo, cli.get("id"))]
    if latest is not None:
        fix.insert(0, "    gh api -X PATCH repos/%s/releases/%s -f "
                      "make_latest=false   # the thief" % (repo, latest.get("id")))
    raise Refusal(
        "%s.\n  It belongs to %s (id %s, created %s).\n"
        "  REMEDY (RELEASE.md, 'The Latest badge is a separate, sticky flag'):\n"
        "%s\n"
        "  ★Clearing the thief's flag alone is NOT enough -- GitHub then falls "
        "back to the newest non-draft, non-prerelease release by created_at "
        "and hands the badge straight back. The re-pin is the load-bearing "
        "line. Never fix this by deleting, retagging or moving a release."
        % (problem, cli.get("tag_name"), cli.get("id"), cli.get("created_at"),
           "\n".join(fix)))


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
    print("GREEN -- /releases/latest resolves to the CLI.")
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
         "gh api -X PATCH repos/%s/releases/388704408 -f make_latest=true" % REPO])
    arm("★theft 1: essence2-v1.6.3 holds it", 1, _api(ESS, [ESS, C20]),
        ["essence2-v1.6.3", "cli-v2.6.20", "make_latest=true"])
    arm("a newer DRAFT/PRERELEASE cli-v* is not the re-pin target", 1,
        _api(FLU, [FLU, DRF, PRE, C20]), ["cli-v2.6.20"],
        ["cli-v2.6.21", "cli-v2.6.22"])
    arm("★no cli-v* release exists at all -> a DIFFERENT remedy", 1,
        _api(FLU, [FLU, DRF, PRE]),
        ["no published, non-prerelease cli-v* release at all",
         "Cut a CLI release first"], ["make_latest=true"])
    arm("the badge resolves to nothing (/releases/latest 404)", 1,
        _api(None, [C20]), ["404", "cli-v2.6.20", "make_latest=true"])
    arm("★an unreachable API is CANNOT CHECK, never a pass", 2,
        _api(C20, down="URLError: [Errno -3] name resolution failed"),
        ["name resolution failed"])
    arm("the repo itself 404s (bad token) is CANNOT CHECK, not a verdict", 2,
        _api(FLU, None), ["I could not look"])

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
    return selftest() if ap.parse_args(argv).selftest else verify(REPO)


if __name__ == "__main__":
    sys.exit(main())
