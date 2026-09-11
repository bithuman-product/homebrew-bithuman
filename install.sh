#!/bin/sh
#
# bithuman CLI installer.
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/bithuman-product/homebrew-bithuman/main/install.sh | sh
#
# Once install.bithuman.ai DNS is configured (Cloudflare Worker / page rule
# redirect to the raw URL above), the same script is reachable via:
#   curl -sSL install.bithuman.ai | sh
#
# Environment overrides:
#   BITHUMAN_VERSION         Pin a specific version (default: latest GitHub release tag).
#                            ★WITH THE PIPED USAGE ABOVE, THE ASSIGNMENT GOES ON THE
#                            `sh` SIDE OF THE PIPE, not at the front of the line:
#                              curl -sSL <this script> | BITHUMAN_VERSION=cli-vX.Y.Z sh
#                            (the printed hints name the raw URL, not install.bithuman.ai:
#                             that vanity host STILL DOES NOT RESOLVE -- measured NXDOMAIN
#                             2026-09-11 -- so a hint naming it strands the reader twice.
#                             See INSTALL_BITHUMAN_AI_DNS.md; swap the hints back when the
#                             DNS lands and the self-test arm below will keep them honest.)
#                            `BITHUMAN_VERSION=... curl ... | sh` sets the variable for CURL;
#                            the installer never sees it and silently resolves "latest"
#                            instead -- which is exactly what has already failed whenever
#                            this hint gets printed.
#   BITHUMAN_INSTALL_DIR     Install location (default: ~/.local/bin, or
#                            /usr/local/bin if running as root).
#   BITHUMAN_NO_MODIFY_PATH  Set to 1 to suppress the PATH hint at the end.
#
# Re-installs are idempotent. To uninstall:
#   rm -rf <install_dir>/bithuman <install_dir>/lib
#
# Source binaries live in this tap's own GitHub releases:
#   https://github.com/bithuman-product/homebrew-bithuman/releases

set -eu

GITHUB_REPO="bithuman-product/homebrew-bithuman"

# ----- helpers ---------------------------------------------------------------

err() { printf '%s\n' "install: error: $*" >&2; }
info() { printf 'install: %s\n' "$*"; }

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    err "missing required command: $1"
    exit 1
  fi
}

# Portable EUID detection (set -u safe).
current_uid() {
  if [ -n "${EUID:-}" ]; then
    printf '%s' "$EUID"
  else
    id -u
  fi
}

# ----- prerequisites ---------------------------------------------------------

need_cmd curl
need_cmd tar
need_cmd uname
need_cmd mktemp

# ----- ★ does a release actually CARRY a target? -----------------------------
#
# It did not, for aarch64 Linux, for seven weeks. MEASURED 2026-09-04 by
# fetching every URL this script would build:
#
#   tag          aarch64-unknown-linux-gnu   x86_64-unknown-linux-gnu   aarch64-apple-darwin
#   cli-v2.5.1   404                         200                        200
#   cli-v2.5.0   404                         200                        200
#   cli-v2.4.2   404                         200                        200
#   cli-v2.3.27  200                         200                        200
#
# The platform block below happily produces `aarch64-unknown-linux-gnu` on any
# arm64 Linux box — Graviton, Ampere, a Pi, an arm64 container on an Apple
# laptop — because nothing here ever knew which targets a release carries. It
# built the URL, curl 404'd, and the user was told "download failed … may not be
# published": that reads like a network problem, and it names neither what IS
# published nor what to do instead.
#
# So ASK THE RELEASE. One request, the same API the tag lookup already uses.
# This makes advertising a target that does not exist structurally impossible
# rather than a hand-maintained list that drifts out of date.
#
# ★ AND IT SKIPS RATHER THAN PASSES when it cannot read the list: an installer
# that stops working because GitHub rate-limited an anonymous request would be a
# worse defect than the one being fixed. Skipped is reported, not swallowed.

assets_for_tag() {
  # $1 = tag. Prints one tarball asset name per line. No output = could not read.
  #
  # ★ `|| true` is not defensive noise. This script runs under `set -eu`, and
  # BOTH `curl -f` on a tag that does not exist AND `grep` matching nothing exit
  # non-zero — so without it the SKIP path kills the installer instead of
  # skipping, which is the precise failure the check was added to avoid. That is
  # not a hypothetical: the first version of this function did exactly that, and
  # `--self-test`'s fifth arm (a tag that cannot exist) is what caught it.
  curl -fsSL "https://api.github.com/repos/${GITHUB_REPO}/releases/tags/$1" 2>/dev/null \
    | grep '"name"' \
    | sed -e 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' \
    | grep '^bithuman-.*\.tar\.gz$' || true
}

