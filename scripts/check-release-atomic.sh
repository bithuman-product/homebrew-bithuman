#!/usr/bin/env bash
# =============================================================================
# check-release-atomic.sh — a cli-v* release must be COMPLETE and CONSISTENT
#                           before it is visible to anyone.
#
# ── THE DEFECT THIS EXISTS FOR ───────────────────────────────────────────────
# A `cli-vX.Y.Z` release is TWO tarballs (macOS arm64 + Linux x86_64), each
# with a `.sha256` sidecar, plus a formula that pins the macOS sha. Nothing
# made those arrive together, and measured on 2026-09-03 they never have:
#
#   tag         published_at          last asset uploaded   advertised
#                                                           incomplete for
#   cli-v2.5.1  2026-09-02T12:44:19Z  2026-09-02T19:42:49Z  6 h 58 m (linux)
#   cli-v2.5.0  2026-09-02T07:17:51Z  2026-09-02T11:55:21Z  4 h 37 m (linux)
#   cli-v2.4.2  2026-08-01T19:49:29Z  2026-08-02T03:02:56Z  7 h 13 m (BOTH)
#   cli-v2.4.0  2026-07-17T05:49:04Z  2026-07-17T06:36:38Z  47 m     (linux)
#   cli-v2.4.1  2026-08-01T15:54:28Z  (never)               permanently
#   cli-v2.3.27 2026-07-10T21:25:26Z  2026-07-10T21:25:07Z  0 — correct
#
# cli-v2.3.27 is the shape every release should have: every asset already
# uploaded when the release became visible. It is also this script's live
# positive control — C5 passing on it is what proves C5 is not simply red
# on everything.
#
# cli-v2.4.1 is the end state of the same bug: a published release carrying
# ZERO assets. During each window a Linux user following the tap got a 404,
# and a macOS user could get a tarball whose sha the formula had not been
# re-pinned to yet — this repo already carries the fix commit for that,
# 2a7cd37 "re-pin mac sha256 after linux-lane rebuild re-uploaded the asset".
#
# The fix is procedural and this script enforces it:
#   create the release as a DRAFT -> upload every asset -> run this -> publish.
# A draft is invisible to `brew` and to anonymous downloads, so the window
# closes. This script is what makes the last step safe.
#
# ── CHECKS ───────────────────────────────────────────────────────────────────
#   C1 COMPLETE      every asset in the required matrix is present
#   C2 NONEMPTY      no asset is 0 bytes or below its floor (a truncated
#                    upload publishes a tarball that cannot be extracted)
#   C3 SIDECAR-SHAPE each .sha256 is `<64 hex>  <the tarball's own filename>`
#                    — a sidecar naming a DIFFERENT file is what a re-cut
#                    leaves behind
#   C4 FORMULA-PIN   Formula/bithuman-cli.rb's url + sha256 match the release
#                    tag and the macOS sidecar's digest. This is a check on
#                    the release the formula CURRENTLY pins; pointing it at
#                    an older tag correctly reports the mismatch. Pass
#                    `--formula -` to check a historical release without it.
#   C5 ATOMIC        no asset was uploaded after the release stopped being a
#                    draft — this is the actual atomicity invariant, and the
#                    one every release above violates
#   C6 BYTES         (--verify-bytes) recomputed sha256 of the downloaded
#                    tarball equals its sidecar
#   C7 ONE BUILD     (--verify-bytes) the tarballs were produced by ONE build.
#                    ★ THIS IS THE SECOND PROVEN DEFECT AND C5 CANNOT SEE IT.
#                    C5 grades UPLOAD times, which a re-upload can make look
#                    tidy. C7 grades the BUILD clock carried INSIDE each
#                    archive -- the mtimes the build machine stamped on the
#                    members -- so it survives re-uploading, renaming and
#                    re-tagging. Measured on the real cli-v2.5.1 assets,
#                    2026-09-04:
#                        bithuman-aarch64-apple-darwin.tar.gz  ./bithuman
#                            2026-09-02 08:42:02   (and ./engines/ 08:41)
#                        bithuman-x86_64-unknown-linux-gnu.tar.gz  bithuman
#                            2026-09-02 15:32:58   (and engines/ 15:32)
#                    Six hours fifty minutes apart. Each archive is internally
#                    tight -- every member within a minute or two -- so this is
#                    not clock noise, it is two builds. One release, two source
#                    trees, and every checksum on both of them is correct.
##   C8 ONE TREE      (--verify-bytes) every asset carries the SAME source
#                    commit, read out of the binary's own bytes.
#                    ★ AND IT IS WHAT REPLACES C7, NOT WHAT SUPPLEMENTS IT.
#                    C7 reads member mtimes; a reproducible pack fixes those,
#                    so C7 measures 0.00 h spread on a release built from two
#                    different commits -- MEASURED 2026-09-04 on two real
#                    packs. C8 reads a stamp the compiler put inside the
#                    binary, which no repack can smooth over. An asset that
#                    carries no stamp is REFUSED, not skipped: that is the
#                    state of every release published to date, and it is
#                    precisely what may not happen again.
#
# ── USAGE ────────────────────────────────────────────────────────────────────
#   scripts/check-release-atomic.sh cli-v2.5.1
#   scripts/check-release-atomic.sh --manifest fixture.json [--formula F]
#                                   [--assets DIR] [--verify-bytes]
#   scripts/check-release-atomic.sh --self-test
#
#   --manifest takes the JSON `gh api repos/OWNER/REPO/releases/tags/TAG`
#   returns, so the checks can be exercised against fixtures — including
#   fixtures that are deliberately broken — with no network and no risk of
#   touching a published release. In LIVE mode a DRAFT is read from the
#   release LIST instead, because a draft has no git tag and the tags
#   endpoint 404s on it (measured 2026-09-10 on cli-v2.6.5) — which is the
#   state this gate exists to grade.
#
# ── EXIT CODES ───────────────────────────────────────────────────────────────
#   0  release is complete, consistent and was assembled before it was visible
#   1  a check failed — DO NOT PUBLISH
#   3  could not run (no gh, no jq/python, no manifest). Not a pass.
# =============================================================================
set -uo pipefail

REPO="${BITHUMAN_TAP_REPO:-bithuman-product/homebrew-bithuman}"

