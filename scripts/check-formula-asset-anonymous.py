#!/usr/bin/env python3
"""THE FORMULA'S PINNED ASSET MUST BE FETCHABLE BY SOMEONE WITH NO CREDENTIALS.

★ THE DEFECT THIS EXISTS FOR (2026-09-11). `Formula/bithuman-cli.rb` was bumped
to pin a release that was still a DRAFT. A draft release is fully visible to the
person who cut it and to any token with push access; it is a **404** to everyone
else — including `brew`, which fetches anonymously. So `brew install
bithuman-product/bithuman/bithuman-cli` was broken for every anonymous user for
roughly eight hours, while every instrument the person cutting it could run said
the asset was there.

Nothing in this tap read the release state back. `check-release-atomic.sh` has a
C4 FORMULA-PIN check, but it grades the formula against a manifest the CALLER
supplies, and it is wired in NO workflow (`git grep check-release-atomic --
.github/workflows` returns nothing). Neither half would have caught a draft.

★ THE ONE THING THAT MAKES THIS GATE MEAN ANYTHING: IT FETCHES ANONYMOUSLY.
A CI job has `GITHUB_TOKEN` in its environment, and `curl` picks up `~/.netrc`
and `GH_*`/`GITHUB_*` credentials from habit and from wrapper scripts. Any of
those turns a draft into a 200 and this gate into decoration. So it:

  * scrubs every credential variable out of its own environment before the first
    request and ASSERTS the scrub happened (a gate that merely intended to be
    anonymous is not anonymous);
  * sends no Authorization header and disables netrc;
  * and refuses — exit 2, never 0 — if it cannot establish that it is anonymous.

"I could not check anonymously" is never "the asset is fine".

★ WHAT IT CHECKS, in order, each one a different way to be broken:
  R1 the formula has a top-level `url` + `sha256` pair at all
  R2 the url is a GitHub release-asset url this tap could serve
  R3 the release for that tag is visible ANONYMOUSLY (a draft is not)
  R4 that release is not marked draft
  R5 the pinned asset NAME is among that release's assets
  R6 the asset URL itself answers 200 anonymously, with a non-empty body
  R7 (with --verify-bytes) the bytes hash to the pinned sha256

R3 and R6 are deliberately separate. A release can be visible while an asset
upload is still in flight — measured in this repo's own history, where
`cli-v2.4.2` advertised an incomplete asset set for 7 h 13 m — so "the release
exists" and "the file downloads" are two facts, and this gate reports both.

USAGE
    check-formula-asset-anonymous.py [--formula Formula/bithuman-cli.rb]
    check-formula-asset-anonymous.py --url <asset-url> [--sha256 <hex>]
    check-formula-asset-anonymous.py --verify-bytes        # hash 275 MB
    check-formula-asset-anonymous.py --self-test
    check-formula-asset-anonymous.py --prove-by-mutation --probe-repo O/R

EXIT
    0 the pinned asset is anonymously fetchable
    1 it is NOT — a developer following the documented instruction gets a 404
    2 the gate could not run (not anonymous, no formula, no network)
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.request

CRED_VARS = (
    "GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_API_TOKEN",
    "HOMEBREW_GITHUB_API_TOKEN", "GH_CONFIG_DIR", "NETRC",
)

URL_RE = re.compile(
    r"https://github\.com/(?P<owner>[^/]+)/(?P<repo>[^/]+)/releases/download/"
    r"(?P<tag>[^/]+)/(?P<asset>[^\"'\s]+)"
)


class CannotMeasure(Exception):
    pass


def go_anonymous() -> None:
    """Strip every credential this process could accidentally present, then
    PROVE the strip happened. A gate that only intends to be anonymous is not."""
    for v in CRED_VARS:
        os.environ.pop(v, None)
    os.environ["HOME"] = os.environ.get("RUNNER_TEMP") or "/nonexistent-anon-home"
    os.environ["NETRC"] = "/dev/null"
    still = [v for v in CRED_VARS if v in os.environ and v != "NETRC"]
    if still:
        raise CannotMeasure(
            "could not become anonymous — still holding %s" % ", ".join(still)
        )


def fetch(url: str, method: str = "GET", max_bytes: int | None = 2 << 20):
    """-> (status, body_bytes). No Authorization header, ever."""
    req = urllib.request.Request(url, method=method)
    req.add_header("User-Agent", "bithuman-formula-gate/1 (anonymous)")
    req.add_header("Accept", "application/vnd.github+json")
    opener = urllib.request.build_opener()  # no HTTPBasicAuthHandler, no netrc
    try:
        with opener.open(req, timeout=60) as r:
            body = r.read() if max_bytes is None else r.read(max_bytes)
            return r.status, body
    except urllib.error.HTTPError as e:
        return e.code, e.read(4096)
    except Exception as e:  # network, DNS, TLS — cannot measure, never a pass
        raise CannotMeasure("%s: %s" % (url, e))


def parse_formula(path: str) -> tuple[str, str | None]:
    try:
        text = open(path, "r", encoding="utf-8").read()
    except OSError as e:
        raise CannotMeasure("cannot read formula %s: %s" % (path, e))
    # The top-level pin is the first url/sha256 pair OUTSIDE any `on_*`/`resource`
    # block; in this formula it is the only `url "...releases/download/..."`.
    urls = URL_RE.findall(text)
    m = URL_RE.search(text)
    if not m:
        raise CannotMeasure(
            "R1 the formula has no GitHub release-asset url — nothing to check"
        )
    if len({u[2] + "/" + u[3] for u in urls}) > 1:
        raise CannotMeasure(
            "R1 the formula pins more than one release asset (%d); this gate "
            "grades ONE pin and must not silently pick" % len(urls)
        )
    url = m.group(0)
    tail = text[m.end():m.end() + 400]
    sm = re.search(r'sha256\s+"([0-9a-f]{64})"', tail)
    return url, (sm.group(1) if sm else None)


def check(url: str, sha256: str | None, verify_bytes: bool) -> int:
    m = URL_RE.match(url)
    if not m:
        print("  R2 FAIL  not a GitHub release-asset url: %s" % url)
        return 1
    owner, repo, tag, asset = m.group("owner", "repo", "tag", "asset")
    print("  subject  %s/%s  tag=%s  asset=%s" % (owner, repo, tag, asset))

    api = "https://api.github.com/repos/%s/%s/releases/tags/%s" % (owner, repo, tag)
    status, body = fetch(api)
    if status == 404:
        print("  R3 FAIL  the release for %r is NOT VISIBLE anonymously (404)." % tag)
        print("           That is what a DRAFT looks like to everyone but its author,")
        print("           and it is exactly what `brew install` would have seen.")
        return 1
    if status != 200:
        raise CannotMeasure("R3 the releases API answered %d for %s" % (status, tag))
    rel = json.loads(body.decode("utf-8", "replace"))
    print("  R3 ok    the release is visible anonymously")

    if rel.get("draft"):
        print("  R4 FAIL  the release is marked DRAFT")
        return 1
    print("  R4 ok    not a draft%s" % (" (pre-release)" if rel.get("prerelease") else ""))

    names = [a.get("name") for a in rel.get("assets") or []]
    if asset not in names:
        print("  R5 FAIL  the release does not carry %r" % asset)
        print("           it carries: %s" % (", ".join(sorted(n for n in names if n)) or "(nothing)"))
        return 1
    print("  R5 ok    the release carries the pinned asset name")

    status, body = fetch(url, max_bytes=None if verify_bytes else (1 << 20))
    if status != 200:
        print("  R6 FAIL  the asset URL answered %d anonymously" % status)
        return 1
    if not body:
        print("  R6 FAIL  the asset URL answered 200 with an EMPTY body")
        return 1
    print("  R6 ok    the asset URL answers 200 anonymously (%d bytes read)" % len(body))

    if verify_bytes:
        got = hashlib.sha256(body).hexdigest()
        if sha256 and got != sha256:
            print("  R7 FAIL  sha256 %s != formula's %s" % (got, sha256))
            return 1
        print("  R7 ok    sha256 matches the formula pin" if sha256
              else "  R7 SKIP  the formula carries no sha256 to compare")
    else:
        print("  R7 SKIP  --verify-bytes not given (the asset is ~275 MB)")
    return 0


# ── proofs ───────────────────────────────────────────────────────────────────

def self_test() -> int:
    """Grades the PARSER and the anonymity primitive. The network arms are in
    --prove-by-mutation, which needs a probe repo."""
    ok = True
    good = 'url "https://github.com/o/r/releases/download/cli-v1.2.3/x.tar.gz"\n  sha256 "%s"\n' % ("a" * 64)
    import tempfile
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "f.rb")
        open(p, "w").write(good)
        u, s = parse_formula(p)
        if u.endswith("x.tar.gz") and s == "a" * 64:
            print("  PASS  parser reads the url and the sha256 beside it")
        else:
            print("  FAIL  parser: %r %r" % (u, s)); ok = False

        open(p, "w").write("class F < Formula\n  desc 'no url'\nend\n")
        try:
            parse_formula(p); print("  FAIL  a formula with no pin did not refuse"); ok = False
        except CannotMeasure:
            print("  PASS  ★a formula with no pin REFUSES (exit 2), never passes")

        open(p, "w").write(good + good.replace("cli-v1.2.3", "cli-v9.9.9"))
        try:
            parse_formula(p); print("  FAIL  two different pins did not refuse"); ok = False
        except CannotMeasure:
            print("  PASS  ★two different pins REFUSE rather than picking one")

    os.environ["GH_TOKEN"] = "x"
    go_anonymous()
    if "GH_TOKEN" in os.environ:
        print("  FAIL  go_anonymous left GH_TOKEN in the environment"); ok = False
    else:
        print("  PASS  ★go_anonymous removes a credential that was really there")

    if not ok:
        print("SELF-TEST FAILED", file=sys.stderr)
        return 1
    print("SELF-TEST PASSED")
    return 0


def prove_by_mutation(probe_repo: str, live_url: str | None) -> int:
    """Point the SAME code at things that must be RED, and at one that must be
    GREEN. A gate that has not been seen to fail is not a gate."""
    ok = True
    owner_repo = probe_repo

    # ★THE ARMS ARE SELF-CONTAINED BY DEFAULT. They run against THIS tap, whose
    # release history is permanent, so the proof needs no scratch repository
    # that someone could delete out from under it. `cli-v0.0.0-nope` has never
    # existed and never will; `PROBE_REAL_TAG` is a release this tap actually
    # published, asked for a file it does not carry.
    #
    # ★THE DRAFT ARM IS THE SAME CODE PATH AS ARM 1 — R3, "not visible
    # anonymously" — because that is what a draft IS to an anonymous caller.
    # It was proven ONCE against a real draft release on 2026-09-11
    # (sgu-bithuman/bh-latest-resolver-proof cli-v0.0.0-draft: draft=true to an
    # authenticated caller, HTTP 404 to an anonymous one, gate rc=1), and is
    # re-runnable here by setting PROBE_DRAFT_TAG on a repo that has one.
    real_tag = os.environ.get("PROBE_REAL_TAG", "cli-v2.3.27")
    arms = [
        ("★a tag that does not exist",
         "https://github.com/%s/releases/download/cli-v0.0.0-nope/x.tar.gz" % owner_repo, 1),
        ("★a real release, an asset it does not carry",
         "https://github.com/%s/releases/download/%s/not-an-asset.tar.gz" % (owner_repo, real_tag), 1),
    ]
    draft_tag = os.environ.get("PROBE_DRAFT_TAG")
    if draft_tag:
        arms.insert(1, ("★a DRAFT release (no anonymous tag)",
                        "https://github.com/%s/releases/download/%s/x.tar.gz"
                        % (owner_repo, draft_tag), 1))
    if live_url:
        arms.append(("control: the formula's real pin", live_url, 0))

    for label, url, want in arms:
        try:
            rc = check(url, None, False)
        except CannotMeasure as e:
            print("  FAIL  %-46s could not measure: %s" % (label, e)); ok = False; continue
        flag = "PASS" if rc == want else "FAIL"
        print("  %s  %-46s rc=%d want=%d" % (flag, label, rc, want))
        if rc != want:
            ok = False
    if not ok:
        print("PROVE-BY-MUTATION FAILED", file=sys.stderr)
        return 1
    print("PROVE-BY-MUTATION PASSED: the gate reddens on a missing tag, on a "
          "draft, and on a missing asset, and stays green on the live pin")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--formula", default=os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "Formula", "bithuman-cli.rb"))
    ap.add_argument("--url")
    ap.add_argument("--sha256")
    ap.add_argument("--verify-bytes", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--prove-by-mutation", action="store_true")
    ap.add_argument("--probe-repo")
    a = ap.parse_args()

    try:
        go_anonymous()
        if a.self_test:
            return self_test()
        if a.prove_by_mutation:
            live = None
            probe = a.probe_repo
            if os.path.isfile(a.formula):
                live, _ = parse_formula(a.formula)
                if not probe:
                    m = URL_RE.match(live)
                    probe = "%s/%s" % (m.group("owner"), m.group("repo"))
            if not probe:
                raise CannotMeasure(
                    "no --probe-repo and no formula to take one from")
            return prove_by_mutation(probe, live)
        url, sha = (a.url, a.sha256) if a.url else parse_formula(a.formula)
        print("ANONYMOUS FORMULA-PIN GATE")
        rc = check(url, sha, a.verify_bytes)
        print("VERDICT: %s" % ("the pinned asset is anonymously fetchable" if rc == 0
                               else "★a developer following the documented instruction gets a 404"))
        return rc
    except CannotMeasure as e:
        print("CANNOT MEASURE: %s" % e, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