# target_availability <tag> <tarball-name>
#   prints  OK      the release carries it
#           MISSING the release exists and does NOT carry it
#           SKIP    the asset list could not be read
target_availability() {
  _avail=$(assets_for_tag "$1" || true)
  if [ -z "$_avail" ]; then
    printf 'SKIP\n'
  elif printf '%s\n' "$_avail" | grep -qx "$2"; then
    printf 'OK\n'
  else
    printf 'MISSING\n'
  fi
}

# ----- ★ is a tag a REAL release, or a pre-release / draft? -------------------
#
# MEASURED 2026-09-11 against the live API. `GET /releases` is NOT ordered by
# version, and it carries pre-releases inline with no distinction the old
# `grep '"tag_name"' | head -1` could see. Worse than "wrong order": the order
# is not STABLE. A scratch repository holding exactly two releases returned them
# in BOTH orders on successive anonymous fetches minutes apart, so the old line
# was a coin flip, and two developers running the same documented one-liner at
# the same minute could get different bytes.
# The list on that date began:
#
#   tag              draft  prerelease  created_at
#   v2.6.1           false  false       2026-09-11T05:18Z
#   essence2-v1.5.1  false  false       2026-09-11T06:03Z
#   cli-v2.6.7       false  false       2026-09-11T07:24Z   <- the real Latest
#   cli-v2.6.6       false  TRUE        2026-09-11T03:51Z
#   cli-v2.6.5       false  TRUE        2026-09-09T09:07Z
#
# Two defects in one line, and they compound:
#
#  1. PRE-RELEASES WERE ELIGIBLE. The press lane marks a SUPERSEDED release as
#     pre-release as standing practice (the owner's trim ruling), so this repo
#     will always carry pre-release `cli-v*` tags — and it only takes one whose
#     tag commit is newer than the current release's for `head -1` to hand every
#     `curl | sh` developer bytes that Homebrew users, pinned by the formula,
#     never see. Two populations, one documented instruction, different bytes.
#  2. "NEWEST" WAS NEVER VERSION ORDER. `cli-v2.6.7` sits BELOW `v2.6.1` in the
#     response above. Any ordering that depends on when a tag's commit was
#     authored is not an ordering over versions.
#
# So: take every `cli-v*` candidate, sort by SEMVER (POSIX numeric field sort —
# `sort -V` is not on macOS), and walk down asking each one whether it is a real
# release. `draft` and `prerelease` appear ONLY at the top level of a release
# object — an asset carries name/label/state/size/created_at, and the uploader
# carries login/id/type, but neither carries either of these keys — so a plain
# grep of a SINGLE release object is exact, where a grep of the whole list is
# not.
#
# ★ AND IT REFUSES RATHER THAN GUESSES. If no candidate can be confirmed a real
# release, this exits with the BITHUMAN_VERSION escape hatch named. Installing
# an unverified pre-release because the API was unreadable is the exact defect
# being fixed; a clear refusal is not.

release_state() {
  # $1 = tag. Prints RELEASE | PRERELEASE | DRAFT | UNKNOWN.
  _meta=$(curl -fsSL "https://api.github.com/repos/${GITHUB_REPO}/releases/tags/$1" 2>/dev/null || true)
  [ -z "$_meta" ] && { printf 'UNKNOWN\n'; return 0; }
  _draft=$(printf '%s\n' "$_meta" | grep -m1 '"draft"' \
    | sed -e 's/.*"draft"[[:space:]]*:[[:space:]]*\([a-z]*\).*/\1/')
  _pre=$(printf '%s\n' "$_meta" | grep -m1 '"prerelease"' \
    | sed -e 's/.*"prerelease"[[:space:]]*:[[:space:]]*\([a-z]*\).*/\1/')
  if [ "$_draft" != true ] && [ "$_draft" != false ]; then printf 'UNKNOWN\n'; return 0; fi
  if [ "$_pre"   != true ] && [ "$_pre"   != false ]; then printf 'UNKNOWN\n'; return 0; fi
  if [ "$_draft" = true ]; then printf 'DRAFT\n'; return 0; fi
  if [ "$_pre"   = true ]; then printf 'PRERELEASE\n'; return 0; fi
  printf 'RELEASE\n'
}

semver_desc() {
  # stdin: tags sharing one prefix ($1). stdout: same tags, newest semver first.
  # POSIX numeric field sort; `sort -V` does not exist on macOS.
  sed -e "s/^$1//" \
    | sed -e 's/^\([0-9][0-9]*\)$/\1.0.0/' -e 's/^\([0-9][0-9]*\.[0-9][0-9]*\)$/\1.0/' \
    | sort -t. -k1,1nr -k2,2nr -k3,3nr \
    | sed -e "s/^/$1/"
}