# ── THE MATRIX — single source of truth. Add a platform here only. ──────────
# name                                       floor bytes (a sane lower bound;
#                                            the real tarballs are 166–276 MB)
# The floor catches a TRUNCATED or empty upload, which is the realistic
# failure. It is deliberately far below today's 166–276 MB tarballs: a floor
# tuned to the current size would encode "must vendor an engine" and go red
# on cli-v2.3.27 (33/38 MB, cut before engine vendoring), which is a correct
# release. Byte integrity is C6's job, not this one's.
REQUIRED_TARBALLS=(
  "bithuman-aarch64-apple-darwin.tar.gz:10000000"
  "bithuman-x86_64-unknown-linux-gnu.tar.gz:10000000"
)
# The formula pins the macOS half.
FORMULA_PLATFORM="bithuman-aarch64-apple-darwin.tar.gz"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_FORMULA="${SCRIPT_DIR}/../Formula/bithuman-cli.rb"

PY="${PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 || { echo "FATAL: no $PY — cannot run" >&2; exit 3; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/relatomic.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT INT TERM

MANIFEST=""; FORMULA=""; ASSETS=""; VERIFY_BYTES=0; TAG=""; SELFTEST=0
GATE_DRAFT=""; GATE_REQUIRE=""
while (( $# )); do
  case "$1" in
    --manifest)      MANIFEST="$2"; shift 2 ;;
    --formula)       FORMULA="$2"; shift 2 ;;
    --assets)        ASSETS="$2"; shift 2 ;;
    --verify-bytes)  VERIFY_BYTES=1; shift ;;
    --self-test)     SELFTEST=1; shift ;;
    --gate-draft)    GATE_DRAFT="$2"; GATE_REQUIRE="$3"; shift 3 ;;
    --repo)          REPO="$2"; shift 2 ;;
    -*)              echo "unknown flag: $1" >&2; exit 3 ;;
    *)               TAG="$1"; shift ;;
  esac
done
[[ -n "$FORMULA" ]] || FORMULA="$DEFAULT_FORMULA"

# ---------------------------------------------------------------------------
# run_checks <manifest.json> <formula|-> <assets-dir|-> <verify-bytes 0|1>
#   Prints one line per check. Returns 0 iff every check passed.
#   The FAILING check ids are written to $WORK/failed so a caller (the
#   self-test) can assert a mutation failed for the RIGHT reason.
# ---------------------------------------------------------------------------
run_checks() {
  local man="$1" formula="$2" assets="$3" bytes="$4"
  : > "$WORK/failed"

  REQ_SPEC="$(printf '%s\n' "${REQUIRED_TARBALLS[@]}")" \
  FORMULA_PLATFORM="$FORMULA_PLATFORM" \
  MAN="$man" FORMULA_FILE="$formula" ASSET_DIR="$assets" VERIFY="$bytes" \
  FAILED_OUT="$WORK/failed" \
  "$PY" <<'CHECKS'
import hashlib, json, os, re, sys, time
from datetime import datetime, timezone

man       = json.load(open(os.environ["MAN"]))
req_spec  = [l for l in os.environ["REQ_SPEC"].splitlines() if l.strip()]
required  = {}
for line in req_spec:
    name, floor = line.rsplit(":", 1)
    required[name] = int(floor)
formula_platform = os.environ["FORMULA_PLATFORM"]
formula_file = os.environ["FORMULA_FILE"]
asset_dir    = os.environ["ASSET_DIR"]
verify_bytes = os.environ["VERIFY"] == "1"
failed = []

def ok(cid, msg):   print(f"  [{cid}] PASS  {msg}")
def bad(cid, msg):  print(f"  [{cid}] FAIL  {msg}"); failed.append(cid)

assets = {a["name"]: a for a in man.get("assets", [])}
tag    = man.get("tag_name", "?")
draft  = man.get("draft", False)
print(f"release {tag}  draft={draft}  assets={len(assets)}")

def parse(ts):
    if not ts: return None
    return datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)

# ── C1 COMPLETE ────────────────────────────────────────────────────────────
missing = []
for name in required:
    for want in (name, name + ".sha256"):
        if want not in assets:
            missing.append(want)
if missing:
    bad("C1", "missing asset(s): " + ", ".join(sorted(missing)))
else:
    ok("C1", f"all {2*len(required)} required assets present")

# ── C2 NONEMPTY ────────────────────────────────────────────────────────────
small = []
for name, floor in required.items():
    a = assets.get(name)
    if a is None:
        continue                      # already reported by C1
    if int(a.get("size", 0)) < floor:
        small.append(f"{name}={a.get('size')}B (floor {floor}B)")
    s = assets.get(name + ".sha256")
    if s is not None and int(s.get("size", 0)) < 64:
        small.append(f"{name}.sha256={s.get('size')}B (a sha256 line is >=64B)")
if small:
    bad("C2", "asset(s) below floor: " + "; ".join(small))
else:
    ok("C2", "every present asset is above its size floor")

# ── C3 SIDECAR-SHAPE ───────────────────────────────────────────────────────
# Needs the sidecar CONTENT. Sidecars are ~107 bytes, so downloading them is
# cheap; when --assets is given we read from disk instead.
sidecar_digest = {}
shape_problems = []
for name in required:
    sc = name + ".sha256"
    text = None
    if asset_dir != "-" and os.path.isfile(os.path.join(asset_dir, sc)):
        text = open(os.path.join(asset_dir, sc)).read()
    elif "body_text" in assets.get(sc, {}):
        text = assets[sc]["body_text"]        # fixture-injected content
    if text is None:
        shape_problems.append(f"{sc}: content not available to check")
        continue
    m = re.match(r"^([0-9a-f]{64})\s+\*?(\S+)\s*$", text.strip())
    if not m:
        shape_problems.append(f"{sc}: not `<64 hex>  <filename>` -> {text.strip()[:70]!r}")
        continue
    digest, fname = m.group(1), os.path.basename(m.group(2))
    sidecar_digest[name] = digest
    if fname != name:
        shape_problems.append(f"{sc}: names {fname!r}, should name {name!r}")
if shape_problems:
    bad("C3", "; ".join(shape_problems))
else:
    ok("C3", "every sidecar is well-formed and names its own tarball")

# ── C4 FORMULA-PIN ─────────────────────────────────────────────────────────
if formula_file == "-":
    print("  [C4] SKIP  no formula given")
