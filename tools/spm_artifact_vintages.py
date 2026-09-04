#!/usr/bin/env python3
"""spm_artifact_vintages — WHEN was each binary the SwiftPM tag resolves actually
BUILT?

★ WHY THIS EXISTS. `Package.swift` at tag `v2.5.0` declares three binaryTargets
and pins a sha256 for each. All three checksums are CORRECT. That is the whole
problem: a checksum says the bytes you got are the bytes that were pinned, and
says nothing about WHEN — or from what — those bytes were made. `check-manifest-
truth.py` verifies exactly that (R1) and is green.

MEASURED 2026-09-04 by reading the mtimes stored inside each zip's central
directory — the clock of the machine that built it, which travels with the
archive and survives re-uploading, re-tagging and renaming:

    bitHumanKit.xcframework.zip              105 entries   2026-04-28 13:42-13:49
    Expression2.xcframework.zip               38 entries   2026-08-29 08:47:18
    BithumanEngineProtocol.xcframework.zip    38 entries   2026-08-29 08:47:18

So the tag resolves THREE artifacts of TWO vintages, 123 days apart — and the
two August ones agree TO THE SECOND, i.e. they really are one build. It is
`bitHumanKit` that is old, and it is older than its own release: it was uploaded
to the `v2.4.0` release on 2026-06-30, but BUILT on 2026-04-28. An upload date
would have understated the gap by two months.

★ THIS TOOL REPORTS; IT DOES NOT REFUSE. The split is DELIBERATE and
`Package.swift` carries the measurement for it: `releaseBase` is shared by every
binaryTarget, so bumping `releaseTag` from v2.4.0 to v2.5.0 re-points
bitHumanKit at a tag that does not carry it — measured, both URLs HTTP 404. A
second constant (`expression2Base`) is what keeps the shipping product alive. So
the vintage spread is a consequence of a correct fix, not a bug to redden main
over. What is NOT acceptable is nobody being able to SEE it, and that is what
this closes.

★ WHAT WOULD ACTUALLY CLOSE IT: one release carrying all three zips, built from
one commit, with every binaryTarget pointed at that one tag. That needs an Apple
build of bitHumanKit — it cannot be produced on the Linux host this estate builds
from, and re-uploading the April bytes under a new tag would change the tag, not
the vintage.

Usage:
    spm_artifact_vintages.py [--manifest Package.swift]
    spm_artifact_vintages.py --self-test
"""
from __future__ import annotations

import argparse
import datetime
import io
import re
import sys
import urllib.request
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_MANIFEST = HERE.parent / "Package.swift"


def targets(manifest_text: str) -> list[tuple[str, str, str]]:
    """[(target name, url, checksum)] with the two base constants substituted."""
    consts = dict(re.findall(r'let\s+(\w+)\s*=\s*"([^"]*)"', manifest_text))
    def expand(u: str) -> str:
        def sub(m):
            return consts.get(m.group(1), m.group(0))
        prev = None
        while prev != u:
            prev = u
            u = re.sub(r"\\\((\w+)\)", sub, u)
        return u
    out = []
    for blk in re.findall(r"\.binaryTarget\((.*?)\)\s*,", manifest_text, re.S):
        n = re.search(r'name:\s*"([^"]+)"', blk)
        u = re.search(r'url:\s*"([^"]+)"', blk)
        c = re.search(r'checksum:\s*"([0-9a-f]{64})"', blk)
        if n and u and c:
            out.append((n.group(1), expand(u.group(1)), c.group(1)))
    return out


def vintage(blob: bytes) -> tuple[int, datetime.datetime, datetime.datetime]:
    z = zipfile.ZipFile(io.BytesIO(blob))
    ts = [datetime.datetime(*i.date_time) for i in z.infolist()]
    if not ts:
        raise ValueError("no entries")
    return len(ts), min(ts), max(ts)