pick_latest_real_release() {
  # $1 = tag prefix ('cli-v' or 'v'). stdin: the full tag list.
  # Prints the newest tag under that prefix whose release is neither draft nor
  # pre-release. Prints nothing if there is none.
  _cands=$(grep "^$1[0-9]" || true)
  [ -z "$_cands" ] && return 0
  # `*-mac` is the Sparkle app feed and is never the CLI.
  _cands=$(printf '%s\n' "$_cands" | grep -v -- '-mac$' || true)
  [ -z "$_cands" ] && return 0
  _n=0
  for _t in $(printf '%s\n' "$_cands" | semver_desc "$1"); do
    _n=$((_n + 1))
    # Bound the walk: an anonymous caller gets 60 API requests an hour, and a
    # repo with a long pre-release tail must not burn them all here.
    [ "$_n" -gt 8 ] && break
    case "$(release_state "$_t")" in
      RELEASE) printf '%s\n' "$_t"; return 0 ;;
      *)       ;;
    esac
  done
  return 0
}

# ----- self-test -------------------------------------------------------------
# `sh install.sh --self-test`. A `curl | sh` never passes an argument, so this
# is unreachable on the install path. It is a LIVE probe against the real
# releases, and it is built so that a blind instrument fails it: the SAME target
# must come back MISSING on the release that dropped it and OK on the release
# that carries it, so "MISSING for everything" cannot pass.
if [ "${1:-}" = "--self-test" ]; then
  # ★NO RECURSION. The arms below re-run THIS FILE with a `uname` shim, and a
  # self-test that can re-enter itself is a fork bomb — this estate has built
  # one. The child is invoked with no arguments, so it can never reach here;
  # this refuses anyway, because "can never" is what the fork bomb also said.
  if [ -n "${BITHUMAN_INSTALL_SELFTEST_CHILD:-}" ]; then
    printf 'install.sh: refusing to self-test inside a self-test child\n' >&2
    exit 2
  fi
  _t_fail=0
  _t() { # <label> <tag> <asset> <expected>
    _got=$(target_availability "$2" "$3" || true)
    if [ "$_got" = "$4" ]; then
      printf '  PASS  %-58s %s\n' "$1" "$_got"
    else
      printf '  FAIL  %-58s got %s, want %s\n' "$1" "$_got" "$4"; _t_fail=1
    fi
  }
  printf 'install.sh --self-test  (live, against %s)\n' "$GITHUB_REPO"
  _t "cli-v2.5.1 has no aarch64 Linux"          cli-v2.5.1  bithuman-aarch64-unknown-linux-gnu.tar.gz MISSING
  _t "cli-v2.5.1 HAS x86_64 Linux (control)"    cli-v2.5.1  bithuman-x86_64-unknown-linux-gnu.tar.gz  OK
  _t "cli-v2.5.1 HAS arm64 macOS (control)"     cli-v2.5.1  bithuman-aarch64-apple-darwin.tar.gz      OK
  _t "cli-v2.3.27 HAS aarch64 Linux (★control)" cli-v2.3.27 bithuman-aarch64-unknown-linux-gnu.tar.gz OK
  _t "a tag that cannot exist -> SKIP not OK"   cli-v0.0.0-nope bithuman-x86_64-unknown-linux-gnu.tar.gz SKIP

  # ── ★THE RESOLVER MUST NEVER HAND A DEVELOPER A PRE-RELEASE ──────────────
  # The press lane marks a SUPERSEDED release as pre-release as standing
  # practice (the owner's trim ruling), so `cli-v*` pre-releases are a permanent
  # feature of this repo, not an accident. Before 2026-09-11 this script took
  # `grep '^cli-v' | head -1` of the API's own ordering, which carries
  # pre-releases inline and is NOT version order: on that date `cli-v2.6.7` sat
  # BELOW `v2.6.1` in the response, and the same two-release scratch repository
  # returned the two entries in BOTH orders on successive anonymous fetches.
  # So `head -1` was a coin flip that could land on a pre-release, and the
  # curl-installed population would then be running bytes the Homebrew
  # population — pinned by the formula — never sees.
  #
  # PROVEN on 2026-09-11 against a scratch repository whose only `cli-v*`
  # entries were pre-releases: the OLD script resolved `cli-v9.9.9`, a
  # PRE-RELEASE; this one refused. With a genuine `cli-v9.9.8` added, this one
  # selected it and skipped the higher-versioned pre-release above it.
  #
  # These arms re-run that against THIS repo's permanent history.
  _ts() { # <label> <tag> <expected-state>
    _got=$(release_state "$2" || true)
    if [ "$_got" = "$3" ]; then
      printf '  PASS  %-58s %s\n' "$1" "$_got"
    else
      printf '  FAIL  %-58s got %s, want %s\n' "$1" "$_got" "$3"; _t_fail=1
    fi
  }
  _ts "cli-v2.6.7 is a REAL release"            cli-v2.6.7      RELEASE
  _ts "★cli-v2.6.6 is a PRE-RELEASE"            cli-v2.6.6      PRERELEASE
  _ts "a tag that cannot exist -> UNKNOWN"      cli-v0.0.0-nope UNKNOWN

  # ★AND THE SELECTION ITSELF, not just the classifier. A resolver that reads
  # the state correctly and then ignores it is the defect wearing a passing
  # test, so this runs the real picker over the real list.
  _sel=$(printf '%s\n' "$(curl -fsSL "https://api.github.com/repos/${GITHUB_REPO}/releases?per_page=100" \
    | grep '"tag_name"' \
    | sed -e 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')" \
    | pick_latest_real_release 'cli-v' || true)
  if [ -z "$_sel" ]; then
    printf '  FAIL  %-58s resolved nothing\n' "the picker selects a cli-v* release"; _t_fail=1
  elif [ "$(release_state "$_sel")" = RELEASE ]; then
    printf '  PASS  %-58s %s\n' "★the picker selects a release, never a pre-release" "$_sel"
  else
    printf '  FAIL  %-58s picked %s which is %s\n' \
           "★the picker selects a release, never a pre-release" "$_sel" "$(release_state "$_sel")"; _t_fail=1
  fi

  # ★AND THE GUIDANCE ITSELF, GRADED ON THE RENDERED REFUSAL — not on the
  # source text. DISTRIBUTION-SURFACE.md §5a's finding was that the
  # aarch64-Linux refusal named an x86_64 host, an old pin and an email, but
  # NOT the channel that serves that platform today. A text fix nothing grades
  # regresses silently.
  #
  # ★AND IT MUST GRADE THE OUTPUT, BECAUSE GRADING THE SOURCE WAS BLIND — twice,
  # measured. A `grep` for the sentence in this file matched its OWN call site;
  # assembling the pattern from halves fixed that, and then it matched the
  # explanatory COMMENT beside the fix, so deleting the actual `err` line still
  # passed. Two blind versions in a row, both caught by mutation. So this runs
  # the installer under a `uname` shim and reads what a developer would see.
  _st_tmp=$(mktemp -d 2>/dev/null || mktemp -d -t 'bithuman-selftest')
  mkdir -p "$_st_tmp/shim" "$_st_tmp/bin"
  _mkshim() { # <machine>
    cat > "$_st_tmp/shim/uname" <<SHIM
#!/bin/sh
case "\${1:-}" in
  -s) echo Linux ;;
  -m) echo $1 ;;
  *)  echo Linux ;;