else:
    try:
        f = open(formula_file).read()
    except OSError as e:
        bad("C4", f"cannot read formula: {e}")
        f = None
    if f is not None:
        url = re.search(r'^\s*url\s+"([^"]+)"', f, re.M)
        sha = re.search(r'^\s*sha256\s+"([0-9a-f]{64})"', f, re.M)
        probs = []
        if not url or not sha:
            probs.append("formula has no top-level url/sha256 pair")
        else:
            u, s = url.group(1), sha.group(1)
            if f"/download/{tag}/" not in u:
                probs.append(f"formula url points at {u.split('/download/')[-1].split('/')[0]!r}, release is {tag!r}")
            if not u.endswith(formula_platform):
                probs.append(f"formula url asset is {u.rsplit('/',1)[-1]!r}, expected {formula_platform!r}")
            want = sidecar_digest.get(formula_platform)
            if want is None:
                probs.append("macOS sidecar digest unavailable — cannot confirm the pin")
            elif want != s:
                probs.append(f"formula pins {s[:12]}… but the published sidecar says {want[:12]}…")
        if probs:
            bad("C4", "; ".join(probs))
        else:
            ok("C4", f"formula pins {tag}/{formula_platform} at the published sha")

# ── C5 ATOMIC ──────────────────────────────────────────────────────────────
# The release became visible at published_at (a draft has none). Any asset
# created after that moment was advertised before it existed.
pub = parse(man.get("published_at"))
if draft:
    ok("C5", "still a draft — not yet visible, nothing can be advertised early")
elif pub is None:
    bad("C5", "not a draft but has no published_at — cannot bound the window")
else:
    late = []
    for name, a in assets.items():
        c = parse(a.get("created_at"))
        if c is not None and c > pub:
            late.append((name, int((c - pub).total_seconds())))
    if late:
        late.sort(key=lambda t: -t[1])
        detail = "; ".join(f"{n} uploaded {s//3600}h{(s%3600)//60:02d}m after publish" for n, s in late)
        bad("C5", f"release was visible before it was complete: {detail}")
    else:
        ok("C5", "every asset existed before the release became visible")

# ── C6 BYTES ───────────────────────────────────────────────────────────────
if not verify_bytes:
    print("  [C6] SKIP  --verify-bytes not given (manifest-only run)")
elif asset_dir == "-":
    bad("C6", "--verify-bytes needs --assets DIR")
else:
    probs = []
    checked = 0
    for name in required:
        path = os.path.join(asset_dir, name)
        if not os.path.isfile(path):
            probs.append(f"{name}: not in {asset_dir}")
            continue
        h = hashlib.sha256()
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                h.update(chunk)
        got = h.hexdigest()
        want = sidecar_digest.get(name)
        if want is None:
            probs.append(f"{name}: no sidecar digest to compare against")
        elif got != want:
            probs.append(f"{name}: bytes hash {got[:12]}…, sidecar says {want[:12]}…")
        else:
            checked += 1
    if probs:
        bad("C6", "; ".join(probs))
    else:
        ok("C6", f"recomputed sha256 matches the sidecar for {checked} tarball(s)")

# ── C7 ONE BUILD ───────────────────────────────────────────────────────────
# The build clock lives inside the archive. Take the LATEST member mtime in each
# tarball -- when the build finished writing it -- and require every tarball in
# the release to agree to within C7_WINDOW_H hours. The two jobs of one dispatch
# run in parallel and finish within minutes of each other; the mac job's own
# timeout is 60 minutes. Four hours is therefore generous by design: it is wide
# enough that a slow, retried, but SINGLE release passes, and narrow enough that
# the seven-hour gap on cli-v2.5.1 cannot.
#
# ★ It SKIPS rather than passes when it cannot read a tarball. An unreadable
# archive is C2/C6's finding, not a licence for C7 to report green.
window_h = float(os.environ.get("C7_WINDOW_H", "4"))
if not verify_bytes:
    print("  [C7] SKIP  --verify-bytes not given (the build clock is inside the tarball)")
elif asset_dir == "-":
    bad("C7", "--verify-bytes needs --assets DIR")
else:
    import tarfile
    clocks = {}
    unread = []
    for name in required:
        if not name.endswith(".tar.gz"):
            continue
        path = os.path.join(asset_dir, name)
        try:
            with tarfile.open(path, "r:gz") as tf:
                mt = [m.mtime for m in tf.getmembers() if m.mtime]
            if not mt:
                unread.append(f"{name}: no member carries an mtime")
            else:
                clocks[name] = (min(mt), max(mt))
        except Exception as e:
            unread.append(f"{name}: {type(e).__name__}")
    if unread and not clocks:
        print("  [C7] SKIP  could not read a build clock out of any tarball "
              f"({'; '.join(unread)})")
    elif len(clocks) < 2:
        print(f"  [C7] SKIP  only {len(clocks)} tarball(s) readable — nothing to compare")
    else:
        def ts(x): return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(x))
        finals = {n: v[1] for n, v in clocks.items()}
        lo_n = min(finals, key=finals.get); hi_n = max(finals, key=finals.get)
        spread = finals[hi_n] - finals[lo_n]
        detail = ", ".join(f"{n} built {ts(v[1])}" for n, v in sorted(clocks.items()))
        if spread > window_h * 3600:
            bad("C7", f"the assets are from DIFFERENT BUILDS: {detail} — "
                      f"{spread/3600:.2f} h apart, window is {window_h:g} h. "
                      f"One release must be one build from one commit.")
        else:
            ok("C7", f"one build: every tarball's clock within {spread/3600:.2f} h "
                     f"({detail})")

# ── C8 ONE TREE ─────────────────────────────────────────────────────────────
# ★C7 IS NOT ENOUGH ANY MORE, AND THAT IS MEASURED, NOT FEARED.
# C7 grades the member mtimes the build machine stamped inside each archive.
# The moment a release is packed REPRODUCIBLY -- which is the whole point of
# `bithuman-cli scripts/release_pack.sh`, and which is what makes "gate this
# file, publish this file" possible at all -- every member carries a FIXED
# mtime from SOURCE_DATE_EPOCH.  Measured 2026-09-04 on two real packs of two
# genuinely different binaries built from two different commits:
#
#     relC (one tree)  mac 1756900000  linux 1756900000   spread 0.00 h
#     relM (TWO trees) mac 1756900000  linux 1756900000   spread 0.00 h
#
# C7 reports "one build" for BOTH.  The defect it was written for becomes
# invisible to it the day we fix packing.  So the discriminator has to move
# INSIDE the artifact, and it has: each tarball now carries the source commit
# in a self-delimiting stamp in the binary's own bytes, plus a PROVENANCE.json
# derived from it.  C8 reads them.
#
# ★AND IT REFUSES AN ARTIFACT THAT CANNOT NAME ITS TREE, rather than skipping
# it.  "No stamp" is the state every published release is in today (the estate
# graded 15 findings against a population of 15), and the whole point is that
# such an artifact may not be published again.  Historical auditing is
# unaffected: without --verify-bytes there are no bytes to read and C8 SKIPs.
_PB = "BITHUMAN-PROV" + "ENANCE-V1{"
_PE = "}END-BITHUMAN-" + "PROVENANCE"

