#!/usr/bin/env python3
"""downloads-publish.py -- this repository's `gh release` replacement: releases live on
https://downloads.bithuman.ai, and nothing is published to GitHub any more.

LAYOUT (fixed; every client relies on it, so a client change is a URL swap):
    https://downloads.bithuman.ai/<repo>/<tag>/<asset>
    https://downloads.bithuman.ai/<repo>/releases.json   array, the shape of GitHub's
                                                         GET /repos/:o/:r/releases
    https://downloads.bithuman.ai/<repo>/latest.json     one release, the shape of /releases/latest
<repo> is the repository's old GitHub name (here `homebrew-bithuman`). The index is edge-cached
for up to 300 s; assets are immutable and cached for a year.

WRITES go through the canonical downloads publisher, `dlhost.py` (owned with the downloads host;
it keeps one manifest per tag, derives releases.json / latest.json from them, verifies every
upload, and refuses different bytes under a published name). This wrapper finds it at
$BITHUMAN_DLHOST, else next to this file (scripts/dlhost.py). READS are anonymous, from the public
index, so they need no credential and see exactly what a customer sees.

THE RULES THIS REPOSITORY ADDS
  * Only a `cli-vX.Y.Z` release may be latest.json (installers and the CLI's update notice read
    it). `publish` defaults to --latest auto for cli-v* tags and --latest false for every other
    family (Swift SDK `v*`, `essence2-v*`, `flutter-plugin-vendor-v*`, engine assets...).
  * There are no drafts (the bucket is public). A release is assembled LOCALLY and graded before
    it exists anywhere:  `stage` writes the would-be manifest, scripts/check-release-atomic.sh
    grades it with --manifest/--assets/--verify-bytes, and ONE `publish` call uploads every asset
    (the release appears in the index only after all of them are verified, so it is atomic by
    construction). Publishing a CLI release in two calls is refused by check-release-atomic.sh C5.
  * Assets are write-once. To change bytes, cut a new tag (and re-pin every sha256 naming it).

COMMANDS
  list [--json]                                  gh release list
  view TAG [--json]                              gh release view TAG --json ...
  download TAG [-p GLOB]... [-D DIR] [--clobber] gh release download
  stage TAG FILE...                              print the manifest a publish would create
  publish TAG FILE... [--title T] [--notes-file F] [--prerelease] [--latest auto|true|false]
                                                 gh release create/upload (via dlhost.py)
  set-latest TAG                                 point latest.json at a cli-v* release
  reindex                                        rebuild releases.json / latest.json
  --self-test                                    offline arms (a file:// index, a fake publisher)

--base (default $BITHUMAN_DOWNLOADS_BASE or https://downloads.bithuman.ai) points reads at another
copy, e.g. a local test server. Secrets (bucket key) are dlhost.py's business: environment, ~/.env
or $DOWNLOADS_BUCKET_KEY_FILE, never argv, never printed.
EXIT  0 ok; 1 refused; 2 could not run.
"""
from __future__ import annotations

import argparse
import datetime as _dt
import fnmatch
import json
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request

REPO = "homebrew-bithuman"
UA = "bithuman-downloads-publish/2"
HERE = os.path.dirname(os.path.abspath(__file__))


class Refusal(Exception):
    """exit 1"""


class CannotRun(Exception):
    """exit 2"""


def default_base() -> str:
    return os.environ.get("BITHUMAN_DOWNLOADS_BASE", "https://downloads.bithuman.ai").rstrip("/")


def now() -> str:
    return _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ── reads (anonymous) ────────────────────────────────────────────────────────
def fetch(url: str, timeout: int = 60) -> bytes:
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": UA}), timeout=timeout) as r:
            return r.read()
    except Exception as e:  # noqa: BLE001
        raise CannotRun("could not read %s: %s" % (url, e)) from None


