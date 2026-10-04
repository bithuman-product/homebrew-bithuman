#!/usr/bin/env bash
# Local CI for bithuman-product/homebrew-bithuman.
# GitHub Actions is removed from this org (owner directive 2026-09-29); this
# script runs locally what the PR/push workflows used to grade. The old YAML is
# the recipe: ci/github-workflows-disabled/ (ci/wf-step.py replays a job from it).
# See ci/README.md for the evidence convention.
set -euo pipefail
ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT"
WF="python3 ci/wf-step.py ci/github-workflows-disabled"

# name | heavy(1=cap) | required tools | description | command
STEPS=(
  "no-large-files|0|git|no blob over 10 MB in origin/main..HEAD (no-large-files.yml)|BASE_REF=\${BASE_REF:-main} $WF/no-large-files.yml size-check"
  "apple-engine-pin|0|git|one engine tag on both Apple paths + negative control (apple-engine-pin.yml)|$WF/apple-engine-pin.yml pin"
  "manifest-truth|0|python3 strings curl|formula licence + Package.swift vs shipped binaries + mutation proof (manifest-truth.yml)|$WF/manifest-truth.yml manifest-truth"
  "public-vocabulary|0|python3|no internal vocabulary in the tracked tree (public-vocabulary.yml:vocabulary)|$WF/public-vocabulary.yml vocabulary"
  "platform-guards|0|python3|bare #if os(macOS) states its reason + control (plugin-platform-guards.yml:guards)|$WF/plugin-platform-guards.yml guards"
  "android-coordinates|0|python3 curl|pinned Android coordinates + transitive deps served by their home (ai.bithuman: maven.bithuman.ai; else Central) + controls (plugin-platform-guards.yml)|$WF/plugin-platform-guards.yml android-coordinates-on-central"
  "dev-levers|0|python3|dev levers go through their door + controls (plugin-platform-guards.yml:dev-levers)|$WF/plugin-platform-guards.yml dev-levers"
  "voice-render-edge-dart|0|python3|Dart voice module does not import render + controls (plugin-platform-guards.yml)|$WF/plugin-platform-guards.yml voice-render-edge-dart"
  "latest-badge-selftest|0|python3|Latest-badge detector can refuse, no network (latest-badge.yml, --selftest only)|python3 tools/verify_latest_badge.py --selftest"
  "release-coverage|0|python3 curl|newest CLI release carries every platform (release-coverage.yml:coverage)|$WF/release-coverage.yml coverage"
  "formula-pin-anonymous|0|python3 curl|formula asset anonymously fetchable + mutation proof (release-coverage.yml)|$WF/release-coverage.yml formula-pin-is-anonymously-fetchable"
  "installer-self-test|0|sh curl|install.sh --self-test live arms against downloads.bithuman.ai (release-coverage.yml)|$WF/release-coverage.yml installer-self-test"
  "installer-offline|0|sh tar|install.sh origin + mirror + error handling, offline; no host but the origin/mirror is ever asked (tests/install-sh-*.sh)|sh tests/install-sh-mirror.sh && sh tests/install-sh-download-errors.sh"
  "installer-ps1-offline|0|pwsh python3|install.ps1 retry helper, offline (tests/install-ps1-download-errors.ps1)|pwsh -NoProfile -File tests/install-ps1-download-errors.ps1"
  "installer-ps1-resolution|0|pwsh python3|install.ps1 end to end, offline: latest.json -> releases.json -> mirror order (tests/install-ps1-resolution.ps1)|pwsh -NoProfile -File tests/install-ps1-resolution.ps1"
  "downloads-publish-selftest|0|python3|the publish wrapper: cli-v* only for latest.json, refusals map to exit 1, no publisher is exit 2 (scripts/downloads-publish.py)|python3 scripts/downloads-publish.py --self-test"
  "flutter-plugin-tests|1|flutter|flutter plugin census + flutter test (flutter-plugin-tests.yml)|$WF/flutter-plugin-tests.yml plugin"
)

# slower / scheduled / non-PR jobs that still run on this host (read-only)
FULL_STEPS=(
  "public-vocabulary-releases|0|python3|published release titles + notes carry no internal vocabulary (public-vocabulary.yml:releases; reads downloads.bithuman.ai releases.json, no credential)|$WF/public-vocabulary.yml releases"
)