def _scan_stamps(blob):
    """Every parseable stamp in `blob`.  Anchored on the END marker, then the
    LAST begin before it -- a stray begin marker (llvm really does pool one
    next to the stamp) must not swallow the real one."""
    b, e = _PB.encode(), _PE.encode()
    out, at = [], 0
    while True:
        end = blob.find(e, at)
        if end < 0:
            break
        start = blob.rfind(b, 0, end)
        if start >= 0:
            body = blob[start + len(b) - 1:end + 1]
            try:
                out.append(json.loads(body.decode("utf-8", "replace")))
            except Exception:
                pass
        at = end + len(e)
    return out

def _scan_member(tf, m, chunk=4 << 20):
    """Chunked scan of one tar member -- the binary is ~80 MB and this runs on
    a CI runner.  The overlap is longer than any stamp, so a stamp straddling
    a chunk boundary is still found."""
    f = tf.extractfile(m)
    if f is None:
        return []
    found, tail = [], b""
    while True:
        buf = f.read(chunk)
        if not buf:
            break
        found += _scan_stamps(tail + buf)
        tail = (tail + buf)[-4096:]
    return found

if not verify_bytes:
    print("  [C8] SKIP  --verify-bytes not given (the stamp is inside the tarball)")
elif asset_dir == "-":
    bad("C8", "--verify-bytes needs --assets DIR")
else:
    import tarfile
    trees, probs, unread = {}, [], []
    for name in required:
        if not name.endswith(".tar.gz"):
            continue
        path = os.path.join(asset_dir, name)
        try:
            with tarfile.open(path, "r:gz") as tf:
                sidecar, in_binary = None, []
                for m in tf.getmembers():
                    if not m.isfile():
                        continue
                    if os.path.basename(m.name) == "PROVENANCE.json":
                        try:
                            sidecar = json.loads(tf.extractfile(m).read().decode())
                        except Exception:
                            probs.append(f"{name}: PROVENANCE.json is not readable JSON")
                    else:
                        # ★NO SIZE THRESHOLD. An earlier draft only scanned
                        # members over 1 MiB — a magic number that decides
                        # which bytes count, and the kind of rule that goes
                        # wrong silently the day an artifact is repackaged.
                        # Every member is scanned; the scan is chunked, so a
                        # small member costs almost nothing.
                        in_binary += _scan_member(tf, m)
        except Exception as exc:
            unread.append(f"{name}: {type(exc).__name__}")
            continue

        if not in_binary:
            probs.append(f"{name}: carries NO provenance stamp — it cannot name "
                         f"the tree that built it")
            continue
        if len(in_binary) > 1:
            probs.append(f"{name}: {len(in_binary)} stamps inside — which one is "
                         f"the artifact talking?")
            continue
        stamp = in_binary[0]
        commit = str(stamp.get("commit", ""))
        if not re.fullmatch(r"[0-9a-f]{40}", commit):
            probs.append(f"{name}: stamped commit {commit!r} does not name a tree")
            continue
        if stamp.get("dirty") == "true":
            probs.append(f"{name}: built from a tree with uncommitted changes")
        if sidecar is None:
            probs.append(f"{name}: no PROVENANCE.json beside the binary")
        elif str(sidecar.get("commit", "")) != commit:
            probs.append(f"{name}: PROVENANCE.json says {str(sidecar.get('commit',''))[:12]}, "
                         f"the binary says {commit[:12]}")
        trees[name] = commit

    if unread and not trees:
        print("  [C8] SKIP  could not open any tarball ({})".format("; ".join(unread)))
    elif probs:
        bad("C8", "; ".join(probs))
    elif len(set(trees.values())) > 1:
        detail = ", ".join(f"{n} <- {c[:12]}" for n, c in sorted(trees.items()))
        bad("C8", f"the assets name {len(set(trees.values()))} DIFFERENT SOURCE TREES: "
                  f"{detail}. One release is one tree.")
    elif not trees:
        print("  [C8] SKIP  no tarball readable — nothing to compare")
    else:
        one = next(iter(set(trees.values())))
        bad_note = "" if len(trees) > 1 else "  (only one tarball — no comparison)"
        ok("C8", f"one tree: every asset built from {one[:12]}{bad_note}")

open(os.environ["FAILED_OUT"], "w").write("\n".join(failed))
sys.exit(1 if failed else 0)
CHECKS
}

# ---------------------------------------------------------------------------
# draft_verdict <draft-state> <require_draft>
#   The ONE decision that makes a release atomic: may this dispatch upload
#   assets to release_tag? Kept here, not inline in the workflow, so its truth
#   table is covered by --self-test instead of being exercised for the first
#   time during a real release.
#
#   draft-state is `true` | `false` | `missing` (tag does not exist).
#   Returns 0 to allow the upload, 1 to refuse.
# ---------------------------------------------------------------------------
draft_verdict() {
  local state="$1" require="$2"
  case "$state" in
    missing)
      echo "REFUSE: the release does not exist. Create it as a DRAFT first:"
      echo "        gh release create <tag> --draft --title '…' --notes '…'"
      return 1 ;;
    true)
      echo "ALLOW: still a draft — invisible to brew and to anonymous"
      echo "       downloads, so nothing is advertised while assets arrive."
      return 0 ;;
    false)
      if [[ "$require" == "true" ]]; then
        echo "REFUSE: the tag is already PUBLISHED. Uploading now re-opens the"
        echo "        window this gate exists to close — the tag is visible"
        echo "        while its assets are still arriving."
        return 1
      fi
      echo "ALLOW (require_draft=false): the tag is published; every second"
      echo "      until the last upload is a window. Repair only."
      return 0 ;;
    *)
      echo "REFUSE: unreadable draft state '"'"'$state'"'"' — an unreadable state is"
      echo "        not a green one."
      return 1 ;;
  esac
}

