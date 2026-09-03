#!/usr/bin/env python3
"""
check-manifest-truth.py — hold Package.swift's PROSE to what the SHIPPED
BINARIES and the `products:` list actually say.

Why this exists. On 2026-09-03 the live published Package.swift contradicted
itself inside one file: the `bitHumanKit` block recorded, with a measurement,
that the umbrella "DOES NOT CONTAIN libessence", and ~100 lines lower a note in
`products:` still told the reader to "use `bitHumanKit` (the umbrella product
re-exports both engines)". The same header sent developers to two modules the
package has never vended. None of that is reachable by `swift build`: SwiftPM
compiles the manifest, it does not read the comments, so a manifest can resolve
perfectly while lying to every developer who opens it in Xcode.

FIVE RULES, and every one of them has a mutation arm below. Run
`--prove-by-mutation` and each arm must turn this guard RED; an arm whose edit
does not change the file's bytes is itself an ERROR (a mutation that mutates
nothing is how a guard passes by testing air).

  R1 CHECKSUM     every .binaryTarget URL fetches 200 and its sha256 equals the
                  pinned checksum.
  R2 TOKENS       the measured `strings -a` count block in the bitHumanKit
                  comment matches a fresh `strings -a` of the ios-arm64 slice,
                  for the zero counts AND the non-zero counts. (`strings -a`,
                  never `grep` on a binary: without -a, grep reads 0 silently
                  and every absence claim would confirm itself.)
  R3 IMPORTS      every `import X` written as an instruction in a comment names
                  a product this package actually declares.
  R4 DOCUMENTED   the set of declared products equals the set named in the
                  "WHAT THIS PACKAGE ACTUALLY VENDS" block.
  R5 NO-CLAIM     no comment may mention a library token measured ABSENT
                  (libessence, libelevate, onnxruntime, tessera) without a
                  negation/quotation marker on the same line.

Exit 0 = all rules pass. Exit 1 = a rule failed. Exit 2 = harness error.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
MANIFEST = REPO / "Package.swift"

RULES = ["R1-CHECKSUM", "R2-TOKENS", "R3-IMPORTS", "R4-DOCUMENTED", "R5-NO-CLAIM"]

# Tokens that name a LIBRARY and are measured absent from the umbrella. Bare
# "essence" is deliberately NOT here: essence-2 is a real product family the
# manifest must be able to discuss in prose.
ABSENT_LIB_TOKENS = ["libessence", "libelevate", "onnxruntime", "tessera"]

# A line mentioning an absent token is only allowed if it also carries one of
# these — i.e. it is denying the token, quoting an old denial, or is the
# measured count block itself.
NEGATION_MARKERS = [
    "not", "no ", "never", "zero", "used to", "was", "refuted",
    "absent", "deleted", "0",
]


class Failure(Exception):
    pass


def log(msg: str) -> None:
    print(msg, flush=True)


# ---------------------------------------------------------------------------
# manifest parsing
# ---------------------------------------------------------------------------

def read_manifest(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def comment_lines(src: str) -> list[tuple[int, str]]:
    out = []
    for i, line in enumerate(src.splitlines(), 1):
        s = line.strip()
        if s.startswith("//"):
            out.append((i, s))
    return out


def code_text(src: str) -> str:
    keep = [l for l in src.splitlines() if not l.strip().startswith("//")]
    return "\n".join(keep)


def parse_constants(src: str) -> dict[str, str]:
    consts = {}
    for m in re.finditer(r'^\s*let\s+([A-Za-z][A-Za-z0-9]*)\s*=\s*"([^"]*)"', code_text(src), re.M):
        consts[m.group(1)] = m.group(2)
    # resolve one level of \(interpolation)
    for _ in range(3):
        for k, v in list(consts.items()):
            def sub(mm):
                return consts.get(mm.group(1), mm.group(0))
            consts[k] = re.sub(r'\\\(([A-Za-z][A-Za-z0-9]*)\)', sub, v)
    return consts


def parse_binary_targets(src: str) -> list[dict]:
    consts = parse_constants(src)
    targets = []
    pat = re.compile(
        r'\.binaryTarget\(\s*name:\s*"([^"]+)"\s*,\s*url:\s*"([^"]+)"\s*,\s*checksum:\s*"([0-9a-fA-F]+)"',
        re.S,
    )
    for m in pat.finditer(code_text(src)):
        url = m.group(2)

        def sub(mm):
            return consts.get(mm.group(1), mm.group(0))

        url = re.sub(r'\\\(([A-Za-z][A-Za-z0-9]*)\)', sub, url)
        targets.append({"name": m.group(1), "url": url, "checksum": m.group(3).lower()})
    return targets


def parse_products(src: str) -> list[str]:
    return re.findall(r'\.library\(name:\s*"([^"]+)"', code_text(src))


# ---------------------------------------------------------------------------
# fetching
# ---------------------------------------------------------------------------

def fetch(url: str, cache: Path) -> bytes:
    cache.mkdir(parents=True, exist_ok=True)
    key = hashlib.sha256(url.encode()).hexdigest()[:16]
    blob = cache / key
    if blob.exists():
        return blob.read_bytes()
    req = urllib.request.Request(url, headers={"User-Agent": "check-manifest-truth"})
    try:
        with urllib.request.urlopen(req, timeout=600) as r:
            data = r.read()
    except Exception as e:  # 404 included
        raise Failure(f"fetch failed: {url}: {e}")
    blob.write_bytes(data)
    return data


def ios_slice_from_zip(data: bytes, framework: str) -> bytes:
    """Return the ios-arm64 (device, not simulator) mach-o/ar payload."""
    zf = zipfile.ZipFile(io.BytesIO(data))
    want = f"ios-arm64/{framework}.framework/{framework}"
    for n in zf.namelist():
        if n.endswith(want):
            return zf.read(n)
    raise Failure(f"no ios-arm64 slice for {framework} in the downloaded zip")


def strings_a(blob: bytes, workdir: Path) -> str:
    """`strings -a` on real bytes. -a is load-bearing: it is the difference
    between reading the whole file and silently reading nothing."""
    p = workdir / "slice.bin"
    p.write_bytes(blob)
    r = subprocess.run(["strings", "-a", str(p)], capture_output=True, text=True)
    if r.returncode != 0:
        raise Failure(f"strings -a failed rc={r.returncode}")
    return r.stdout


# ---------------------------------------------------------------------------
# rules
# ---------------------------------------------------------------------------

def rule_R1_checksum(src, cache, workdir, state) -> list[str]:
    errs = []
    for t in parse_binary_targets(src):
        try:
            data = fetch(t["url"], cache)
        except Failure as e:
            errs.append(f"R1 {t['name']}: {e}")
            continue
        got = hashlib.sha256(data).hexdigest()
        if got != t["checksum"]:
            errs.append(
                f"R1 {t['name']}: sha256 measured {got} != pinned {t['checksum']} ({t['url']})"
            )
        else:
            log(f"    R1 ok  {t['name']:28} {len(data):>10} B  sha256 {got[:16]}…")
        if t["name"] == "bitHumanKit":
            state["kit_zip"] = data
    return errs


COUNT_PAIR = re.compile(r'([A-Za-z][A-Za-z0-9_]*)\s+(\d+)')
# A count-block line is ONLY `tok N` pairs joined by `·`, optionally trailing `·`.
# Anchoring the WHOLE line is what stops the parser walking on into prose and
# inventing a claim ("...grep silently reads 0" parsed as token 'reads' = 0).
COUNT_LINE = re.compile(r'^[A-Za-z][A-Za-z0-9_]*\s+\d+(\s*·\s*[A-Za-z][A-Za-z0-9_]*\s+\d+)*\s*·?$')


def parse_count_claims(src: str) -> dict[str, int]:
    """Read the `strings -a` count block out of the bitHumanKit comment."""
    claims: dict[str, int] = {}
    inblock = False
    for _, line in comment_lines(src):
        if "counts:" in line:
            inblock = True
            continue
        if inblock:
            body = line.lstrip("/").strip()
            if not COUNT_LINE.match(body):
                break
            for tok, n in COUNT_PAIR.findall(body):
                claims[tok] = int(n)
    return claims


def rule_R2_tokens(src, cache, workdir, state) -> list[str]:
    errs = []
    claims = parse_count_claims(src)
    if not claims:
        return ["R2: no `strings -a` count block found in the manifest comments"]
    data = state.get("kit_zip")
    if data is None:
        return ["R2: bitHumanKit zip unavailable (R1 must pass first)"]
    blob = ios_slice_from_zip(data, "bitHumanKit")
    text = strings_a(blob, workdir)
    lines = text.splitlines()
    zero, nonzero = 0, 0
    for tok, want in sorted(claims.items()):
        got = sum(1 for l in lines if tok in l)
        if got != want:
            errs.append(f"R2 token '{tok}': manifest claims {want}, `strings -a` measures {got}")
        else:
            (zero if want == 0 else nonzero).__class__  # no-op, keeps intent readable
            if want == 0:
                zero += 1
            else:
                nonzero += 1
    if not errs:
        log(f"    R2 ok  {len(claims)} token counts match ({nonzero} present, {zero} absent)")
    if zero == 0 or nonzero == 0:
        errs.append(
            f"R2: the count block must assert BOTH presence and absence "
            f"(got {nonzero} non-zero, {zero} zero) — an absence-only block cannot "
            f"tell a real reading from an empty one"
        )
    return errs


IMPORT_INSTRUCTION = re.compile(r'`import ([A-Za-z][A-Za-z0-9_]*)`')


def rule_R3_imports(src, cache, workdir, state) -> list[str]:
    errs = []
    products = set(parse_products(src))
    seen = set()
    for ln, line in comment_lines(src):
        for name in IMPORT_INSTRUCTION.findall(line):
            seen.add(name)
            if name not in products:
                errs.append(
                    f"R3 line {ln}: comment instructs `import {name}` but the package "
                    f"declares no such product (products: {sorted(products)})"
                )
    if not errs:
        log(f"    R3 ok  {len(seen)} `import` instructions, all declared products: {sorted(seen)}")
    return errs


VENDS_HEADER = "WHAT THIS PACKAGE ACTUALLY VENDS"


def rule_R4_documented(src, cache, workdir, state) -> list[str]:
    products = set(parse_products(src))
    lines = comment_lines(src)
    start = None
    for idx, (ln, line) in enumerate(lines):
        if VENDS_HEADER in line:
            start = idx
            break
    if start is None:
        return [f"R4: the manifest has no '{VENDS_HEADER}' block to check products against"]
    block = []
    for ln, line in lines[start + 1:]:
        body = line.lstrip("/").strip()
        if not body:
            block.append(line)          # a bare `//` is a paragraph break, not the end
            continue
        if set(body) <= {"─", "-", "="}:
            break                        # a rule line ends the block
        block.append(line)
        if len(block) > 60:
            break
    text = "\n".join(block)
    documented = set(re.findall(r'^\s*//\s+-\s+([A-Za-z][A-Za-z0-9_]*)', text, re.M))
    errs = []
    for p in sorted(products - documented):
        errs.append(f"R4: product '{p}' is declared but not listed in the {VENDS_HEADER} block")
    for d in sorted(documented - products):
        errs.append(f"R4: the {VENDS_HEADER} block lists '{d}', which is not a declared product")
    if not errs:
        log(f"    R4 ok  declared == documented: {sorted(products)}")
    return errs


def rule_R5_noclaim(src, cache, workdir, state) -> list[str]:
    errs = []
    checked = 0
    cl = comment_lines(src)
    for idx, (ln, line) in enumerate(cl):
        body = line.lstrip("/").strip()
        # A negation can sit on the previous line: "NOT ONE of them is libessence,\n
        # libelevate or onnxruntime." is ONE clause that the 80-column wrap split.
        # Read the clause, not the line, or the rule reds on its own formatting.
        prev = cl[idx - 1][1].lstrip("/").strip() if idx else ""
        low = (prev + " " + body).lower()
        for tok in ABSENT_LIB_TOKENS:
            if tok in body.lower():
                checked += 1
                if not any(m in low for m in NEGATION_MARKERS):
                    errs.append(
                        f"R5 line {ln}: mentions '{tok}' — measured ABSENT from the shipped "
                        f"umbrella — with no negation on the line: {body[:100]!r}"
                    )
    if not errs:
        log(f"    R5 ok  {checked} mentions of absent library tokens, all negated or quoted")
    return errs


RULE_FUNCS = {
    "R1-CHECKSUM": rule_R1_checksum,
    "R2-TOKENS": rule_R2_tokens,
    "R3-IMPORTS": rule_R3_imports,
    "R4-DOCUMENTED": rule_R4_documented,
    "R5-NO-CLAIM": rule_R5_noclaim,
}


def run_all(src: str, cache: Path, only: str | None = None) -> list[str]:
    errs: list[str] = []
    state: dict = {}
    with tempfile.TemporaryDirectory(dir=str(cache)) as td:
        wd = Path(td)
        for name in RULES:
            if only and name != only and name != "R1-CHECKSUM":
                # R1 always runs: R2 needs the downloaded zip it caches.
                continue
            try:
                errs.extend(RULE_FUNCS[name](src, cache, wd, state))
            except Failure as e:
                errs.append(f"{name}: {e}")
    return errs


# ---------------------------------------------------------------------------
# mutation proof
# ---------------------------------------------------------------------------

def _mut_checksum(src: str) -> str:
    return src.replace(
        '"5c536e37919b693591dff234db8627c01952ae24ae58651aeacbd875bd78e9db"',
        '"5c536e37919b693591dff234db8627c01952ae24ae58651aeacbd875bd78e9dc"',
    )


def _mut_url_404(src: str) -> str:
    return src.replace("bitHumanKit.xcframework.zip", "bitHumanKit-zzz-none.xcframework.zip")


def _mut_count_nonzero(src: str) -> str:
    return src.replace("ImxContainer 141", "ImxContainer 142")


def _mut_count_zero(src: str) -> str:
    return src.replace("libessence 0", "libessence 7")


def _mut_import_ghost(src: str) -> str:
    return src.replace("`import bitHumanKit`.", "`import bitHumanKit`. Or `import Expression`.", 1)


def _mut_undocumented_product(src: str) -> str:
    return src.replace(
        '.library(name: "bitHumanKit", targets: ["bitHumanKit"]),',
        '.library(name: "bitHumanKit", targets: ["bitHumanKit"]),\n'
        '        .library(name: "Ghost", targets: ["bitHumanKit"]),',
        1,
    )


def _mut_reexports_claim(src: str) -> str:
    return src.replace(
        "import PackageDescription",
        "// the umbrella product re-exports the libessence runtime\n"
        "import PackageDescription",
        1,
    )


ARMS = [
    ("R1-CHECKSUM", "flip one hex digit of the pinned bitHumanKit checksum", _mut_checksum),
    ("R1-CHECKSUM", "point the bitHumanKit asset at a URL that 404s", _mut_url_404),
    ("R2-TOKENS", "overstate a PRESENT token count (ImxContainer 141 -> 142)", _mut_count_nonzero),
    ("R2-TOKENS", "claim an ABSENT token is present (libessence 0 -> 7)", _mut_count_zero),
    ("R3-IMPORTS", "instruct `import Expression`, a product that does not exist", _mut_import_ghost),
    ("R4-DOCUMENTED", "declare a product the VENDS block does not list", _mut_undocumented_product),
    ("R5-NO-CLAIM", "re-add the 're-exports the libessence runtime' claim", _mut_reexports_claim),
]


def prove_by_mutation(src: str, cache: Path) -> int:
    covered = {a[0] for a in ARMS}
    missing = [r for r in RULES if r not in covered]
    if missing:
        log(f"HARNESS ERROR: rules with no mutation arm: {missing}")
        return 2

    log("")
    log("PROVE BY MUTATION — every arm must turn the guard RED.")
    log(f"  rules: {len(RULES)}   arms: {len(ARMS)}   every rule armed: yes")
    log("")

    base = run_all(src, cache)
    if base:
        log("HARNESS ERROR: the UNMUTATED manifest is already RED, so no arm can prove anything:")
        for e in base:
            log(f"    {e}")
        return 2
    log("  negative control (unmutated manifest) ....... GREEN  [required]")
    log("")

    bad = 0
    for rule, desc, fn in ARMS:
        mutated = fn(src)
        if mutated == src:
            log(f"  [{rule}] {desc}")
            log(f"      HARNESS ERROR: the mutation changed NOTHING — this arm tests air.")
            bad += 1
            continue
        errs = run_all(mutated, cache, only=rule)
        hit = [e for e in errs if e.startswith(rule.split("-")[0])]
        if hit:
            log(f"  [{rule}] {desc}")
            log(f"      RED as required -> {hit[0][:130]}")
        else:
            log(f"  [{rule}] {desc}")
            log(f"      ✗ GUARD STAYED GREEN — this rule is blind to its own defect.")
            bad += 1
    log("")
    if bad:
        log(f"MUTATION PROOF FAILED: {bad} of {len(ARMS)} arms did not turn the guard RED.")
        return 1
    log(f"MUTATION PROOF PASSED: {len(ARMS)}/{len(ARMS)} arms RED, {len(RULES)}/{len(RULES)} rules armed.")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--manifest", default=str(MANIFEST))
    ap.add_argument("--cache", default=os.environ.get("MANIFEST_TRUTH_CACHE", ""),
                    help="directory for downloaded assets (default: a temp dir)")
    ap.add_argument("--prove-by-mutation", action="store_true")
    args = ap.parse_args()

    if not shutil.which("strings"):
        log("HARNESS ERROR: `strings` not on PATH (binutils). R2 cannot run.")
        return 2

    src = read_manifest(Path(args.manifest))
    tmp = None
    if args.cache:
        cache = Path(args.cache)
    else:
        tmp = tempfile.mkdtemp(prefix="manifest-truth-")
        cache = Path(tmp)
    cache.mkdir(parents=True, exist_ok=True)

    try:
        if args.prove_by_mutation:
            return prove_by_mutation(src, cache)

        log(f"check-manifest-truth: {args.manifest}")
        log(f"  products declared: {parse_products(src)}")
        errs = run_all(src, cache)
        log("")
        if errs:
            log(f"RED — {len(errs)} finding(s):")
            for e in errs:
                log(f"  {e}")
            return 1
        log(f"GREEN — all {len(RULES)} rules pass.")
        return 0
    finally:
        if tmp:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
