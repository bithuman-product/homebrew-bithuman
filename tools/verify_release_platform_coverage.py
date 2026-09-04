#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""verify_release_platform_coverage.py -- DID THE CLI RELEASE LOSE A PLATFORM?

The GitHub-Releases twin of bithuman-models' tools/verify_pypi_platform_
coverage.py, which guards `pip install bithuman`.  This one guards
`curl -sSL install.bithuman.ai | sh`.

WHY THIS EXISTS (measured 2026-09-02)
─────────────────────────────────────
`cli-v2.5.0` shipped TWO assets -- bithuman-aarch64-apple-darwin.tar.gz and its
.sha256.  `cli-v2.4.2` before it shipped FOUR: the same pair PLUS
bithuman-x86_64-unknown-linux-gnu.tar.gz(.sha256).  install.sh resolves the
newest `cli-v*` tag and downloads `bithuman-<target>.tar.gz` from it, so from
the moment 2.5.0 was published every Linux customer running the documented
one-liner got:

    curl: (22) The requested URL returned error: 404
    install: error: download failed.
    install: error: The tarball for x86_64-unknown-linux-gnu may not be
                    published for cli-v2.5.0.
    -> rc=1

Reproduced on lafayette, rc read directly (not through a pipe), before this
file was written.

Nothing was broken.  release-cli.yml's `linux-tarball` job had just been
GATED behind `inputs.build_linux` -- correctly, because it used to run on
every dispatch and end in an unguarded `gh release upload --clobber`, so a
mac-only dispatch could silently REPLACE a published Linux tarball.  One
hazard closed, another opened: a dispatch with build_linux=false now publishes
a macOS-only release and the run goes GREEN, because ★NOTHING COMPARED WHAT
THE RELEASE CARRIES AGAINST WHAT THE RELEASE BEFORE IT HAD.  That is the hole,
and this file is it.

WHAT THIS DOES
──────────────
Reads the repo's Releases index and refuses if the release under test carries
fewer (asset-kind, target-triple) pairs than the CLI release before it.  A
release may ADD a platform freely; losing one is the defect, and losing one
silently is the defect that shipped.

The pair -- not just the triple -- is the unit, so losing the `.sha256`
sidecar while keeping the tarball is ALSO a refusal: install.sh treats a
missing sidecar as "verification skipped", which is a silent downgrade from
verified to unverified rather than a 404.  Adding a sidecar (or a platform)
that the predecessor lacked can only ADD pairs, so an improvement never
refuses.

★WHAT IT CANNOT SEE -- READ THIS BEFORE TRUSTING A GREEN
 1. WHETHER THE TARBALL WORKS.  It reads asset names off the API.  Running the
    installer end-to-end on the target OS is what binds published bytes to a
    working `bithuman --version`.
 2. A PLATFORM DROPPED BEFORE THE PREDECESSOR.  It compares to the PREDECESSOR,
    not to an ideal, so a platform lost several releases ago is permanently
    invisible here -- which is why the predecessor's target set is PRINTED,
    always, and why --require may be used to pin a floor.
    ★CORRECTED 2026-09-04.  This paragraph used to say "no `cli-v*` release has
    ever carried either" of `x86_64-apple-darwin` and `aarch64-unknown-linux-gnu`.
    That is FALSE for ARM Linux and the falsehood was load-bearing: it is the
    sentence a reader used to decide the 404 was expected.  Measured by fetching
    every URL, 2026-09-04:
        cli-v2.3.27  bithuman-aarch64-unknown-linux-gnu.tar.gz  200 (40,082,649 B)
        cli-v2.4.2   same name                                  404
        cli-v2.5.0   same name                                  404
        cli-v2.5.1   same name                                  404
    ARM Linux shipped through cli-v2.3.27 and was dropped at cli-v2.4.0, when the
    tarball began vendoring the expression-2 render engine and only an x86_64
    Linux engine was built.  `x86_64-apple-darwin` really has never shipped.
    The customer-visible half is closed in install.sh, which now asks the release
    for its assets and REFUSES by name instead of building a URL that 404s; this
    tool is deliberately NOT made red for it, because a permanent red for
    something nobody has been asked to fix teaches people to ignore the gate.
 3. DRAFTS AND PRE-RELEASES.  A draft release is invisible to an anonymous
    reader and is skipped; a pre-release is included (cli-v2.4.1 is one, and
    it is exactly the "shipped no assets at all" shape this refuses).