if [[ -n "$GATE_DRAFT" ]]; then
  draft_verdict "$GATE_DRAFT" "$GATE_REQUIRE"
  exit $?
fi

# ---------------------------------------------------------------------------
# SELF-TEST — mutation proof. Each mutation must fail, and must fail on the
# CHECK IT TARGETS: a mutation that trips some other check would let the
# targeted check be dead code and still show a red.
# ---------------------------------------------------------------------------
if (( SELFTEST )); then
  FIX="$WORK/fix"; mkdir -p "$FIX"
  # A synthetic COMPLETE release: both tarballs + sidecars, uploaded before
  # publish, formula pinned to the macOS sidecar's digest.
  MAC_SHA="$(printf 'mac-bytes'  | sha256sum | cut -d' ' -f1)"
  LNX_SHA="$(printf 'linux-bytes'| sha256sum | cut -d' ' -f1)"
  "$PY" - "$FIX/good.json" "$MAC_SHA" "$LNX_SHA" <<'MK'
import json, sys
out, mac, lnx = sys.argv[1], sys.argv[2], sys.argv[3]
def a(name, size, created, body=None):
    d = {"name": name, "size": size, "created_at": created, "updated_at": created}
    if body is not None: d["body_text"] = body
    return d
man = {
  "tag_name": "cli-v9.9.9", "draft": False,
  "published_at": "2026-09-03T12:00:00Z",
  "assets": [
    a("bithuman-aarch64-apple-darwin.tar.gz",       275952595, "2026-09-03T11:50:00Z"),
    a("bithuman-aarch64-apple-darwin.tar.gz.sha256",       103, "2026-09-03T11:50:00Z",
      f"{mac}  bithuman-aarch64-apple-darwin.tar.gz\n"),
    a("bithuman-x86_64-unknown-linux-gnu.tar.gz",   166759273, "2026-09-03T11:51:00Z"),
    a("bithuman-x86_64-unknown-linux-gnu.tar.gz.sha256",   107, "2026-09-03T11:51:00Z",
      f"{lnx}  bithuman-x86_64-unknown-linux-gnu.tar.gz\n"),
  ],
}
json.dump(man, open(out, "w"), indent=1)
MK
  cat > "$FIX/good.rb" <<RB
class BithumanCli < Formula
  url "https://github.com/bithuman-product/homebrew-bithuman/releases/download/cli-v9.9.9/bithuman-aarch64-apple-darwin.tar.gz"
  sha256 "$MAC_SHA"