esac
SHIM
    chmod 755 "$_st_tmp/shim/uname"
  }
  # ★PROVE THE INSTRUMENT FIRES: the shim must change what `uname -m` says.
  # If this host already reports aarch64 the shim is indistinguishable, and
  # the honest answer is SKIP — not a pass.
  _mkshim aarch64
  _real_m=$(uname -m)
  _shim_m=$(PATH="$_st_tmp/shim:$PATH" uname -m)
  if [ "$_shim_m" != aarch64 ]; then
    printf '  FAIL  %-58s shim did not fire (got %s)\n' "uname shim is reachable" "$_shim_m"; _t_fail=1
  elif [ "$_real_m" = aarch64 ]; then
    printf '  SKIP  %-58s host is already aarch64\n' "uname shim is reachable"
  else
    printf '  PASS  %-58s %s -> %s\n' "★uname shim is reachable" "$_real_m" "$_shim_m"
  fi

  _pat_ok="pip install bit""human"
  _run_child() { # <machine>  -> prints the installer's own stderr+stdout
    _mkshim "$1"
    PATH="$_st_tmp/shim:$PATH" \
      BITHUMAN_INSTALL_DIR="$_st_tmp/bin" \
      BITHUMAN_INSTALL_SELFTEST_CHILD=1 \
      sh "$0" 2>&1 || true
  }
  _out_arm=$(_run_child aarch64)
  case "$_out_arm" in
    *"$_pat_ok"*)
      printf '  PASS  %-58s FOUND\n' "aarch64-Linux refusal NAMES the channel that serves it" ;;
    *)
      printf '  FAIL  %-58s the rendered refusal does not name it\n' \
             "aarch64-Linux refusal NAMES the channel that serves it"; _t_fail=1 ;;
  esac
  # ★THE NEAR-TWIN CONTROL: an architecture we serve nowhere must NOT be told
  # to `pip install bithuman`. If it were, the arm above would be passing on a
  # sentence this script prints unconditionally.
  _out_ctl=$(_run_child riscv64)
  case "$_out_ctl" in
    *"$_pat_ok"*)
      printf '  FAIL  %-58s it is printed unconditionally\n' \
             "★control: an unserved arch is NOT sent to that channel"; _t_fail=1 ;;
    *"unsupported architecture"*)
      printf '  PASS  %-58s ABSENT\n' "★control: an unserved arch is NOT sent to that channel" ;;
    *)
      printf '  FAIL  %-58s the control arm did not refuse at all\n' \
             "★control: an unserved arch is NOT sent to that channel"; _t_fail=1 ;;
  esac
  # ── ★EVERY PRINTED `BITHUMAN_VERSION` HINT MUST ACTUALLY PIN ─────────────
  # MEASURED 2026-09-11 on the published script: the escape hatch this file
  # printed was `BITHUMAN_VERSION=cli-vX.Y.Z curl -sSL install.bithuman.ai | sh`.
  # In that form the assignment binds to CURL, not to the `sh` that runs the
  # installer, so the pin never arrived and the script silently resolved
  # "latest" -- the one thing that had just failed, since this hint is printed
  # only when resolution failed. Proved in a clean container: the printed form
  # installed cli-v2.6.7 while asking for cli-v2.3.27; `| BITHUMAN_VERSION=... sh`
  # installed cli-v2.3.27.
  #
  # ★GRADED BY EXECUTION, NOT BY READING. Every hint line is pulled out of this
  # file and RUN with `sh` replaced by a shim that reports what reached it, so a
  # rewrite into some other broken form fails here too. The count arm means
  # deleting the hints cannot pass either.
  cat > "$_st_tmp/bin/shpin" <<'SHPIN'