def asset_url(base: str, repo: str, tag: str, name: str) -> str:
    return "%s/%s/%s/%s" % (base, repo, urllib.parse.quote(tag, safe=""), urllib.parse.quote(name, safe=""))


def read_index(a) -> list:
    data = json.loads(fetch("%s/%s/releases.json" % (a.base, a.repo)))
    if not isinstance(data, list):
        raise CannotRun("%s/releases.json is not a JSON array" % a.repo)
    return data


def find(index: list, tag: str) -> dict:
    rel = next((r for r in index if r.get("tag_name") == tag), None)
    if rel is None:
        raise Refusal("release %s is not in %s/releases.json" % (tag, REPO))
    return rel


def cmd_list(a) -> int:
    index = read_index(a)
    if a.json:
        print(json.dumps(index, indent=2))
        return 0
    for r in index:
        state = "draft" if r.get("draft") else ("pre" if r.get("prerelease") else "")
        print("%-40s %-6s %s  %d asset(s)" % (r["tag_name"], state, r.get("published_at") or "-",
                                             len(r.get("assets") or [])))
    return 0


def cmd_view(a) -> int:
    rel = find(read_index(a), a.tag)
    if a.json:
        print(json.dumps(rel, indent=2))
        return 0
    print("%s  %s  prerelease=%s published=%s" % (rel["tag_name"], rel.get("name"), rel.get("prerelease"),
                                                rel.get("published_at")))
    for x in rel.get("assets") or []:
        print("  %-60s %12d  %s" % (x["name"], x["size"], x.get("updated_at") or ""))
    return 0


def cmd_download(a) -> int:
    rel = find(read_index(a), a.tag)
    pats = a.pattern or ["*"]
    names = [x["name"] for x in rel.get("assets") or [] if any(fnmatch.fnmatch(x["name"], p) for p in pats)]
    if not names:
        raise Refusal("release %s has no asset matching %s" % (a.tag, pats))
    os.makedirs(a.dir, exist_ok=True)
    for n in names:
        dst = os.path.join(a.dir, n)
        if os.path.exists(dst) and not a.clobber:
            raise Refusal("%s exists (pass --clobber)" % dst)
        url = asset_url(a.base, a.repo, a.tag, n)
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": UA}), timeout=900) as r, \
                    open(dst + ".part", "wb") as fh:
                shutil.copyfileobj(r, fh, 1 << 20)
        except Exception as e:  # noqa: BLE001
            raise CannotRun("download of %s failed: %s" % (url, e)) from None
        os.replace(dst + ".part", dst)
        print("  got  %s" % dst)
    return 0


def cmd_stage(a) -> int:
    """The manifest `publish` would create, for check-release-atomic.sh --manifest (graded
    BEFORE anything is uploaded). draft=true marks it as not yet visible."""
    t = now()
    assets = []
    for f in a.files:
        if not os.path.isfile(f):
            raise Refusal("no such file: %s" % f)
        n = os.path.basename(f)
        assets.append({"name": n, "size": os.path.getsize(f), "created_at": t, "updated_at": t,
                       "browser_download_url": asset_url(a.base, a.repo, a.tag, n)})
    print(json.dumps({"tag_name": a.tag, "name": a.title or a.tag, "draft": True, "prerelease": bool(a.prerelease),
                      "created_at": t, "published_at": None, "body": "", "assets": assets}, indent=2))
    return 0


# ── writes (the canonical publisher) ─────────────────────────────────────────
def dlhost() -> list:
    path = os.environ.get("BITHUMAN_DLHOST") or os.path.join(HERE, "dlhost.py")
    if not os.path.isfile(path):
        raise CannotRun("the downloads publisher dlhost.py was not found (set BITHUMAN_DLHOST, or place it "
                        "at scripts/dlhost.py); this wrapper never writes the bucket itself")
    return [sys.executable, path]


def run_dlhost(args: list) -> int:
    rc = subprocess.call(dlhost() + args)
    if rc == 0:
        return 0
    if rc == 2:          # dlhost.py: refused
        return 1
    return 2