end
RB

  fails=0
  echo "=============================================================="
  echo "BASELINE — a complete, consistent, draft-then-publish release"
  echo "=============================================================="
  if run_checks "$FIX/good.json" "$FIX/good.rb" "-" 0; then
    echo "BASELINE: PASS (rc=0)"
  else
    echo "*** BASELINE FAILED. Every mutation below would then be red for"
    echo "    free, and this whole self-test would prove nothing."
    fails=$((fails+1))
  fi

  mutate() {   # <label> <expected-check> <python mutation>
    local label="$1" expect="$2" prog="$3"
    echo
    echo "=============================================================="
    echo "MUTATION: $label   (must trip $expect)"
    echo "=============================================================="
    "$PY" - "$FIX/good.json" "$WORK/mut.json" <<MUT
import json, sys
m = json.load(open(sys.argv[1]))
A = {a["name"]: a for a in m["assets"]}
$prog
m["assets"] = list(A.values())
json.dump(m, open(sys.argv[2], "w"), indent=1)
MUT
    if run_checks "$WORK/mut.json" "$FIX/good.rb" "-" 0; then
      echo "*** NOT CAUGHT — the guard accepted a release it must refuse."
      fails=$((fails+1))
    else
      local got; got="$(tr '\n' ' ' < "$WORK/failed")"
      if [[ " $got " == *" $expect "* ]]; then
        echo "REFUSED on $expect — correct check fired (failed: $got)"
      else
        echo "*** REFUSED, but on the WRONG check: expected $expect, got: $got"
        echo "    $expect may be dead code and still look green here."
        fails=$((fails+1))
      fi
    fi
  }

  mutate "linux tarball absent"            C1 'A.pop("bithuman-x86_64-unknown-linux-gnu.tar.gz")'
  mutate "linux sidecar absent"            C1 'A.pop("bithuman-x86_64-unknown-linux-gnu.tar.gz.sha256")'
  mutate "mac tarball truncated to 4 KB"   C2 'A["bithuman-aarch64-apple-darwin.tar.gz"]["size"] = 4096'
  mutate "sidecar names the other file"    C3 'a=A["bithuman-x86_64-unknown-linux-gnu.tar.gz.sha256"]; a["body_text"]=a["body_text"].split("  ")[0]+"  bithuman-aarch64-apple-darwin.tar.gz\n"'
  mutate "sidecar digest is not 64 hex"    C3 'a=A["bithuman-x86_64-unknown-linux-gnu.tar.gz.sha256"]; a["body_text"]="deadbeef  bithuman-x86_64-unknown-linux-gnu.tar.gz\n"'
  mutate "mac sha changed, formula stale"  C4 'a=A["bithuman-aarch64-apple-darwin.tar.gz.sha256"]; a["body_text"]="0"*64+"  bithuman-aarch64-apple-darwin.tar.gz\n"'
  mutate "linux asset re-cut after publish" C5 'A["bithuman-x86_64-unknown-linux-gnu.tar.gz"]["created_at"]="2026-09-03T19:00:00Z"'

  echo
  echo "=============================================================="
  echo "MUTATION: bytes disagree with the sidecar   (must trip C6)"
  echo "=============================================================="
  BD="$WORK/bytes"; mkdir -p "$BD"
  printf 'mac-bytes'   > "$BD/bithuman-aarch64-apple-darwin.tar.gz"
  printf 'linux-bytes' > "$BD/bithuman-x86_64-unknown-linux-gnu.tar.gz"
  printf '%s  bithuman-aarch64-apple-darwin.tar.gz\n'      "$MAC_SHA" > "$BD/bithuman-aarch64-apple-darwin.tar.gz.sha256"
  printf '%s  bithuman-x86_64-unknown-linux-gnu.tar.gz\n'  "$LNX_SHA" > "$BD/bithuman-x86_64-unknown-linux-gnu.tar.gz.sha256"
  # Byte-mode control FIRST: with honest bytes C6 must PASS, or the mutation
  # below would be red no matter what. (Sizes are tiny here, so C2's floor is
  # relaxed for this control only — C2 is proven separately above.)
  REQUIRED_TARBALLS=(
    "bithuman-aarch64-apple-darwin.tar.gz:1"
    "bithuman-x86_64-unknown-linux-gnu.tar.gz:1"
  )
  if run_checks "$FIX/good.json" "$FIX/good.rb" "$BD" 1; then
    echo "  byte-mode control: PASS (honest bytes verify)"
  else
    echo "*** byte-mode control FAILED — C6 cannot be trusted below"
    fails=$((fails+1))
  fi
  printf 'linux-bytes-TAMPERED' > "$BD/bithuman-x86_64-unknown-linux-gnu.tar.gz"
  if run_checks "$FIX/good.json" "$FIX/good.rb" "$BD" 1; then
    echo "*** NOT CAUGHT — tampered bytes accepted"
    fails=$((fails+1))
  else
    got="$(tr '\n' ' ' < "$WORK/failed")"
    if [[ " $got " == *" C6 "* ]]; then
      echo "REFUSED on C6 — correct check fired (failed: $got)"
    else
      echo "*** REFUSED on the WRONG check: $got"
      fails=$((fails+1))
    fi
  fi

  echo
  echo "=============================================================="
  echo "MUTATION: the two tarballs are from two builds  (must trip C7)"
  echo "=============================================================="
  # Real .tar.gz files this time — C7 reads the clock the build machine stamped
  # on the members, so a text file cannot stand in for one.
  C7D="$WORK/c7"; mkdir -p "$C7D/src"
  # ★THE FIXTURE CARRIES A VALID STAMP, because a fixture that is broken in a
  # SECOND way cannot isolate the defect under test. Without this the C7
  # control was red on C8 ("no provenance stamp") and reported itself failed —
  # which is a fixture bug wearing a check's clothes.
  C7_COMMIT=$(printf '7%.0s' $(seq 1 40))
  {
    printf 'payload BITHUMAN-PROV'
    printf 'ENANCE-V1{"product":"bithuman-cli","commit":"%s","dirty":"false","target":"t"}END-BITHUMAN-PROVENANCE\n' "$C7_COMMIT"
  } > "$C7D/src/bithuman"
  printf '{"commit":"%s","dirty":"false","target":"t"}\n' "$C7_COMMIT" > "$C7D/src/PROVENANCE.json"
  mk_tar() { # <out.tar.gz> <epoch>
    touch -d "@$2" "$C7D/src/bithuman" "$C7D/src/PROVENANCE.json"
    tar -czf "$1" -C "$C7D/src" bithuman PROVENANCE.json
  }
  # Control: both built inside one window (12 minutes apart, like one dispatch).
  mk_tar "$C7D/bithuman-aarch64-apple-darwin.tar.gz"     1788400000
  mk_tar "$C7D/bithuman-x86_64-unknown-linux-gnu.tar.gz" 1788400720
  C7_MAC="$(sha256sum "$C7D/bithuman-aarch64-apple-darwin.tar.gz" | cut -d' ' -f1)"
  C7_LNX="$(sha256sum "$C7D/bithuman-x86_64-unknown-linux-gnu.tar.gz" | cut -d' ' -f1)"
  printf '%s  bithuman-aarch64-apple-darwin.tar.gz\n'     "$C7_MAC" > "$C7D/bithuman-aarch64-apple-darwin.tar.gz.sha256"
  printf '%s  bithuman-x86_64-unknown-linux-gnu.tar.gz\n' "$C7_LNX" > "$C7D/bithuman-x86_64-unknown-linux-gnu.tar.gz.sha256"
  "$PY" - "$FIX/good.json" "$WORK/c7.json" "$C7_MAC" "$C7_LNX" <<'MK7'
import json, sys
m = json.load(open(sys.argv[1]))
A = {a["name"]: a for a in m["assets"]}
A["bithuman-aarch64-apple-darwin.tar.gz.sha256"]["body_text"] = sys.argv[3] + "  bithuman-aarch64-apple-darwin.tar.gz\n"
A["bithuman-x86_64-unknown-linux-gnu.tar.gz.sha256"]["body_text"] = sys.argv[4] + "  bithuman-x86_64-unknown-linux-gnu.tar.gz\n"
m["assets"] = list(A.values())
json.dump(m, open(sys.argv[2], "w"), indent=1)
MK7
  cat > "$C7D/good.rb" <<RB7
class BithumanCli < Formula
  url "https://github.com/bithuman-product/homebrew-bithuman/releases/download/cli-v9.9.9/bithuman-aarch64-apple-darwin.tar.gz"
  sha256 "$C7_MAC"
RB7
  echo "end" >> "$C7D/good.rb"
  REQUIRED_TARBALLS=(
    "bithuman-aarch64-apple-darwin.tar.gz:1"
    "bithuman-x86_64-unknown-linux-gnu.tar.gz:1"
  )
  if run_checks "$WORK/c7.json" "$C7D/good.rb" "$C7D" 1; then
    echo "  one-build control: PASS (12 minutes apart is ONE build)"
  else
    echo "*** one-build control FAILED — C7 is red on a correct release and proves nothing"
    fails=$((fails+1))
  fi
  # Mutation: rebuild the linux tarball 6h58m later — the real cli-v2.5.1 gap.
  mk_tar "$C7D/bithuman-x86_64-unknown-linux-gnu.tar.gz" 1788425080
  C7_LNX2="$(sha256sum "$C7D/bithuman-x86_64-unknown-linux-gnu.tar.gz" | cut -d' ' -f1)"
  printf '%s  bithuman-x86_64-unknown-linux-gnu.tar.gz\n' "$C7_LNX2" > "$C7D/bithuman-x86_64-unknown-linux-gnu.tar.gz.sha256"
  "$PY" - "$WORK/c7.json" "$WORK/c7mut.json" "$C7_LNX2" <<'MK7B'