#!/bin/sh
printf '%s\n' "${BITHUMAN_VERSION:-<UNSET>}"
SHPIN
  chmod +x "$_st_tmp/bin/shpin"
  # Assemble the pattern from halves so it cannot match its own call site.
  _st_self="$0"
  _hint_pat="BITHUMAN_"$(printf 'VERSION')"=cli-v"
  _hints=$(grep -n "err \"" "$_st_self" 2>/dev/null | grep -- "$_hint_pat" \
           | sed -e 's/^[0-9]*: *err "//' -e 's/"$//' -e 's/^ *//' -e 's/\\`/`/g')
  _hint_n=$(printf '%s\n' "$_hints" | grep -c . || true)
  if [ "${_hint_n:-0}" -lt 2 ]; then
    printf '  FAIL  %-58s found %s, want >= 2\n' \
           "★the pin hints are still printed at all" "${_hint_n:-0}"; _t_fail=1
  else
    printf '  PASS  %-58s %s\n' "★the pin hints are still printed at all" "$_hint_n"
  fi
  printf '%s\n' "$_hints" | while IFS= read -r _hint; do
    [ -n "$_hint" ] || continue
    case "$_hint" in *"|"*" sh") ;; *) continue ;; esac
    # Run the hint verbatim with the real fetch replaced by a local cat and the
    # trailing `sh` replaced by the reporting shim.
    _cmd=$(printf '%s' "$_hint" \
           | sed -e "s#curl -sSL [^ |]*#cat '$_st_self'#" -e 's# sh$# shpin#')
    _got=$(PATH="$_st_tmp/bin:$PATH" sh -c "$_cmd" 2>/dev/null | head -1)
    _want=$(printf '%s' "$_hint" | sed -n "s/.*$_hint_pat\([^ ]*\).*/cli-v\1/p")
    if [ -n "$_got" ] && [ "$_got" = "$_want" ]; then
      printf '  PASS  %-58s %s\n' "★a printed pin hint really pins" "$_got"
    else
      printf '  FAIL  %-58s the hint `%s` delivered %s, want %s\n' \
             "★a printed pin hint really pins" "$_hint" "${_got:-<nothing>}" "$_want"
      echo fail > "$_st_tmp/hintfail"
    fi
  done
  [ -f "$_st_tmp/hintfail" ] && _t_fail=1

  rm -rf "$_st_tmp"

  if [ "$_t_fail" = 0 ]; then
    printf 'SELF-TEST PASSED: the same target is MISSING on cli-v2.5.1 and OK on cli-v2.3.27,\n'
    printf '                  so the check discriminates rather than refusing everything.\n'
    exit 0
  fi
  printf 'SELF-TEST FAILED\n'; exit 1
fi

# ----- platform detection ----------------------------------------------------

uname_s=$(uname -s)
uname_m=$(uname -m)

case "$uname_s" in
  Darwin) os="apple-darwin" ;;
  Linux)  os="unknown-linux-gnu" ;;
  *)
    err "unsupported operating system: $uname_s"
    err "supported: Darwin (macOS), Linux"
    exit 1
    ;;
esac

case "$uname_m" in
  arm64|aarch64) arch="aarch64" ;;
  x86_64|amd64)  arch="x86_64" ;;
  *)
    err "unsupported architecture: $uname_m"
    err "supported: arm64/aarch64, x86_64/amd64"
    exit 1
    ;;
esac

target="${arch}-${os}"

# ----- version resolution ----------------------------------------------------