def cmd_publish(a) -> int:
    latest = a.latest or ("auto" if a.tag.startswith("cli-v") else "false")
    if latest != "false" and not a.tag.startswith("cli-v"):
        raise Refusal("only a cli-v* release may be latest.json in %s (got --latest %s for %s)" % (a.repo, latest, a.tag))
    args = ["publish", "--repo", a.repo, "--tag", a.tag, "--latest", latest]
    if a.title:
        args += ["--title", a.title]
    if a.notes_file:
        args += ["--notes-file", a.notes_file]
    if a.prerelease:
        args += ["--prerelease"]
    if a.dry_run:
        args += ["--dry-run"]
    return run_dlhost(args + list(a.files))


def cmd_set_latest(a) -> int:
    if not a.tag.startswith("cli-v"):
        raise Refusal("only a cli-v* release may be latest.json in %s" % a.repo)
    return run_dlhost(["set-latest", "--repo", a.repo, "--tag", a.tag])


def cmd_reindex(a) -> int:
    return run_dlhost(["reindex", "--repo", a.repo])


# ── self-test ────────────────────────────────────────────────────────────────
def self_test() -> int:
    ran, bad = [], []

    def arm(label, cond):
        ran.append(label)
        print("  %s  %s" % ("PASS" if cond else "FAIL", label))
        if not cond:
            bad.append(label)

    with tempfile.TemporaryDirectory() as d:
        root = os.path.join(d, "host")
        rel_dir = os.path.join(root, REPO, "cli-v1.0.0")
        os.makedirs(rel_dir)
        open(os.path.join(rel_dir, "bithuman-x.tar.gz"), "wb").write(b"bytes")
        open(os.path.join(rel_dir, "bithuman-x.tar.gz.sha256"), "wb").write(b"0" * 64 + b"  bithuman-x.tar.gz\n")
        base = "file://" + root
        index = [{"tag_name": "cli-v1.0.0", "name": "CLI 1.0.0", "draft": False, "prerelease": False,
                  "created_at": "2026-10-04T00:00:00Z", "published_at": "2026-10-04T00:00:00Z", "body": "",
                  "assets": [{"name": n, "size": 1, "browser_download_url": asset_url(base, REPO, "cli-v1.0.0", n)}
                             for n in ("bithuman-x.tar.gz", "bithuman-x.tar.gz.sha256")]}]
        json.dump(index, open(os.path.join(root, REPO, "releases.json"), "w"))
        log = os.path.join(d, "argv.json")
        fake = os.path.join(d, "dlhost.py")
        open(fake, "w").write("import json,sys\njson.dump(sys.argv[1:], open(%r,'w'))\n"
                              "sys.exit(2 if 'refuse-me' in sys.argv else 0)\n" % log)
        os.environ["BITHUMAN_DLHOST"] = fake
        quiet = open(os.devnull, "w")

        def run(argv):
            out, err, sys.stdout, sys.stderr = sys.stdout, sys.stderr, quiet, quiet
            try:
                return main(["--base", base] + argv)
            finally:
                sys.stdout, sys.stderr = out, err

        def argv():
            return json.load(open(log)) if os.path.exists(log) else None

        dl = os.path.join(d, "dl")
        arm("download by pattern from the public index", run(["download", "cli-v1.0.0", "-p", "*.sha256", "-D", dl]) == 0
            and os.listdir(dl) == ["bithuman-x.tar.gz.sha256"])
        arm("view of a tag that is not published is refused", run(["view", "cli-v9.9.9"]) == 1)
        f = os.path.join(rel_dir, "bithuman-x.tar.gz")
        stage_out = os.path.join(d, "stage.json")
        out, sys.stdout = sys.stdout, open(stage_out, "w")
        try:
            rc = main(["--base", base, "stage", "cli-v2.0.0", f])
        finally:
            sys.stdout.close(); sys.stdout = out
        st = json.load(open(stage_out))
        arm("stage writes a draft manifest with real sizes", rc == 0 and st["draft"] is True
            and st["assets"][0]["size"] == 5 and st["published_at"] is None)
        arm("publish of a cli-v* tag defaults to --latest auto", run(["publish", "cli-v2.0.0", f]) == 0
            and argv()[:7] == ["publish", "--repo", REPO, "--tag", "cli-v2.0.0", "--latest", "auto"])
        arm("★publish of any other family defaults to --latest false", run(["publish", "essence2-v9.0.0", f]) == 0
            and argv()[5:7] == ["--latest", "false"])
        os.remove(log)
        arm("★--latest true on a non-CLI tag is refused before the publisher runs",
            run(["publish", "flutter-plugin-vendor-v2", f, "--latest", "true"]) == 1 and argv() is None)
        arm("★set-latest refuses a non-CLI tag", run(["set-latest", "v2.20.3"]) == 1 and argv() is None)
        arm("set-latest of a CLI tag reaches the publisher", run(["set-latest", "cli-v2.0.0"]) == 0
            and argv() == ["set-latest", "--repo", REPO, "--tag", "cli-v2.0.0"])
        arm("a publisher refusal (its exit 2) is exit 1 here", run(["publish", "cli-v2.0.1", f, "--title", "refuse-me"]) == 1)
        os.environ["BITHUMAN_DLHOST"] = os.path.join(d, "absent.py")
        arm("★no publisher -> could not run (2), never a silent success", run(["reindex"]) == 2)
        quiet.close()
    want = 10
    if len(ran) != want or bad:
        print("SELF-TEST FAILED: %d/%d arms ran, failed: %s" % (len(ran), want, bad))
        return 1
    print("SELF-TEST PASSED: %d/%d arms" % (len(ran), want))
    return 0


