#!/usr/bin/env python3
"""check-explicit-tap.py -- the Homebrew tap is ALWAYS tapped with its URL.

THE RISK THIS REFUSES (2026-10, the move to GitLab). The tap is named `bithuman/bithuman`. Homebrew
resolves a tap name it has not seen to GitHub: `brew tap bithuman/bithuman` with no URL, or
`brew install bithuman/bithuman/bithuman-cli` on a machine that has not tapped it, clones
`github.com/bithuman/homebrew-bithuman`. `github.com/bithuman` is an UNRELATED account. Today that
repository does not exist (404), but whoever controls that account can create it at any time, and
every shortened command would then install their formula. AI assistants that shorten commands from
llms.txt are a likely way this happens. So every line in this repository that taps or installs
from the tap carries the URL, and the installer script stays the primary install.

RULES (offline; every tracked text file except this one)
  R1 TAP-URL      `brew tap bithuman/bithuman` is followed by the GitLab URL (or `./` for a local
                  checkout) on the same line.
  R2 NO-SHORT     `brew install bithuman/bithuman/<formula>` appears only after an explicit tap
                  (`brew tap bithuman/bithuman <URL>` or `./`) earlier on the same line or on one
                  of the 3 lines before it (a code block that taps first), or in a warning that
                  says not to shorten it (the line, or the line before, says "shorten").
  R3 NO-OLD-TAP   no `brew tap bithuman-product/bithuman` (the pre-move GitHub tap) except in an
                  untap/migration line (`untap` or `--custom-remote` on the same line).
  R4 NO-MIGRATION no tap_migrations.json: a migration names a tap by its short name, which is
                  exactly the shortened form R1/R2 refuse.

  --live          also check that github.com/bithuman/homebrew-bithuman still answers 404 (a
                  plain HTTPS request, no API, no token). A 200 means someone created the
                  squattable tap: tell the maintainers at once.
  --selftest      plant one regression per rule and require each to be refused.

Exit: 0 PASS, 1 REFUSE, 2 could not run.
Apache-2.0; (c) bitHuman.
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

TAP_URL = "https://gitlab.com/bithuman/sdk/homebrew-bithuman"
SQUAT_URL = "https://github.com/bithuman/homebrew-bithuman"
SELF = "scripts/check-explicit-tap.py"

RX_TAP = re.compile(r"brew tap bithuman/bithuman(?![\w/-])(?P<rest>[^\n]*)")
RX_INSTALL = re.compile(r"brew (?:install|reinstall|upgrade|info|fetch|audit)\b[^\n`]*?(?<![\w-])bithuman/bithuman/[\w@.-]+")
RX_OLD_TAP = re.compile(r"brew tap bithuman-product/bithuman(?![\w/-])")


def grade_lines(name: str, lines: list[str]) -> list[str]:
    out = []
    for i, line in enumerate(lines):
        n = i + 1
        for m in RX_TAP.finditer(line):
            rest = m.group("rest").lstrip()
            if not (rest.startswith(TAP_URL) or rest.startswith("./")):
                out.append(f"R1 {name}:{n}: `brew tap bithuman/bithuman` without its URL ({TAP_URL})")
        for m in RX_INSTALL.finditer(line):
            before = line[:m.start()]
            window = lines[max(0, i - 3):i] + [before]
            tapped = any(f"brew tap bithuman/bithuman {TAP_URL}" in w or "brew tap bithuman/bithuman ./" in w
                         for w in window)
            warned = "shorten" in line.lower() or (i > 0 and "shorten" in lines[i - 1].lower())
            if not (tapped or warned):
                out.append(f"R2 {name}:{n}: shortened `{m.group(0)}` with no explicit tap first")
        for m in RX_OLD_TAP.finditer(line):
            if "untap" not in line and "--custom-remote" not in line:
                out.append(f"R3 {name}:{n}: the pre-move tap `brew tap bithuman-product/bithuman`")
    return out


def tracked_files(root: str) -> list[str]:
    r = subprocess.run(["git", "-C", root, "ls-files", "-z"], capture_output=True)
    if r.returncode != 0:
        raise SystemExit(2)
    return [p for p in r.stdout.decode().split("\0") if p]


def grade_tree(root: str) -> list[str]:
    problems = []
    files = tracked_files(root)
    if any(os.path.basename(p) == "tap_migrations.json" for p in files):
        problems.append("R4 tap_migrations.json is tracked: a tap migration names the short (squattable) tap")
    for rel in files:
        if rel == SELF:
            continue
        path = os.path.join(root, rel)
        try:
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
        except (UnicodeDecodeError, IsADirectoryError, FileNotFoundError):
            continue
        if "bithuman/bithuman" not in text and "bithuman-product/bithuman" not in text:
            continue
        problems += grade_lines(rel, text.split("\n"))
    return problems


def live() -> list[str]:
    req = urllib.request.Request(SQUAT_URL, method="HEAD", headers={"User-Agent": "check-explicit-tap"})
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            code = resp.status
    except urllib.error.HTTPError as e:
        code = e.code
    except Exception as e:  # noqa: BLE001 - network trouble is "could not run", never a pass
        print(f"could not reach {SQUAT_URL}: {e}", file=sys.stderr)
        raise SystemExit(2)
    if code == 404:
        print(f"ok      live: {SQUAT_URL} answers 404 (nobody holds the squattable tap)")
        return []
    return [f"LIVE {SQUAT_URL} answers HTTP {code}: a tap with our short name EXISTS on an account "
            "bitHuman does not control. Tell the maintainers now; every shortened brew command installs it."]


def selftest() -> int:
    good = [
        f"brew tap bithuman/bithuman {TAP_URL}",
        f"brew tap bithuman/bithuman {TAP_URL} && brew install bithuman/bithuman/bithuman-cli",
        "brew tap bithuman/bithuman ./",
        "brew audit --strict bithuman/bithuman/bithuman-cli",
        "Never shorten it to `brew install bithuman/bithuman/bithuman-cli` before tapping.",
        "  brew untap bithuman-product/bithuman",
        "brew install bithuman-cli",
    ]
    cases = [
        ("R1", ["brew tap bithuman/bithuman"]),
        ("R1", ["brew tap bithuman/bithuman https://github.com/bithuman/homebrew-bithuman"]),
        ("R2", ["Install: `brew install bithuman/bithuman/bithuman-cli`"]),
        ("R2", ["brew tap bithuman/bithuman", "", "", "", "brew install bithuman/bithuman/bithuman-cli"]),
        ("R3", ["brew tap bithuman-product/bithuman"]),
    ]
    fail = 0
    base = grade_lines("good", good)
    if base:
        print("SELFTEST FAIL: the good lines were refused:\n  " + "\n  ".join(base))
        fail = 1
    for rule, lines in cases:
        got = grade_lines("planted", lines)
        if not any(p.startswith(rule) for p in got):
            print(f"SELFTEST FAIL: {rule} did not refuse {lines!r}")
            fail = 1
        else:
            print(f"control fires: {rule} refuses {lines[0]!r}")
    print("SELFTEST " + ("FAIL" if fail else f"PASS ({len(cases)} planted regressions refused, {len(good)} good lines pass)"))
    return fail


def main(argv: list[str]) -> int:
    args = [a for a in argv if not a.startswith("--")]
    if "--selftest" in argv:
        return selftest()
    root = os.path.abspath(args[0] if args else os.path.join(os.path.dirname(__file__), ".."))
    problems = grade_tree(root)
    if "--live" in argv:
        problems += live()
    for p in problems:
        print("REFUSE  " + p)
    if problems:
        print(f"\n{len(problems)} problem(s). Tap with the URL: brew tap bithuman/bithuman {TAP_URL}")
        return 1
    print(f"PASS — every tap/install line names the tap's URL ({TAP_URL}); no shortened form, no migration.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