version="${BITHUMAN_VERSION:-}"
if [ -z "$version" ]; then
  info "querying latest release..."
  # Tag taxonomy in this repo: the CLI publishes under `cli-v*`; the bare `v*`
  # namespace is reserved for the Swift SDK (SwiftPM-resolved); the Sparkle Mac
  # app uses `*-mac`. Prefer the newest `cli-v*` release; fall back to the newest
  # bare `v<semver>` CLI release (pre-migration tags like v2.3.25), and never the
  # `*-mac` app feed. Grep + sed is POSIX-portable; no jq dep.
  api_url="https://api.github.com/repos/${GITHUB_REPO}/releases?per_page=100"
  tags=$(curl -fsSL "$api_url" \
    | grep '"tag_name"' \
    | sed -e 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
  # ★ A PRE-RELEASE CAN NEVER BE SELECTED HERE. See release_state() above.
  version=$(printf '%s\n' "$tags" | pick_latest_real_release 'cli-v')
  [ -z "$version" ] && version=$(printf '%s\n' "$tags" | pick_latest_real_release 'v')
  if [ -z "$version" ]; then
    err "could not determine latest CLI release from $api_url"
    err ""
    err "  Every cli-v* candidate was a draft, a pre-release, or unreadable."
    err "  The installer does NOT fall back to a pre-release: a pre-release is"
    err "  bytes Homebrew users are not running, and the two populations follow"
    err "  the same instruction."
    err ""
    err "  If this box shares an egress IP with other machines, the likeliest"
    err "  cause is GitHub ANONYMOUS API budget exhaustion: 60 requests per"
    err "  hour per SOURCE ADDRESS, shared by everyone behind that address."
    err "  Resolving a version costs about three of them. Wait for the window"
    err "  to roll, or skip resolution entirely by pinning:"
    err ""
    err "      curl -sSL https://raw.githubusercontent.com/bithuman-product/homebrew-bithuman/main/install.sh | BITHUMAN_VERSION=cli-vX.Y.Z sh"
    err ""
    err "  Check the budget with:  curl -s https://api.github.com/rate_limit"
    err ""
    err "set BITHUMAN_VERSION on the \`sh\` side of the pipe (form above) to pin a release."
    exit 1
  fi
fi

info "version: $version"
info "target:  $target"

# ----- install location ------------------------------------------------------

install_dir="${BITHUMAN_INSTALL_DIR:-}"
if [ -z "$install_dir" ]; then
  if [ "$(current_uid)" = "0" ]; then
    install_dir="/usr/local/bin"
  else
    install_dir="$HOME/.local/bin"
  fi
fi

mkdir -p "$install_dir"
info "install dir: $install_dir"

# ----- download + extract ----------------------------------------------------

tarball_name="bithuman-${target}.tar.gz"
tarball_url="https://github.com/${GITHUB_REPO}/releases/download/${version}/${tarball_name}"

case "$(target_availability "$version" "$tarball_name")" in
  OK)   ;;
  SKIP) info "could not read $version's asset list (offline or rate-limited) — availability check SKIPPED, not passed" ;;
  *)
    err "the bithuman CLI is NOT published for $target."
    err ""
    err "  release : $version"
    err "  wanted  : $tarball_name"
    err "  release carries:"
    assets_for_tag "$version" | sed -e 's/^/install: error:     /' >&2
    err ""
    case "$target" in
      aarch64-unknown-linux-gnu)
        # ★THE FIRST OPTION IS THE ONE THAT ACTUALLY WORKS ON THIS MACHINE.
        # Until 2026-09-04 this block offered an x86_64 host, a pinned old
        # release, and an email address — and never mentioned that a supported
        # channel serves aarch64 Linux TODAY. `pip install bithuman` has the
        # broadest platform coverage in the estate and is the only channel that
        # carries this one. Telling a developer to change machines while we
        # ship a working package for the machine they have is the kind of
        # refusal that reads as "unsupported" when it means "use the other
        # door". DISTRIBUTION-SURFACE.md §5a / D-U3.
        err "  aarch64 Linux was published through cli-v2.3.27 and dropped at cli-v2.4.0,"
        err "  when the tarball began vendoring the expression-2 render engine and only an"
        err "  x86_64 Linux engine was built. Options, in order of preference:"
        err "    * ★USE THE PYTHON LIBRARY — it supports aarch64 Linux today:"
        err "          pip install bithuman        # docs.bithuman.ai"
        err "      Same engine, in your process; it is a library, not this command."
        err "    * use an x86_64 Linux host (or run the x86_64 build under emulation);"
        err "    * pin the last aarch64 release — note it predates engine vendoring, so"
        err "      \`bithuman run\` cannot render locally on it:"
        err "          curl -sSL https://raw.githubusercontent.com/bithuman-product/homebrew-bithuman/main/install.sh | BITHUMAN_VERSION=cli-v2.3.27 sh"
        err "    * tell us you need it: hello@bithuman.ai"
        ;;
      x86_64-apple-darwin)
        # ★AN INTEL MAC IS A DIFFERENT ANSWER FROM "not published yet".
        # No release has ever carried an x86_64-apple-darwin asset and no other
        # channel serves it either — `pip install bithuman` resolves an Intel
        # Mac to a 2026-04-29 wheel, which is worse than a refusal. So this arm
        # says the true thing and offers nothing that would not work.
        err "  Intel Macs are not built, and no other channel serves one either."
        err "  On Apple Silicon this installs normally. Options:"
        err "    * run on an Apple Silicon Mac or an x86_64 Linux host;"
        err "    * tell us you need it: hello@bithuman.ai"
        ;;
      *)
        err "  If you need this target, tell us: hello@bithuman.ai"
        ;;
    esac
    err ""
    err "  Full asset list: https://github.com/${GITHUB_REPO}/releases/tag/${version}"
    exit 1
    ;;