import json, sys
m = json.load(open(sys.argv[1]))
A = {a["name"]: a for a in m["assets"]}
A["bithuman-x86_64-unknown-linux-gnu.tar.gz.sha256"]["body_text"] = sys.argv[3] + "  bithuman-x86_64-unknown-linux-gnu.tar.gz\n"
m["assets"] = list(A.values())
json.dump(m, open(sys.argv[2], "w"), indent=1)
MK7B
  if run_checks "$WORK/c7mut.json" "$C7D/good.rb" "$C7D" 1; then
    echo "*** NOT CAUGHT — two builds accepted as one release"
    fails=$((fails+1))
  else
    got="$(tr '\n' ' ' < "$WORK/failed")"
    if [[ " $got " == *" C7 "* ]]; then
      echo "REFUSED on C7 — correct check fired (failed: $got)"
    else
      echo "*** REFUSED on the WRONG check: $got"
      fails=$((fails+1))
    fi
  fi

  echo
  echo "=============================================================="
  echo "MUTATION: reproducible packing BLINDS C7 — C8 must see it"
  echo "=============================================================="
  # ★THE POINT OF THESE ARMS. Every member below carries the SAME fixed mtime,
  # exactly as a reproducible pack produces, so C7 measures 0.00 h spread and
  # PASSES on all three. The only thing that differs is the stamp inside the
  # binary. If C8 ever goes quiet, these arms go green with a release built
  # from two trees — which is the defect the whole file exists for.
  C8D="$WORK/c8"; mkdir -p "$C8D/src"
  C8_A=$(printf 'a%.0s' $(seq 1 40) | tr 'a' '1')
  C8_B=$(printf 'b%.0s' $(seq 1 40) | tr 'b' '2')
  mk8() { # <out.tar.gz> <commit-or-empty>
    if [[ -n "$2" ]]; then
      printf 'noise%sBITHUMAN-PROV' "$(head -c 2000 /dev/zero | tr '\0' 'x')" > "$C8D/src/bithuman"
      printf 'ENANCE-V1{"product":"bithuman-cli","commit":"%s","dirty":"false","target":"t"}END-BITHUMAN-PROVENANCE\n' "$2" >> "$C8D/src/bithuman"
      printf '{"commit":"%s","dirty":"false","target":"t"}\n' "$2" > "$C8D/src/PROVENANCE.json"
    else
      head -c 2000 /dev/zero | tr '\0' 'x' > "$C8D/src/bithuman"
      rm -f "$C8D/src/PROVENANCE.json"
    fi
    # ★ the member must be over C8's 1 MiB "this is the binary" threshold
    head -c 1200000 /dev/zero | tr '\0' 'z' >> "$C8D/src/bithuman"
    tar --sort=name --owner=0 --group=0 --numeric-owner --mtime='@1788400000' \
        --format=gnu -cf - -C "$C8D/src" . 2>/dev/null | gzip -9 -n > "$1"
  }
  mkman8() { # <dir> <manifest-out> <formula-out>
    local d="$1" out="$2" rb="$3" ms ls
    ms="$(sha256sum "$d/bithuman-aarch64-apple-darwin.tar.gz" | cut -d' ' -f1)"
    ls="$(sha256sum "$d/bithuman-x86_64-unknown-linux-gnu.tar.gz" | cut -d' ' -f1)"
    printf '%s  bithuman-aarch64-apple-darwin.tar.gz\n' "$ms" > "$d/bithuman-aarch64-apple-darwin.tar.gz.sha256"
    printf '%s  bithuman-x86_64-unknown-linux-gnu.tar.gz\n' "$ls" > "$d/bithuman-x86_64-unknown-linux-gnu.tar.gz.sha256"
    "$PY" - "$out" "$ms" "$ls" <<'MK8'
import json, sys
out, mac, lnx = sys.argv[1], sys.argv[2], sys.argv[3]
def a(n, s, body=None):
    d = {"name": n, "size": s, "created_at": "2026-09-03T11:50:00Z",
         "updated_at": "2026-09-03T11:50:00Z"}
    if body is not None: d["body_text"] = body
    return d
json.dump({"tag_name": "cli-v9.9.9", "draft": False,
           "published_at": "2026-09-03T12:00:00Z",
           "assets": [
             a("bithuman-aarch64-apple-darwin.tar.gz", 1200000),
             a("bithuman-aarch64-apple-darwin.tar.gz.sha256", 103,
               f"{mac}  bithuman-aarch64-apple-darwin.tar.gz\n"),
             a("bithuman-x86_64-unknown-linux-gnu.tar.gz", 1200000),
             a("bithuman-x86_64-unknown-linux-gnu.tar.gz.sha256", 107,
               f"{lnx}  bithuman-x86_64-unknown-linux-gnu.tar.gz\n"),
           ]}, open(out, "w"), indent=1)
MK8
    { echo 'class BithumanCli < Formula'
      echo '  url "https://github.com/bithuman-product/homebrew-bithuman/releases/download/cli-v9.9.9/bithuman-aarch64-apple-darwin.tar.gz"'
      echo "  sha256 \"$ms\""
      echo 'end'; } > "$rb"
  }
  REQUIRED_TARBALLS=(
    "bithuman-aarch64-apple-darwin.tar.gz:1"
    "bithuman-x86_64-unknown-linux-gnu.tar.gz:1"
  )

  # ── control: one tree, reproducibly packed ────────────────────────────────
  mk8 "$C8D/bithuman-aarch64-apple-darwin.tar.gz"     "$C8_A"
  mk8 "$C8D/bithuman-x86_64-unknown-linux-gnu.tar.gz" "$C8_A"
  mkman8 "$C8D" "$WORK/c8ok.json" "$C8D/ok.rb"
  if run_checks "$WORK/c8ok.json" "$C8D/ok.rb" "$C8D" 1; then
    echo "  ★one-tree control: PASS (C8 is not red on a correct release)"
  else
    echo "*** one-tree control FAILED — C8 refuses a correct release: $(tr '\n' ' ' < "$WORK/failed")"
    fails=$((fails+1))
  fi

  # ── mutation A: two trees, identical mtimes ───────────────────────────────
  mk8 "$C8D/bithuman-x86_64-unknown-linux-gnu.tar.gz" "$C8_B"
  mkman8 "$C8D" "$WORK/c8two.json" "$C8D/two.rb"
  if run_checks "$WORK/c8two.json" "$C8D/two.rb" "$C8D" 1; then
    echo "*** NOT CAUGHT — two SOURCE TREES accepted as one release"
    fails=$((fails+1))
  else
    got="$(tr '\n' ' ' < "$WORK/failed")"
    if [[ " $got " == *" C8 "* && " $got " != *" C7 "* ]]; then
      echo "REFUSED on C8 alone — and C7 was silent, which is the whole point (failed: $got)"
    elif [[ " $got " == *" C8 "* ]]; then
      echo "REFUSED on C8 (failed: $got)"
    else
      echo "*** REFUSED on the WRONG check: $got"
      fails=$((fails+1))
    fi
  fi

  # ── mutation B: no stamp at all — the state of every release to date ──────
  mk8 "$C8D/bithuman-aarch64-apple-darwin.tar.gz"     ""
  mk8 "$C8D/bithuman-x86_64-unknown-linux-gnu.tar.gz" ""
  mkman8 "$C8D" "$WORK/c8non.json" "$C8D/non.rb"
  if run_checks "$WORK/c8non.json" "$C8D/non.rb" "$C8D" 1; then
    echo "*** NOT CAUGHT — an artifact that cannot name its own tree was accepted"
    fails=$((fails+1))
  else
    got="$(tr '\n' ' ' < "$WORK/failed")"
    if [[ " $got " == *" C8 "* ]]; then
      echo "REFUSED on C8 — an unstamped asset may not be published (failed: $got)"
    else
      echo "*** REFUSED on the WRONG check: $got"
      fails=$((fails+1))
    fi
  fi

  echo
  echo "=============================================================="
  echo "DRAFT GATE truth table (the decision the workflow makes)"
  echo "=============================================================="
  #        state    require_draft   expected
  while read -r state require expect; do
    out="$(draft_verdict "$state" "$require" 2>&1)"; got=$?
    verdict=$(( got == 0 ? 0 : 1 ))
    if [[ "$verdict" == "$expect" ]]; then
      printf '  state=%-8s require=%-5s -> %s  OK\n' "$state" "$require" \
        "$( ((verdict==0)) && echo ALLOW || echo REFUSE)"
    else
      printf '  state=%-8s require=%-5s -> %s  *** WRONG (expected %s)\n' \
        "$state" "$require" "$( ((verdict==0)) && echo ALLOW || echo REFUSE)" \
        "$( [[ $expect == 0 ]] && echo ALLOW || echo REFUSE)"
      echo "$out" | sed 's/^/      /'
      fails=$((fails+1))
    fi
  done <<'TT'