MANUAL=(
  "dev-levers-release-arm   [macOS host] python3 ci/wf-step.py ci/github-workflows-disabled/plugin-platform-guards.yml dev-levers-release-arm   (./scripts/prove_dev_levers_release.sh + control)"
  "voice-render-edge        [macOS host] python3 ci/wf-step.py ci/github-workflows-disabled/plugin-platform-guards.yml voice-render-edge   (check_voice_render_edge.sh, prove_lipsync_sink_headless.sh + controls)"
  "swift-package            [macOS 26 + Xcode] swift build --disable-keychain && swift test --disable-keychain   (swift-package.yml)"
  "flutter-plugin-android-unit [Android SDK + a Flutter app that depends on the plugin] packages/flutter-plugin/scripts/test_android_unit.sh <app dir>   (JVM unit tests: EngineUsersTest)"
  "latest-badge --heal      [WRITES latest.json on downloads.bithuman.ai; bucket credentials] python3 tools/verify_latest_badge.py --heal   (latest-badge.yml; run only after a release)"
  "preflight                [secret BITHUMAN_MODELS_SSH_KEY] probe the models deploy key: see preflight.yml"
  "release-pypi             [RELEASE; macOS+Linux x86_64+aarch64 hosts, docker, secrets BITHUMAN_MODELS_SSH_KEY PYPI_API_TOKEN] recipe: ci/github-workflows-disabled/release-pypi.yml; RELEASE.md"
  "publish-cli-wheel        [RELEASE; secret PYPI_API_TOKEN] sha256 pin check + twine check + twine upload dist/bithuman-cli/<wheel>   (publish-cli-wheel.yml)"
  "publish-mcp              [RELEASE; secret PYPI_API_TOKEN] cd packages/python-mcp && python -m build && twine upload dist/*   (publish-mcp.yml, tag mcp-v*)"
  "publish-pubdev           [RELEASE; pub.dev credentials] cd packages/flutter-plugin && no _unpackImxContainer in lib/ && dart pub publish   (publish-pubdev.yml, tag flutter-v*)"
  "publish-essence2-apple   [RELEASE; macOS host, bucket credentials] graded essence2-apple archives -> scripts/downloads-publish.py publish essence2-v<x> <files> (never latest.json)   (recipe: publish-essence2-apple.yml, still written for gh)"
)

# ---------------------------------------------------------------------------
# Runner (shared shape across bithuman-product repos). Nothing below needs
# editing to add a step: add a row to STEPS / FULL_STEPS / MANUAL above.
# ---------------------------------------------------------------------------
usage() {
  cat <<'USAGE'
usage: ci/run-local.sh [--list] [--only <step>]... [--full] [--no-cap] [--verbose]
  (default)      run the required PR suite (what the PR/push workflows graded)
  --list         print every step: default, --full, and manual (host/secret needed)
  --only <step>  run just this step (repeatable; works for --full steps too)
  --full         also run the slower / non-PR jobs that can run on this host
  --no-cap       do not wrap heavy steps in systemd-run MemoryMax=8G CPUQuota=400% nice 19
  --verbose      stream step output (default: log to a file, print its tail on FAIL)
USAGE
}

ONLY=(); FULL=0; CAP=1; LIST=0; VERBOSE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --list) LIST=1 ;;
    --only) shift; [ $# -gt 0 ] || { usage; exit 2; }; ONLY+=("$1") ;;
    --full) FULL=1 ;;
    --no-cap) CAP=0 ;;
    --verbose|-v) VERBOSE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

field() { printf '%s' "$1" | cut -d'|' -f"$2"; }