esac

tmpdir=$(mktemp -d 2>/dev/null || mktemp -d -t 'bithuman-install')
trap 'rm -rf "$tmpdir"' EXIT INT TERM HUP

info "downloading $tarball_url"
if ! curl -fSL --progress-bar "$tarball_url" -o "$tmpdir/$tarball_name"; then
  err "download failed."
  err "The tarball for $target may not be published for $version."
  err "See available assets at: https://github.com/${GITHUB_REPO}/releases/tag/${version}"
  exit 1
fi

# Optional sha256 verification — only fails if a sha256 sidecar exists AND
# does not match. Missing sidecar is treated as 'verification skipped'.
sha_url="${tarball_url}.sha256"
sha_file="$tmpdir/${tarball_name}.sha256"
if curl -fsSL "$sha_url" -o "$sha_file" 2>/dev/null; then
  info "verifying sha256..."
  expected=$(awk '{print $1}' "$sha_file")
  if command -v shasum >/dev/null 2>&1; then
    actual=$(shasum -a 256 "$tmpdir/$tarball_name" | awk '{print $1}')
  elif command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "$tmpdir/$tarball_name" | awk '{print $1}')
  else
    err "no sha256 tool found (shasum or sha256sum); refusing to install unverified tarball."
    exit 1
  fi
  if [ "$expected" != "$actual" ]; then
    err "sha256 mismatch!"
    err "  expected: $expected"
    err "  actual:   $actual"
    err "Aborting install. The download may be corrupt or tampered with."
    exit 1
  fi
  info "sha256 ok"
else
  info "no sha256 sidecar published; skipping integrity check"
fi

info "extracting..."
tar -xzf "$tmpdir/$tarball_name" -C "$tmpdir"

# Locate the binary and lib/ inside the extracted tree. The macOS tarballs
# ship a flat layout (./bithuman + ./lib/) but some builds may nest a single
# top-level directory; handle both.
extracted_bin=""
extracted_lib=""
if [ -f "$tmpdir/bithuman" ]; then
  extracted_bin="$tmpdir/bithuman"
  [ -d "$tmpdir/lib" ] && extracted_lib="$tmpdir/lib"
else
  # Look one level deep.
  candidate=$(find "$tmpdir" -mindepth 2 -maxdepth 2 -type f -name 'bithuman' 2>/dev/null | head -1)
  if [ -n "$candidate" ]; then
    extracted_bin="$candidate"
    parent=$(dirname "$candidate")
    [ -d "$parent/lib" ] && extracted_lib="$parent/lib"
  fi
fi

if [ -z "$extracted_bin" ]; then
  err "extracted tarball does not contain a 'bithuman' binary."
  err "Contents of $tmpdir:"
  ls -la "$tmpdir" >&2 || true
  exit 1
fi

# The expression-2 LOCAL realtime render payload travels next to the binary in
# the self-contained tarball (mac: expression2-model + embody.model + engines/;
# linux: expression2-model + engines/). The CLI discovers them by the binary's
# own location (expression2/render_stream.rs: <exe>/expression2-model,
# <exe>/embody.model; imx_fetch.rs: <exe>/engines/<platform>-<version>.engine),
# so they MUST be installed side-by-side with `bithuman` — otherwise
# `bithuman run` fetches the avatar but has nothing to render it with locally
# (the exact linux out-of-box gap fixed in cli-v2.4.0). Absent ⇒ a cloud/serve-
# only tarball; these stay empty and the render payload is simply not installed.
bundle_root="$(dirname "$extracted_bin")"
extracted_host=""; [ -f "$bundle_root/expression2-model" ] && extracted_host="$bundle_root/expression2-model"
extracted_embody=""; [ -f "$bundle_root/embody.model" ] && extracted_embody="$bundle_root/embody.model"
extracted_engines=""; [ -d "$bundle_root/engines" ] && extracted_engines="$bundle_root/engines"
# ★THE ESSENCE-2 PAYLOAD, which this script never carried. The CLI dlopens
# libessence2.dylib by exe-relative search (elevate/ffi.rs::candidates: next to
# the binary, <exe>/lib, <exe>/../lib, ~/.bithuman/lib), and libessence2 then
# resolves its MLX default.metallib and the Expression bundle through
# Bundle.main — i.e. relative to the EXE dir — so BOTH must land beside
# `bithuman` or `bithuman run <X.elevatedir>` fails. Discovered 2026-08-29
# while tracing why cli-v2.4.2 ships no essence-2: even once the tarball
# carries the engine, this installer would have left it in the temp dir,
# because the payload it copies is a hand-written list. Absent ⇒ empty ⇒
# not installed, exactly like the expression-2 payload above.
extracted_e2lib=""; [ -f "$bundle_root/libessence2.dylib" ] && extracted_e2lib="$bundle_root/libessence2.dylib"
extracted_e2res=""
if [ -n "$(find "$bundle_root" -maxdepth 1 -name '*.bundle' -print -quit 2>/dev/null)" ]; then
  extracted_e2res="$bundle_root"
