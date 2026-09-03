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
#   touching a published release.
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
import hashlib, json, os, re, sys
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
  echo "SELF-TEST: PASS — baseline green, 8 mutations each refused on their own check,"
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
  if ! gh api "repos/${REPO}/releases/tags/${TAG}" > "$MANIFEST" 2>"$WORK/gherr"; then
    echo "FATAL: could not read ${REPO} release ${TAG}:" >&2
    sed 's/^/  /' "$WORK/gherr" >&2
    exit 3
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