SELF-TEST
─────────
`--self-test` runs the arms IN-PROCESS against synthetic indexes.  It never
re-executes this file: a positive control that re-runs itself unmutated is a
fork bomb, and one of those OOM-stormed lafayette on 2026-09-01.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request

REPO = "bithuman-product/homebrew-bithuman"
API = "https://api.github.com/repos/%s/releases?per_page=100"

# The CLI tarball asset name, the ONLY name install.sh ever asks for:
#   bithuman-<arch>-<os>.tar.gz  (+ the optional .sha256 sidecar)
ASSET_RE = re.compile(r"^bithuman-(?P<target>[A-Za-z0-9_]+-[A-Za-z0-9_.-]+)"
                      r"\.tar\.gz(?P<sidecar>\.sha256)?$")

# Tag taxonomy in this repo, copied from install.sh's own resolution rules:
# the CLI publishes under `cli-v*`; the bare `v*` namespace is shared with the
# Swift SDK (xcframework assets); `*-mac` is the Sparkle app feed.  A tag alone
# cannot tell a CLI release from a Swift SDK release -- `v2.5.0` is a Swift SDK
# release with zero tarballs -- so membership of the CLI line is decided by
# CARRYING a bithuman-<target>.tar.gz, not by the tag text.
CLI_TAG_RE = re.compile(r"^(cli-v|v)[0-9]")


class Refusal(Exception):
    """A refusal names BOTH operands."""


def _key(tag: str):
    """Rank tags the way the installer does, with a total order that never
    raises on a non-numeric segment (`cli-v2.4.1-rc1` must not crash the gate
    that guards cli-v2.5.0)."""
    parts = re.findall(r"\d+", tag)
    return ([int(p) for p in parts] + [0, 0, 0])[:4]


def fetch_index(repo: str = REPO, url: str | None = None,
                index_file: str | None = None) -> list:
    if index_file:
        with open(index_file, "r", encoding="utf-8") as fh:
            return json.load(fh)
    req = urllib.request.Request(url or (API % repo),
                                 headers={"Accept": "application/vnd.github+json",
                                          "User-Agent": "bithuman-release-gate"})
    tok = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if tok:
        req.add_header("Authorization", "Bearer %s" % tok)
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode())


def coverage(assets: list) -> set:
    """The (kind, target) pairs a release actually offers a customer."""
    out = set()
    for a in assets or []:
        m = ASSET_RE.match(a.get("name") or "")
        if m:
            out.add(("sha256" if m.group("sidecar") else "tarball",
                     m.group("target")))
    return out


def targets(pairs: set) -> set:
    return {t for kind, t in pairs if kind == "tarball"}


def cli_line(index: list) -> list:
    """Every CLI release in the index, oldest first.  A release is on the CLI
    line iff it carries at least one bithuman-<target>.tar.gz."""
    out = []
    for rel in index or []:
        tag = rel.get("tag_name") or ""
        if rel.get("draft"):
            continue
        if not CLI_TAG_RE.match(tag) or tag.endswith("-mac"):
            continue
        if targets(coverage(rel.get("assets"))):
            out.append(rel)
    return sorted(out, key=lambda r: _key(r["tag_name"]))