fi

# ----- install ---------------------------------------------------------------

# Preserve binary + lib/<dylibs> side by side so @loader_path/lib resolves
# at runtime on macOS (and rpath $ORIGIN/lib on Linux). Replace any prior
# install atomically-ish (rm before cp).
if [ -n "$extracted_lib" ]; then
  rm -rf "$install_dir/lib"
  cp -R "$extracted_lib" "$install_dir/lib"
fi

# install(1) is POSIX-mandatory on Linux; on macOS it's BSD install which
# supports -m. Use cp + chmod as a portable fallback if install fails.
if command -v install >/dev/null 2>&1; then
  install -m 755 "$extracted_bin" "$install_dir/bithuman" 2>/dev/null \
    || { cp "$extracted_bin" "$install_dir/bithuman" && chmod 755 "$install_dir/bithuman"; }
else
  cp "$extracted_bin" "$install_dir/bithuman"
  chmod 755 "$install_dir/bithuman"
fi

# Install the expression-2 local-render payload side-by-side with the binary so
# the CLI's exe-relative discovery finds it (zero engine fetch on first run).
if [ -n "$extracted_host" ]; then
  cp "$extracted_host" "$install_dir/expression2-model"
  chmod 755 "$install_dir/expression2-model"
  info "installed expression2-model (local realtime render host)"
fi
if [ -n "$extracted_embody" ]; then
  cp "$extracted_embody" "$install_dir/embody.model"    # mac shared CoreML/ANE graph (data blob)
fi
if [ -n "$extracted_engines" ]; then
  rm -rf "$install_dir/engines"
  cp -R "$extracted_engines" "$install_dir/engines"
  info "installed engines/ ($(ls -1 "$install_dir/engines" 2>/dev/null | tr '\n' ' '))"
fi

# essence-2: the dylib and its Bundle.main resources travel TOGETHER. Installing
# one without the other produces a CLI that dlopens the engine and then dies at
# the first render, which is strictly worse than not installing it at all — so
# the pair is gated, and a half-payload says so instead of installing quietly.
if [ -n "$extracted_e2lib" ] && [ -z "$extracted_e2res" ]; then
  err "tarball carries libessence2.dylib but none of its resource bundles; skipping essence-2 (it would fail at first render)"
elif [ -n "$extracted_e2lib" ]; then
  cp "$extracted_e2lib" "$install_dir/libessence2.dylib"
  chmod 755 "$install_dir/libessence2.dylib"
  for b in "$extracted_e2res"/*.bundle; do
    [ -e "$b" ] || continue
    rm -rf "$install_dir/$(basename "$b")"
    cp -R "$b" "$install_dir/"
  done
  for f in "$extracted_e2res"/a2x_w2v*.onnx "$extracted_e2res"/audio_encoder_fp16_window_*.onnx; do
    [ -e "$f" ] || continue
    cp "$f" "$install_dir/"
  done
  info "installed libessence2.dylib + essence-2 resources (on-device essence-2)"
fi

# ----- smoke test ------------------------------------------------------------

if ! "$install_dir/bithuman" --version >/dev/null 2>&1; then
  err "install completed but '$install_dir/bithuman --version' failed."
  err "Likely causes:"
  err "  * Bundled lib/ missing or @loader_path/rpath not resolving."
  err "  * Architecture mismatch (downloaded $target on $(uname -m))."
  err "Try running it directly to see the error:"
  err "    $install_dir/bithuman --version"
  exit 1
fi

ver_line=$("$install_dir/bithuman" --version 2>/dev/null | head -1)

# ----- success message -------------------------------------------------------

info ""
info "installed: ${ver_line:-bithuman $version}"
info "  -> $install_dir/bithuman"

case ":$PATH:" in
  *":$install_dir:"*)
    info ""
    info "Run 'bithuman --help' to get started."
    ;;
  *)
    if [ "${BITHUMAN_NO_MODIFY_PATH:-}" != "1" ]; then
      info ""
      info "Note: $install_dir is not on your PATH."
      info "Add this to your shell profile (~/.zshrc, ~/.bashrc, ~/.profile):"
      info ""
      info "    export PATH=\"$install_dir:\$PATH\""
      info ""
      info "Then restart your shell, or run:"
      info "    export PATH=\"$install_dir:\$PATH\""
    fi
    ;;
esac