missing true  1
missing false 1
true    true  0
true    false 0
false   true  1
false   false 0
banana  true  1
TT

  echo
  if (( fails )); then
    echo "SELF-TEST: FAIL — $fails control(s)/mutation(s) behaved wrongly"
    exit 1
  fi
  echo "SELF-TEST: PASS — baseline green, 11 mutations each refused on their own check,"
  echo "                  draft-gate truth table 7/7"
  exit 0
fi

# ---------------------------------------------------------------------------
# LIVE MODE
# ---------------------------------------------------------------------------
if [[ -z "$MANIFEST" ]]; then
  [[ -n "$TAG" ]] || { echo "usage: $0 <cli-vX.Y.Z> | --manifest F | --self-test" >&2; exit 3; }
  command -v gh >/dev/null 2>&1 || { echo "FATAL: no gh — cannot read the release" >&2; exit 3; }
  MANIFEST="$WORK/live.json"
  # ★A DRAFT HAS NO TAG, AND THIS GATE'S WHOLE JOB IS TO GRADE A DRAFT.
  # MEASURED 2026-09-10 while cutting cli-v2.6.5: `gh api
  # repos/OWNER/REPO/releases/tags/cli-v2.6.5` answers **404** for a release
  # that exists as a DRAFT — GitHub's get-release-by-tag resolves a real git
  # tag, and a draft has not created one yet. The list endpoint sees it
  # (`draft:true, tag_name:"cli-v2.6.5"`), and the published cli-v2.6.4
  # answers the tags endpoint fine, so this is about draftness and nothing
  # else. The procedure this file documents in its own header is
  # "create as a DRAFT -> upload every asset -> RUN THIS -> publish", so
  # every honest use of live mode hit the one lookup that cannot see the
  # subject: the gate could only ever be run AFTER the irreversible half.
  # So the tag lookup is tried first (cheapest, and the right answer for a
  # published release) and the LIST is the fallback that can see a draft.
  # A miss in both is still FATAL — never a silent pass.
  if ! gh api "repos/${REPO}/releases/tags/${TAG}" > "$MANIFEST" 2>"$WORK/gherr"; then
    if ! gh api --paginate "repos/${REPO}/releases" --jq \
           "[.[] | select(.tag_name==\"${TAG}\")] | .[0] // empty" \
           > "$WORK/live_draft.json" 2>>"$WORK/gherr" \
       || [[ ! -s "$WORK/live_draft.json" ]]; then
      echo "FATAL: could not read ${REPO} release ${TAG} (neither by tag nor in the release list):" >&2
      sed 's/^/  /' "$WORK/gherr" >&2
      exit 3
    fi
    cp "$WORK/live_draft.json" "$MANIFEST"
    echo "note: ${TAG} is not resolvable by tag (a DRAFT has no git tag) — read from the release list"
  fi
  # Sidecars are ~107 bytes — fetch their CONTENT so C3/C4 are real checks
  # rather than "the file exists". Without this they would report "content
  # not available", which is a fail, not a silent skip.
  SC_DIR="$WORK/sidecars"; mkdir -p "$SC_DIR"
  for spec in "${REQUIRED_TARBALLS[@]}"; do
    name="${spec%%:*}"
    gh release download "$TAG" --repo "$REPO" --pattern "${name}.sha256" \
       --dir "$SC_DIR" --clobber >/dev/null 2>&1 || true
  done
  [[ -n "$ASSETS" ]] || ASSETS="$SC_DIR"
fi

echo "=== release atomicity — ${TAG:-$MANIFEST}"
if run_checks "$MANIFEST" "$FORMULA" "${ASSETS:--}" "$VERIFY_BYTES"; then
  echo "OVERALL: PASS — safe to publish / already consistent"
  exit 0
fi
echo "OVERALL: FAIL — DO NOT PUBLISH."
echo "  Assemble releases as a DRAFT: create with --draft, upload every asset,"
echo "  re-run this, then \`gh release edit <tag> --draft=false\`. A draft is"
echo "  invisible to brew and to anonymous downloads, so there is no window."
exit 1