if [ "$LIST" = 1 ]; then
  echo "== default (required PR suite) =="
  for s in "${STEPS[@]}"; do printf '  %-28s %s\n' "$(field "$s" 1)" "$(field "$s" 4)"; done
  echo "== --full (slower / scheduled / non-PR, runnable here) =="
  if [ ${#FULL_STEPS[@]} -eq 0 ]; then echo "  (none)"; fi
  for s in "${FULL_STEPS[@]}"; do printf '  %-28s %s\n' "$(field "$s" 1)" "$(field "$s" 4)"; done
  echo "== manual (host/secret needed) — NOT run by this script =="
  if [ ${#MANUAL[@]} -eq 0 ]; then echo "  (none)"; fi
  for m in "${MANUAL[@]}"; do echo "  $m"; done
  exit 0
fi

SEL=("${STEPS[@]}")
if [ "$FULL" = 1 ]; then SEL+=("${FULL_STEPS[@]}"); fi
if [ ${#ONLY[@]} -gt 0 ]; then
  SEL=()
  for o in "${ONLY[@]}"; do
    hit=0
    for s in "${STEPS[@]}" "${FULL_STEPS[@]}"; do
      if [ "$(field "$s" 1)" = "$o" ]; then SEL+=("$s"); hit=1; fi
    done
    [ "$hit" = 1 ] || { echo "no such step: $o (see --list)" >&2; exit 2; }
  done
fi

SHA=$(git rev-parse HEAD)
LOGDIR=${LOCAL_CI_LOG_DIR:-${TMPDIR:-/tmp}/local-ci-$(basename "$ROOT")-${SHA:0:12}}
mkdir -p "$LOGDIR"
DIRTY=$(git status --porcelain --untracked-files=no | head -1 || true)
[ -z "$DIRTY" ] || echo "WARNING: tracked files are modified — this run does not grade sha=$SHA exactly" >&2

capwrap() {
  if [ "$CAP" = 1 ] && command -v systemd-run >/dev/null 2>&1 \
     && systemd-run --user --scope -q true >/dev/null 2>&1; then
    systemd-run --user --scope -q -p MemoryMax=8G -p MemorySwapMax=0 -p CPUQuota=400% \
      nice -n 19 "$@"
  else
    "$@"
  fi
}

N=0; NFAIL=0; SKIPPED=(); RESULTS=()
for s in "${SEL[@]}"; do
  name=$(field "$s" 1); heavy=$(field "$s" 2); tools=$(field "$s" 3); cmd=$(field "$s" 5-)
  missing=""
  for t in $tools; do command -v "$t" >/dev/null 2>&1 || missing="$missing $t"; done
  if [ -n "$missing" ]; then
    line="SKIP $name (not installed here:$missing — run it on a host that has it)"
    echo "$line"; SKIPPED+=("$name"); RESULTS+=("$line"); continue
  fi
  N=$((N + 1)); log="$LOGDIR/$name.log"; t0=$(date +%s)
  echo ">> $name" >&2
  set +e
  if [ "$heavy" = 1 ]; then
    if [ "$VERBOSE" = 1 ]; then capwrap bash -c "cd \"$ROOT\" && $cmd" 2>&1 | tee "$log"; rc=${PIPESTATUS[0]}
    else capwrap bash -c "cd \"$ROOT\" && $cmd" >"$log" 2>&1; rc=$?; fi
  else
    if [ "$VERBOSE" = 1 ]; then bash -c "cd \"$ROOT\" && $cmd" 2>&1 | tee "$log"; rc=${PIPESTATUS[0]}
    else bash -c "cd \"$ROOT\" && $cmd" >"$log" 2>&1; rc=$?; fi
  fi
  set -e
  dt=$(( $(date +%s) - t0 ))
  if [ "$rc" = 0 ]; then line="PASS $name (${dt}s)"
  else line="FAIL $name rc=$rc (${dt}s) log=$log"; NFAIL=$((NFAIL + 1))
    [ "$VERBOSE" = 1 ] || { echo "---- tail $log ----"; tail -25 "$log"; echo "----"; }
  fi
  echo "$line"; RESULTS+=("$line")
  # a step must not leave the tree dirty (negative controls restore what they mutate)
  if [ -z "$DIRTY" ] && [ -n "$(git status --porcelain --untracked-files=no | head -1)" ]; then
    echo "FAIL $name left tracked files modified:"; git status --short --untracked-files=no | head
    NFAIL=$((NFAIL + 1)); git checkout -- . 2>/dev/null || true
  fi
done

echo
echo "== summary =="
for r in "${RESULTS[@]}"; do echo "$r"; done
[ ${#SKIPPED[@]} -eq 0 ] || echo "skipped (toolchain missing on this host): ${SKIPPED[*]}"
if [ "$NFAIL" = 0 ] && [ "$N" -gt 0 ]; then
  echo "LOCAL CI PASS sha=$SHA steps=$N"; exit 0
else
  echo "LOCAL CI FAIL sha=$SHA steps=$N"; exit 1
fi