def check(index: list, tag: str | None = None, require: set | None = None) -> list:
    by_tag = {r.get("tag_name"): r for r in (index or []) if not r.get("draft")}
    line = cli_line(index)
    if not line:
        raise Refusal("the index carries no CLI release with a "
                      "bithuman-<target>.tar.gz asset at all")
    if tag is None:
        tag = line[-1]["tag_name"]
    if tag not in by_tag:
        raise Refusal("release %r is not in this index -- refusing to guess "
                      "which release is under test" % tag)

    now = coverage(by_tag[tag].get("assets"))
    if not targets(now):
        raise Refusal(
            "%s carries NO bithuman-<target>.tar.gz at all (%d asset(s): %s) "
            "-- `curl … install.sh | sh` 404s on EVERY platform for it"
            % (tag, len(by_tag[tag].get("assets") or []),
               sorted(a.get("name") for a in (by_tag[tag].get("assets") or []))))

    prior = [r for r in line if _key(r["tag_name"]) < _key(tag)]
    if not prior:
        raise Refusal(
            "%s is the FIRST CLI release in this index; there is no "
            "predecessor to compare its platform coverage to, and a gate that "
            "cannot compare must say so rather than pass" % tag)
    previous = prior[-1]["tag_name"]
    before = coverage(by_tag[previous].get("assets"))

    lines = [
        "under test  %-12s %2d asset(s) over %d target(s): %s"
        % (tag, len(now), len(targets(now)), sorted(targets(now))),
        "predecessor %-12s %2d asset(s) over %d target(s): %s"
        % (previous, len(before), len(targets(before)), sorted(targets(before))),
    ]

    lost = sorted(targets(before) - targets(now))
    if lost:
        raise Refusal(
            "%s DROPPED %s -- %s had them. `curl -sSL install.bithuman.ai | sh` "
            "on a lost platform resolves the newest cli-v* tag, finds no "
            "tarball and exits 1 with a 404, which is exactly how cli-v2.5.0 "
            "broke every Linux customer on 2026-09-02."
            % (tag, lost, previous))
    missing = sorted(before - now)
    if missing:
        raise Refusal(
            "%s keeps every target but loses %d asset(s) %s that %s had -- a "
            "dropped .sha256 sidecar silently downgrades install.sh from "
            "verified to 'verification skipped'"
            % (tag, len(missing), missing, previous))
    if require:
        short = sorted(set(require) - targets(now))
        if short:
            raise Refusal("%s is missing REQUIRED target(s) %s (it carries %s)"
                          % (tag, short, sorted(targets(now))))
        lines.append("required    %s: all present" % sorted(require))
    return lines


def verify(repo: str, tag: str | None, url: str | None, index_file: str | None,
           require: set | None, quiet: bool) -> int:
    try:
        index = fetch_index(repo, url, index_file)
    except Exception as exc:                                   # noqa: BLE001
        # ★UNREACHABLE IS NOT GREEN. A network failure that returns 0 is a gate
        # an outage disarms.
        print("::error::REFUSED -- could not read the releases index for %r: %s"
              % (repo, exc), file=sys.stderr)
        return 2
    try:
        lines = check(index, tag, require)
    except Refusal as exc:
        print("::error::REFUSED -- %s" % exc, file=sys.stderr)
        return 1
    if not quiet:
        for line in lines:
            print("  ok  " + line)
        print("GREEN -- the release under test carries every platform its "
              "predecessor did.")
    return 0


# ── SELF-TEST: THE ARMS MUST GO RED ──────────────────────────────────────────
MAC = "aarch64-apple-darwin"
LIN = "x86_64-unknown-linux-gnu"
ARM = "aarch64-unknown-linux-gnu"


def _rel(tag, tgts, sidecars=True, extra=()):
    assets = []
    for t in tgts:
        assets.append({"name": "bithuman-%s.tar.gz" % t})
        if sidecars:
            assets.append({"name": "bithuman-%s.tar.gz.sha256" % t})
    assets += [{"name": n} for n in extra]
    return {"tag_name": tag, "draft": False, "assets": assets}