def self_test() -> int:
    """The reader must SEE a difference when there is one, and agree when there
    is not. Two zips built a known interval apart, graded in-process."""
    fails = []

    def mk(when: tuple) -> bytes:
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as z:
            for n in ("a.txt", "b.txt"):
                zi = zipfile.ZipInfo(n, date_time=when)
                z.writestr(zi, b"x")
        return buf.getvalue()

    n, lo, hi = vintage(mk((2026, 4, 28, 13, 42, 16)))
    if not (n == 2 and lo == hi == datetime.datetime(2026, 4, 28, 13, 42, 16)):
        fails.append("reads a single clock")
    a = vintage(mk((2026, 4, 28, 13, 42, 16)))[2]
    b = vintage(mk((2026, 8, 29, 8, 47, 18)))[2]
    # ★ 122, not 123, and the difference is the point: timedelta.days TRUNCATES.
    # 2026-04-28 13:42:16 -> 2026-08-29 08:47:18 is 122 days and 19 hours, while
    # the two CALENDAR DATES are 123 apart. main() reports the calendar figure
    # (date.fromisoformat), which is the honest one for "how many days old is
    # this artifact"; this arm exercises the datetime path and pins its answer so
    # the two can never silently disagree. The first draft asserted 123 here and
    # failed — which is the arm doing its job on its own author.
    days = (b - a).days
    cal = (b.date() - a.date()).days
    print(f"  arm 1  a single-clock zip reads back exactly     -> "
          f"{'PASS' if 'reads a single clock' not in fails else 'FAIL'}")
    print(f"  arm 2  the same two clocks: {days} datetime-days / {cal} calendar-days -> "
          f"{'PASS' if (days, cal) == (122, 123) else f'FAIL ({days},{cal})'}")
    if (days, cal) != (122, 123):
        fails.append("interval")
    same = vintage(mk((2026, 8, 29, 8, 47, 18)))[2] == b
    print(f"  arm 3  control: two zips built at the SAME clock agree -> "
          f"{'PASS' if same else 'FAIL'}")
    if not same:
        fails.append("control")
    # the manifest parser must resolve BOTH base constants
    txt = ('let releaseTag = "vA"\nlet releaseBase = "http://x/\\(releaseTag)"\n'
           'let e2Tag = "vB"\nlet e2Base = "http://x/\\(e2Tag)"\n'
           '.binaryTarget(name: "one", url: "\\(releaseBase)/one.zip", checksum: "%s"),\n'
           '.binaryTarget(name: "two", url: "\\(e2Base)/two.zip", checksum: "%s"),\n'
           % ("a" * 64, "b" * 64))
    got = targets(txt)
    ok = got == [("one", "http://x/vA/one.zip", "a" * 64),
                 ("two", "http://x/vB/two.zip", "b" * 64)]
    print(f"  arm 4  the parser expands BOTH base constants    -> {'PASS' if ok else 'FAIL'}")
    if not ok:
        fails.append("parser")
        print("        got:", got)
    if fails:
        print("SELF-TEST FAILED:", ", ".join(fails))
        return 1
    print("SELF-TEST PASSED")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", default=str(DEFAULT_MANIFEST))
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()
    if a.self_test:
        return self_test()

    text = Path(a.manifest).read_text()
    rows = targets(text)
    if not rows:
        print("INSTRUMENT: no binaryTarget parsed out of the manifest — a reader "
              "that finds nothing must not report green.", file=sys.stderr)
        return 2
    print(f"{len(rows)} binaryTarget(s) in {a.manifest}\n")
    seen: dict[str, list[str]] = {}
    import hashlib
    for name, url, want in rows:
        try:
            blob = urllib.request.urlopen(url, timeout=900).read()
        except Exception as e:
            print(f"  {name:34s} UNREADABLE {type(e).__name__} {url}")
            return 2
        got = hashlib.sha256(blob).hexdigest()
        n, lo, hi = vintage(blob)
        span = "" if lo == hi else f" .. {hi:%H:%M:%S}"
        print(f"  {name:34s} {n:5d} entries   built {lo:%Y-%m-%d %H:%M:%S}{span}"
              f"   checksum {'MATCHES' if got == want else '★MISMATCH'}")
        seen.setdefault(f"{lo:%Y-%m-%d}", []).append(name)
    print()
    if len(seen) == 1:
        print(f"ONE VINTAGE: every artifact was built on {next(iter(seen))}.")
    else:
        days = sorted(seen)
        d0 = datetime.date.fromisoformat(days[0])
        d1 = datetime.date.fromisoformat(days[-1])
        print(f"★ {len(rows)} artifacts, {len(seen)} VINTAGES, {(d1 - d0).days} days apart:")
        for d in days:
            print(f"    {d}  {', '.join(seen[d])}")
        print("  Every checksum above is CORRECT. A checksum binds bytes to a pin;")
        print("  it says nothing about when, or from what, those bytes were made.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