# ── cli ──────────────────────────────────────────────────────────────────────
def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(prog="downloads-publish.py", description=__doc__.splitlines()[0])
    ap.add_argument("--repo", default=REPO)
    ap.add_argument("--base", default=None)
    ap.add_argument("--self-test", action="store_true")
    sub = ap.add_subparsers(dest="cmd")
    p = sub.add_parser("list"); p.add_argument("--json", action="store_true")
    p = sub.add_parser("view"); p.add_argument("tag"); p.add_argument("--json", action="store_true")
    p = sub.add_parser("download"); p.add_argument("tag"); p.add_argument("-p", "--pattern", action="append")
    p.add_argument("-D", "--dir", default="."); p.add_argument("--clobber", action="store_true")
    p = sub.add_parser("stage"); p.add_argument("tag"); p.add_argument("files", nargs="+")
    p.add_argument("--title"); p.add_argument("--prerelease", action="store_true")
    p = sub.add_parser("publish"); p.add_argument("tag"); p.add_argument("files", nargs="+")
    p.add_argument("--title"); p.add_argument("--notes-file"); p.add_argument("--prerelease", action="store_true")
    p.add_argument("--latest", choices=("auto", "true", "false")); p.add_argument("--dry-run", action="store_true")
    p = sub.add_parser("set-latest"); p.add_argument("tag")
    sub.add_parser("reindex")
    return ap


COMMANDS = {"list": cmd_list, "view": cmd_view, "download": cmd_download, "stage": cmd_stage,
            "publish": cmd_publish, "set-latest": cmd_set_latest, "reindex": cmd_reindex}


def main(argv=None) -> int:
    ap = build_parser()
    a = ap.parse_args(argv)
    if a.self_test:
        return self_test()
    if not a.cmd:
        ap.print_help()
        return 2
    a.base = (a.base or default_base()).rstrip("/")
    try:
        return COMMANDS[a.cmd](a)
    except Refusal as e:
        print("REFUSED: %s" % e, file=sys.stderr)
        return 1
    except CannotRun as e:
        print("CANNOT RUN: %s" % e, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