def self_test() -> int:
    fails = []

    def arm(name, fn):
        try:
            fn()
        except Refusal as exc:
            print("  RED (as demanded)  %-46s %s" % (name, str(exc)[:88]))
            return
        print("  ★GREEN AND IT MUST NOT BE  %s" % name)
        fails.append(name)

    def green(name, fn):
        try:
            fn()
            print("  GREEN (as demanded)  %s" % name)
        except Refusal as exc:
            print("  ★RED AND IT MUST NOT BE  %s: %s" % (name, exc))
            fails.append(name)

    # POSITIVE CONTROL: equal coverage in both releases must pass, or every RED
    # below means only that this refuses everything.
    ok = [_rel("cli-v2.4.2", [MAC, LIN]), _rel("cli-v2.5.0", [MAC, LIN])]
    try:
        for line in check(ok, "cli-v2.5.0"):
            print("     " + line)
        print("  GREEN (positive control: unmutated index passes)")
    except Refusal as exc:
        print("  ★RED ON THE UNMUTATED INDEX -- the guard is broken: %s" % exc)
        fails.append("positive-control")

    # ★THE ARM THAT IS THE ACTUAL DEFECT, in the actual shape it shipped.
    arm("★the real cli-v2.5.0: macOS only, predecessor had Linux too",
        lambda: check([_rel("cli-v2.4.2", [MAC, LIN]),
                       _rel("cli-v2.5.0", [MAC])], "cli-v2.5.0"))
    arm("the release carries no tarball at all (cli-v2.4.1's shape)",
        lambda: check([_rel("cli-v2.4.0", [MAC, LIN]),
                       {"tag_name": "cli-v2.4.1", "draft": False, "assets": []}],
                      "cli-v2.4.1"))
    arm("tarball kept, .sha256 sidecar lost",
        lambda: check([_rel("cli-v2.4.2", [MAC, LIN]),
                       _rel("cli-v2.5.0", [MAC, LIN], sidecars=False)],
                      "cli-v2.5.0"))
    arm("one arch lost (linux aarch64 dropped)",
        lambda: check([_rel("cli-v2.3.27", [MAC, LIN, ARM]),
                       _rel("cli-v2.4.0", [MAC, LIN])], "cli-v2.4.0"))
    arm("there is no predecessor to compare to",
        lambda: check([_rel("cli-v2.5.0", [MAC, LIN])], "cli-v2.5.0"))
    arm("the index carries no CLI release at all (Swift SDK tags only)",
        lambda: check([{"tag_name": "v2.5.0", "draft": False,
                        "assets": [{"name": "Expression2.xcframework.zip"}]}],
                      "v2.5.0"))
    arm("the tag under test is not in the index",
        lambda: check([_rel("cli-v2.4.2", [MAC, LIN])], "cli-v2.9.9"))
    arm("--require names a target the release does not carry",
        lambda: check([_rel("cli-v2.4.2", [MAC, LIN]),
                       _rel("cli-v2.5.0", [MAC, LIN])], "cli-v2.5.0",
                      require={MAC, LIN, ARM}))
    # A DRAFT predecessor must not be trusted as the comparison point: an
    # anonymous installer cannot download from a draft, so a gate that read one
    # would compare against assets no customer can reach.
    arm("the only predecessor is a DRAFT (invisible to a customer)",
        lambda: check([dict(_rel("cli-v2.4.2", [MAC, LIN]), draft=True),
                       _rel("cli-v2.5.0", [MAC, LIN])], "cli-v2.5.0"))

    # OPPOSITE-DIRECTION CONTROLS -- a gate that blocks progress gets deleted.
    green("a release that ADDS a platform passes",
          lambda: check([_rel("cli-v2.4.2", [MAC]),
                         _rel("cli-v2.5.0", [MAC, LIN, ARM])], "cli-v2.5.0"))
    green("a release that ADDS a .sha256 sidecar passes",
          lambda: check([_rel("v2.3.21", [MAC, LIN], sidecars=False),
                         _rel("v2.3.22", [MAC, LIN])], "v2.3.22"))
    green("a Swift SDK release between two CLI releases is not the predecessor",
          lambda: check([_rel("cli-v2.4.2", [MAC, LIN]),
                         {"tag_name": "v2.4.9", "draft": False,
                          "assets": [{"name": "bitHumanKit.xcframework.zip"}]},
                         _rel("cli-v2.5.0", [MAC, LIN])], "cli-v2.5.0"))

    if fails:
        print("\n★SELF-TEST FAILED: %d arm(s) did not behave: %s"
              % (len(fails), fails))
        return 1
    print("\nself-test OK -- the positive control passes, every loss is "
          "refused by name, and a gained platform is not.")
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--repo", default=REPO)
    ap.add_argument("--tag", default=None,
                    help="release under test (default: newest CLI release)")
    ap.add_argument("--require", default=None,
                    help="comma-separated target triples that MUST be present, "
                         "independent of the predecessor")
    ap.add_argument("--url", default=None,
                    help="read the index from here instead of the GitHub API")
    ap.add_argument("--index-file", default=None,
                    help="read the index from a local JSON file (testing)")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--self-test", action="store_true",
                    help="run the refusal arms in-process (no re-exec)")
    a = ap.parse_args(argv)
    if a.self_test:
        return self_test()
    req = {t.strip() for t in a.require.split(",") if t.strip()} if a.require else None
    return verify(a.repo, a.tag, a.url, a.index_file, req, a.quiet)


if __name__ == "__main__":
    sys.exit(main())
