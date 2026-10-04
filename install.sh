#!/bin/sh
# bithuman CLI installer: downloads the newest CLI release for this machine, checks its sha256, and
# installs it into ~/.local/bin (or $BITHUMAN_INSTALL_DIR).
#   curl -fsSL https://install.bithuman.ai | sh
# Environment: BITHUMAN_VERSION=cli-vX.Y.Z pins a release; BITHUMAN_INSTALL_DIR picks the directory;
# BITHUMAN_DOWNLOADS overrides the release origin (default https://downloads.bithuman.ai/homebrew-bithuman);
# BITHUMAN_MIRROR overrides the download mirror ("off" = the release origin only).
# Docs: https://docs.bithuman.ai/sdk/cli

set -eu

# ── Where releases come from (2026-10: bitHuman's own origin; GitHub is not used) ──
# Every release is published to bitHuman's download origin in one fixed layout:
#   <origin>/latest.json           the newest published cli-v* release (never a draft or pre-release)
#   <origin>/releases.json         every release: tag_name, draft, prerelease, assets[].name
#   <origin>/<tag>/<asset>[.sha256]
# (scripts/downloads-publish.py writes all three; RELEASE.md.)
DOWNLOADS="${BITHUMAN_DOWNLOADS:-${BITHUMAN_DOWNLOADS_BASE:-https://downloads.bithuman.ai}/homebrew-bithuman}"
DOWNLOADS="${DOWNLOADS%/}"

# ── The bitHuman download mirror (2026-10-01) ───────────────────────────────
# A second copy of each CLI release, in a Maven-shaped layout:
#   https://maven.bithuman.ai/ai/bithuman/bithuman-cli/maven-metadata.xml   newest version (<release>)
#   https://maven.bithuman.ai/ai/bithuman/bithuman-cli/<X.Y.Z>/<asset>[.sha256]
# a byte-for-byte copy of each release (scripts/mirror-cli-release.sh, RELEASE.md). The installer
# downloads from it first when it holds the resolved version (sidecar AND tarball), and uses its
# metadata to name a version when the origin cannot be read. Anything it cannot answer falls back
# to the origin above.
MIRROR="${BITHUMAN_MIRROR-https://maven.bithuman.ai/ai/bithuman/bithuman-cli}"
case "$MIRROR" in off|none|0) MIRROR="" ;; esac
MIRROR="${MIRROR%/}"

mirror_fetch() { # <url> <outfile> [progress] -> 0 only on HTTP 200; quiet, short connect timeout
  if [ -n "${3:-}" ]; then
    curl -fSL --progress-bar --connect-timeout 10 --speed-limit 1024 --speed-time 30 -o "$2" "$1" 2>/dev/null
  else
    curl -fsSL --connect-timeout 10 --max-time 30 -o "$2" "$1" 2>/dev/null
  fi
}

mirror_latest() { # -> cli-vX.Y.Z from the mirror's maven-metadata.xml, or nothing
  [ -n "$MIRROR" ] || return 0
  _ml=$(curl -fsSL --connect-timeout 10 --max-time 30 "$MIRROR/maven-metadata.xml" 2>/dev/null || true)
  _mv=$(printf '%s\n' "$_ml" | sed -n 's:.*<release>\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)</release>.*:\1:p' | head -1)
  [ -n "$_mv" ] && printf 'cli-v%s\n' "$_mv"
  return 0
}

err() { printf '%s\n' "install: error: $*" >&2; }
info() { printf 'install: %s\n' "$*"; }

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    err "missing required command: $1"
    exit 1
  fi
}

current_uid() {
  if [ -n "${EUID:-}" ]; then
    printf '%s' "$EUID"
  else
    id -u
  fi
}

need_cmd curl
need_cmd tar
need_cmd uname
need_cmd mktemp

# ── Origin fetches: retry a rate limit honestly ─────────────────────────────
# A 429, or a 403 that says a quota is spent, is "wait and retry", never "not published". Before
# 2026-09-30 a 429 on the tarball printed "The tarball … may not be published", which sent people
# to look for a release that was there all along (DX audit, retry-after: 300). No credential is
# ever sent: the origin is public.
#
# dl_fetch <url> <outfile> [progress] -> 0 on 2xx; else 1, with the last HTTP
# code in $_dl_state/code and, when the origin is rate-limiting, the wait it asked
# for in $_dl_state/ratelimited. State lives in files because callers run this
# inside $( ), where a variable would not survive.
DL_MAX_TRIES="${BITHUMAN_INSTALL_MAX_TRIES:-3}"
DL_MAX_WAIT="${BITHUMAN_INSTALL_MAX_WAIT:-120}"   # total seconds this run will sleep
_dl_state=$(mktemp -d 2>/dev/null || mktemp -d -t 'bithuman-dl')
printf '0\n' > "$_dl_state/waited"
trap 'rm -rf "$_dl_state"' EXIT INT TERM HUP

_dl_hdr_value() { # <header-name> <header-file> -> the last value (redirects write several blocks)
  grep -i "^$1:" "$2" 2>/dev/null | tail -1 | sed -e 's/^[^:]*:[[:space:]]*//' | tr -d '\r' | sed -e 's/[[:space:]]*$//'
}

_dl_curl() { # <url> <outfile> <hdrfile> <progress?>  -> prints the HTTP code
  if [ -n "$4" ]; then
    curl -SL --progress-bar -D "$3" -o "$2" -w '%{http_code}' "$1" || true
  else
    curl -sSL -D "$3" -o "$2" -w '%{http_code}' "$1" 2>/dev/null || true
  fi
}

dl_fetch() {
  _url=$1; _out=$2; _prog=${3:-}
  _hdr="$_dl_state/hdr.$$"
  _try=1
  rm -f "$_dl_state/ratelimited"
  while :; do
    : > "$_hdr"
    _code=$(_dl_curl "$_url" "$_out" "$_hdr" "$_prog")
    case "$_code" in [0-9][0-9][0-9]) ;; *) _code=000 ;; esac
    printf '%s\n' "$_code" > "$_dl_state/code"
    case "$_code" in 2??) rm -f "$_hdr"; return 0 ;; esac

    _wait=""
    _limited=""
    _ra=$(_dl_hdr_value retry-after "$_hdr")
    _rem=$(_dl_hdr_value x-ratelimit-remaining "$_hdr")
    _reset=$(_dl_hdr_value x-ratelimit-reset "$_hdr")
    if [ "$_code" = 429 ] || { [ "$_code" = 403 ] && { [ -n "$_ra" ] || [ "$_rem" = 0 ]; }; }; then
      _limited=1
      case "$_ra" in
        ''|*[!0-9]*) ;;
        *) _wait=$_ra ;;
      esac
      if [ -z "$_wait" ]; then
        case "$_reset" in
          ''|*[!0-9]*) ;;
          *) _now=$(date +%s 2>/dev/null || echo 0)
             [ "$_now" -gt 0 ] && _wait=$((_reset - _now)) ;;
        esac
      fi
      [ -z "$_wait" ] && _wait=$((_try * 10))
      [ "$_wait" -lt 1 ] && _wait=1
    else
      case "$_code" in
        000|5??) _wait=$((_try * 3)) ;;         # network hiccup or a 5xx: brief retry
        *) rm -f "$_hdr"; return 1 ;;           # 404 and friends: a real answer, no retry
      esac
    fi

    _waited=$(cat "$_dl_state/waited" 2>/dev/null || echo 0)
    if [ "$_try" -ge "$DL_MAX_TRIES" ] || [ $((_waited + _wait)) -gt "$DL_MAX_WAIT" ]; then
      [ -n "$_limited" ] && printf '%s %s\n' "$_code" "$_wait" > "$_dl_state/ratelimited"
      rm -f "$_hdr"
      return 1
    fi
    if [ -n "$_limited" ]; then
      printf 'install: the download server is rate-limiting this network (HTTP %s); retrying in %ss (attempt %s of %s)\n' \
        "$_code" "$_wait" "$((_try + 1))" "$DL_MAX_TRIES" >&2
    else
      printf 'install: the download server did not answer (HTTP %s); retrying in %ss (attempt %s of %s)\n' \
        "$_code" "$_wait" "$((_try + 1))" "$DL_MAX_TRIES" >&2
    fi
    sleep "$_wait"
    printf '%s\n' "$((_waited + _wait))" > "$_dl_state/waited"
    _try=$((_try + 1))
  done
}

dl_get() { # <url> -> the body on stdout (empty on failure); status as for dl_fetch
  _body="$_dl_state/body.$$"
  if dl_fetch "$1" "$_body"; then
    cat "$_body"; rm -f "$_body"; return 0
  fi
  rm -f "$_body"; return 1
}

# Print the rate-limit refusal and exit, when the last fetch ended on one.
exit_if_rate_limited() {
  [ -f "$_dl_state/ratelimited" ] || return 0
  read -r _rl_code _rl_wait < "$_dl_state/ratelimited"
  err "the download server is rate-limiting downloads from this network (HTTP $_rl_code); retry in about ${_rl_wait}s."
  err ""
  err "  Nothing is wrong with the release. Run the installer again in a few minutes, or pin a"
  err "  release on the \`sh\` side of the pipe, which skips the release lookup:"
  err ""
  err "      curl -sSL https://install.bithuman.ai | BITHUMAN_VERSION=cli-vX.Y.Z sh"
  exit 1
}

# ── The release index, read without jq ──────────────────────────────────────
# rel_table <json-file>: one line per release, "R <tag> <draft> <prerelease>", then one line per
# asset, "A <tag> <name>". It reads releases.json (an array) and latest.json (one object) in any
# JSON layout -- pretty or minified, any key order -- by splitting on '"' (awk RS): records then
# alternate between text outside and inside strings, an escaped quote is re-joined, and braces
# outside strings give the depth (a release is depth 1, an asset depth 2 inside "assets").
rel_table() {
  awk 'BEGIN { RS = "\""; d = 0; instr = 0; buf = ""; have = 0; ina = 0 }
  {
    if (instr) {
      t = $0; n = 0
      while (n < length(t) && substr(t, length(t) - n, 1) == "\\") n++
      if (n % 2 == 1) { buf = buf $0 "\""; next }
      str = buf $0; buf = ""; instr = 0; have = 1; next
    }
    r = $0
    if (have) {
      have = 0
      if (r ~ /^[ \t\r\n]*:/) { kd[d] = str; if (d == 1) ina = (str == "assets") }
      else if (d == 1 && kd[1] == "tag_name") tag = str
      else if (d == 2 && ina && kd[2] == "name") an[++na] = str
    }
    if (d == 1 && r ~ /^[ \t\r\n]*:[ \t\r\n]*(true|false)/) {
      v = r; sub(/^[ \t\r\n]*:[ \t\r\n]*/, "", v); v = (substr(v, 1, 1) == "t") ? "true" : "false"
      if (kd[1] == "draft") dr = v; else if (kd[1] == "prerelease") pr = v
    }
    for (i = 1; i <= length(r); i++) {
      c = substr(r, i, 1)
      if (c == "{") { d++; if (d == 1) { tag = ""; dr = "?"; pr = "?"; na = 0; ina = 0 } }
      else if (c == "}") {
        if (d == 1 && tag != "") {
          print "R", tag, dr, pr
          for (j = 1; j <= na; j++) print "A", tag, an[j]
        }
        d--
      }
    }
    instr = 1
  }' "$1"
}

releases_json() { # -> path of this run's copy of <origin>/releases.json, or nothing (unreadable)
  if [ ! -s "$_dl_state/releases.json" ] && [ ! -f "$_dl_state/releases.fail" ]; then
    dl_fetch "$DOWNLOADS/releases.json" "$_dl_state/releases.json" || { rm -f "$_dl_state/releases.json"; : > "$_dl_state/releases.fail"; }
  fi
  [ -s "$_dl_state/releases.json" ] && printf '%s\n' "$_dl_state/releases.json"
  return 0
}

assets_for_tag() {
  _rj=$(releases_json)
  [ -n "$_rj" ] || return 0
  rel_table "$_rj" | awk -v t="$1" '$1 == "A" && $2 == t { print $3 }' | grep '^bithuman-.*\.tar\.gz$' || true
}

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

release_state() {
  _rj=$(releases_json)
  [ -n "$_rj" ] || { printf 'UNKNOWN\n'; return 0; }
  _st=$(rel_table "$_rj" | awk -v t="$1" '$1 == "R" && $2 == t { print $3, $4; exit }')
  case "$_st" in
    "true "*)     printf 'DRAFT\n' ;;
    "false true") printf 'PRERELEASE\n' ;;
    "false false") printf 'RELEASE\n' ;;
    *)            printf 'UNKNOWN\n' ;;
  esac
}

semver_desc() {
  sed -e "s/^$1//" \
    | sed -e 's/^\([0-9][0-9]*\)$/\1.0.0/' -e 's/^\([0-9][0-9]*\.[0-9][0-9]*\)$/\1.0/' \
    | sort -t. -k1,1nr -k2,2nr -k3,3nr \
    | sed -e "s/^/$1/"
}

# pick_latest_real_release <prefix>: stdin = rel_table lines; prints the newest <prefix>X.Y.Z that is
# neither a draft nor a pre-release (never a `-mac` app tag), or nothing.
pick_latest_real_release() {
  _cands=$(awk -v p="$1" '$1 == "R" && index($2, p) == 1 && $3 == "false" && $4 == "false" { print $2 }' \
           | grep "^$1[0-9]" | grep -v -- '-mac$' || true)
  [ -z "$_cands" ] && return 0
  printf '%s\n' "$_cands" | semver_desc "$1" | head -1
  return 0
}

# downloads_latest -> the newest published cli-v* release from <origin>/latest.json, cross-checked:
# it must say draft=false and prerelease=false and carry a cli-v tag; anything else falls back to
# picking from <origin>/releases.json. Prints nothing when neither can be read.
downloads_latest() {
  if dl_fetch "$DOWNLOADS/latest.json" "$_dl_state/latest.json"; then
    _lt=$(rel_table "$_dl_state/latest.json" | awk '$1 == "R" && $3 == "false" && $4 == "false" { print $2; exit }')
    case "$_lt" in cli-v[0-9]*) printf '%s\n' "$_lt"; return 0 ;; esac
  fi
  _rj=$(releases_json)
  [ -n "$_rj" ] && rel_table "$_rj" | pick_latest_real_release 'cli-v'
  return 0
}

if [ "${1:-}" = "--self-test" ]; then
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
  printf 'install.sh --self-test  (live, against %s)\n' "$DOWNLOADS"
  _t "cli-v2.5.1 has no aarch64 Linux"          cli-v2.5.1  bithuman-aarch64-unknown-linux-gnu.tar.gz MISSING
  _t "cli-v2.5.1 HAS x86_64 Linux (control)"    cli-v2.5.1  bithuman-x86_64-unknown-linux-gnu.tar.gz  OK
  _t "cli-v2.5.1 HAS arm64 macOS (control)"     cli-v2.5.1  bithuman-aarch64-apple-darwin.tar.gz      OK
  _t "cli-v2.3.27 HAS aarch64 Linux (★control)" cli-v2.3.27 bithuman-aarch64-unknown-linux-gnu.tar.gz OK
  _t "a tag that cannot exist -> SKIP not OK"   cli-v0.0.0-nope bithuman-x86_64-unknown-linux-gnu.tar.gz SKIP

  _ts() { # <label> <tag> <expected-state>
    _got=$(release_state "$2" || true)
    if [ "$_got" = "$3" ]; then
      printf '  PASS  %-58s %s\n' "$1" "$_got"
    else
      printf '  FAIL  %-58s got %s, want %s\n' "$1" "$_got" "$3"; _t_fail=1
    fi
  }
  _rj=$(releases_json)
  _triples=""
  [ -n "$_rj" ] && _triples=$(rel_table "$_rj" | awk '$1 == "R" { print $2, $3, $4 }')
  _one_real=$(printf '%s\n' "$_triples" | awk '$2=="false" && $3=="false" {print $1; exit}')
  _one_pre=$(printf  '%s\n' "$_triples" | awk '$2=="false" && $3=="true"  {print $1; exit}')
  if [ -z "$_one_real" ]; then
    printf '  FAIL  %-58s %s\n' "the index offers a REAL release to grade" "none — could not look"; _t_fail=1
  else
    _ts "a tag the index calls a real release -> RELEASE"     "$_one_real" RELEASE
  fi
  if [ -z "$_one_pre" ]; then
    printf '  FAIL  %-58s %s\n' "★the index offers a PRE-RELEASE to grade" "none — could not look"; _t_fail=1
  else
    _ts "★a tag the index calls a pre-release -> PRERELEASE"   "$_one_pre" PRERELEASE
  fi
  _ts "a tag that cannot exist -> UNKNOWN"      cli-v0.0.0-nope UNKNOWN

  _picked=""
  [ -n "$_rj" ] && _picked=$(rel_table "$_rj" | pick_latest_real_release 'cli-v' || true)
  if [ -z "$_picked" ]; then
    printf '  FAIL  %-58s resolved nothing\n' "the picker selects a cli-v* release"; _t_fail=1
  elif [ "$(release_state "$_picked")" = RELEASE ]; then
    printf '  PASS  %-58s %s\n' "★the picker selects a release, never a pre-release" "$_picked"
  else
    printf '  FAIL  %-58s picked %s which is %s\n' \
           "★the picker selects a release, never a pre-release" "$_picked" "$(release_state "$_picked")"; _t_fail=1
  fi
  _sel=$(downloads_latest || true)
  if [ -n "$_sel" ] && [ "$_sel" = "$_picked" ]; then
    printf '  PASS  %-58s %s\n' "★latest.json names the release the picker chooses" "$_sel"
  else
    printf '  FAIL  %-58s latest.json=%s picker=%s\n' \
           "★latest.json names the release the picker chooses" "${_sel:-<none>}" "${_picked:-<none>}"; _t_fail=1
  fi

  # The formula users install, read from the tap's canonical main (override for a local run).
  _formula_url="${BITHUMAN_SELFTEST_FORMULA_URL:-https://gitlab.com/bithuman/sdk/homebrew-bithuman/-/raw/main/Formula/bithuman-cli.rb}"
  _formula_tag=$(curl -fsSL "$_formula_url" 2>/dev/null \
    | sed -n 's|.*/\([^/]*\)/bithuman-aarch64-apple-darwin\.tar\.gz".*|\1|p' | head -1)
  if [ -z "$_formula_tag" ]; then
    printf '  FAIL  %-58s %s\n' "the formula names a tag to compare against" "none — could not look"; _t_fail=1
  elif [ "$_formula_tag" = "$_sel" ]; then
    printf '  PASS  %-58s %s\n' "★curl|sh and brew install resolve the SAME tag" "$_sel"
  else
    printf '  FAIL  %-58s installer=%s formula=%s\n' \
           "★curl|sh and brew install resolve the SAME tag" "$_sel" "$_formula_tag"; _t_fail=1
  fi

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
      BITHUMAN_VERSION=cli-v2.5.1 \
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
  _pat_rel="BITHUMAN_VERSION=cli-v2.""7.1 sh"
  case "$_out_arm" in
    *"$_pat_rel"*)
      printf '  PASS  %-58s FOUND\n' "aarch64-Linux refusal NAMES the release that restored it" ;;
    *)
      printf '  FAIL  %-58s the rendered refusal does not pin cli-v2.7.1\n' \
             "aarch64-Linux refusal NAMES the release that restored it"; _t_fail=1 ;;
  esac
  _out_ctl=$(_run_child riscv64)
  case "$_out_ctl" in
    *"$_pat_rel"*)
      printf '  FAIL  %-58s it is printed unconditionally\n' \
             "★control: an unserved arch is NOT sent to cli-v2.7.1"; _t_fail=1 ;;
    *)
      printf '  PASS  %-58s ABSENT\n' "★control: an unserved arch is NOT sent to cli-v2.7.1" ;;
  esac
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
  cat > "$_st_tmp/bin/shpin" <<'SHPIN'
#!/bin/sh
printf '%s\n' "${BITHUMAN_VERSION:-<UNSET>}"
SHPIN
  chmod +x "$_st_tmp/bin/shpin"
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

uname_s=$(uname -s)
uname_m=$(uname -m)

case "$uname_s" in
  Darwin) os="apple-darwin" ;;
  Linux)  os="unknown-linux-gnu" ;;
  MINGW*|MSYS*|CYGWIN*|Windows_NT)
    # Git Bash / MSYS2 / Cygwin on Windows: the Windows CLI has its own installer.
    err "this is Windows ($uname_s); install the Windows CLI from PowerShell instead:"
    err "  irm https://install.bithuman.ai/windows | iex"
    exit 1
    ;;
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

version="${BITHUMAN_VERSION:-}"
if [ -z "$version" ]; then
  info "querying latest release..."
  version=$(downloads_latest)
  [ -n "$version" ] && info "latest release: $version"
fi
if [ -z "$version" ]; then
  # A rate limit on the origin does not end the lookup: the mirror exists for exactly this kind of
  # origin trouble. mirror_latest uses plain curl, so the origin's rate-limit record survives it,
  # and the check below still names the rate limit when the mirror cannot name a release either.
  version=$(mirror_latest)
  [ -n "$version" ] && info "latest release (bitHuman mirror; $DOWNLOADS could not be read): $version"
fi
if [ -z "$version" ]; then
  exit_if_rate_limited
  err "could not determine the latest CLI release from $DOWNLOADS/latest.json"
  err ""
  err "  Neither the release origin nor the bitHuman mirror named a published cli-v*"
  err "  release (offline, a proxy, or every candidate is a draft or a pre-release)."
  err "  The installer does NOT fall back to a pre-release: a pre-release is"
  err "  bytes Homebrew users are not running, and the two populations follow"
  err "  the same instruction."
  err ""
  err "  Pin a release to skip the lookup:"
  err ""
  err "      curl -sSL https://install.bithuman.ai | BITHUMAN_VERSION=cli-vX.Y.Z sh"
  err ""
  err "set BITHUMAN_VERSION on the \`sh\` side of the pipe (form above) to pin a release."
  exit 1
fi

info "version: $version"
info "target:  $target"

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

tarball_name="bithuman-${target}.tar.gz"
tarball_url="${DOWNLOADS}/${version}/${tarball_name}"

tmpdir=$(mktemp -d 2>/dev/null || mktemp -d -t 'bithuman-install')
trap 'rm -rf "$tmpdir" "$_dl_state"' EXIT INT TERM HUP
sha_file="$tmpdir/${tarball_name}.sha256"

# The mirror first: it must hold BOTH the sidecar and the tarball, or the origin is used.
from_mirror=""
case "$version" in cli-v[0-9]*) _mver=${version#cli-v} ;; *) _mver="" ;; esac
if [ -n "$MIRROR" ] && [ -n "$_mver" ]; then
  _murl="$MIRROR/$_mver/$tarball_name"
  if mirror_fetch "$_murl.sha256" "$sha_file"; then
    info "downloading $_murl"
    if mirror_fetch "$_murl" "$tmpdir/$tarball_name" progress; then
      from_mirror=1
      tarball_url=$_murl
    else
      rm -f "$tmpdir/$tarball_name" "$sha_file"
      info "the bitHuman mirror did not deliver $tarball_name; using the release origin"
    fi
  else
    rm -f "$sha_file"
    info "the bitHuman mirror has no $version/$tarball_name (or is unreachable); using the release origin"
  fi
fi

if [ -z "$from_mirror" ]; then
_avail=$(target_availability "$version" "$tarball_name")
[ "$_avail" = SKIP ] && exit_if_rate_limited
case "$_avail" in
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
        err "  aarch64 Linux is carried by cli-v2.7.1 and later (and by cli-v2.3.27 and"
        err "  earlier); $version was cut while only an x86_64 Linux render host existed."
        err "  Options, in order of preference:"
        err "    * ★INSTALL A RELEASE THAT CARRIES IT — the newest does; to pin the first:"
        err "          curl -sSL https://install.bithuman.ai | BITHUMAN_VERSION=cli-v2.7.1 sh"
        err "    * use the Python library, which supports aarch64 Linux too:"
        err "          pip install bithuman        # docs.bithuman.ai"
        err "      Same engine, in your process; it is a library, not this command."
        err "    * tell us you need something else: hello@bithuman.ai"
        ;;
      x86_64-apple-darwin)
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
    err "  Full release index: ${DOWNLOADS}/releases.json"
    exit 1
    ;;
esac

info "downloading $tarball_url"
if ! dl_fetch "$tarball_url" "$tmpdir/$tarball_name" progress; then
  exit_if_rate_limited
  _dl_code=$(cat "$_dl_state/code" 2>/dev/null || echo 000)
  case "$_dl_code" in
    404)
      err "download failed (HTTP 404): $version has no $tarball_name."
      err "See the assets it does carry: ${DOWNLOADS}/releases.json"
      ;;
    000)
      err "download failed: could not reach ${DOWNLOADS} (network, proxy or DNS)."
      err "Check the connection and run the installer again."
      ;;
    *)
      err "download failed (HTTP $_dl_code) for $tarball_url"
      err "The download server may be having trouble; run the installer again in a minute."
      ;;
  esac
  exit 1
fi

fi  # end of the release-origin path

sha_url="${tarball_url}.sha256"
if [ -n "$from_mirror" ] || dl_fetch "$sha_url" "$sha_file"; then
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
  exit_if_rate_limited
  info "no sha256 sidecar published; skipping integrity check"
fi

info "extracting..."
tar -xzf "$tmpdir/$tarball_name" -C "$tmpdir"

extracted_bin=""
extracted_lib=""
if [ -f "$tmpdir/bithuman" ]; then
  extracted_bin="$tmpdir/bithuman"
  [ -d "$tmpdir/lib" ] && extracted_lib="$tmpdir/lib"
else
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

bundle_root="$(dirname "$extracted_bin")"
extracted_host=""; [ -f "$bundle_root/expression2-model" ] && extracted_host="$bundle_root/expression2-model"
extracted_embody=""; [ -f "$bundle_root/embody.model" ] && extracted_embody="$bundle_root/embody.model"
extracted_engines=""; [ -d "$bundle_root/engines" ] && extracted_engines="$bundle_root/engines"
extracted_lk=""; [ -f "$bundle_root/livekit-server" ] && extracted_lk="$bundle_root/livekit-server"
extracted_e2lib=""; [ -f "$bundle_root/libessence2.dylib" ] && extracted_e2lib="$bundle_root/libessence2.dylib"
extracted_e2res=""
if [ -n "$(find "$bundle_root" -maxdepth 1 -name '*.bundle' -print -quit 2>/dev/null)" ]; then
  extracted_e2res="$bundle_root"
fi

if [ -n "$extracted_lib" ]; then
  rm -rf "$install_dir/lib"
  cp -R "$extracted_lib" "$install_dir/lib"
fi

if command -v install >/dev/null 2>&1; then
  install -m 755 "$extracted_bin" "$install_dir/bithuman" 2>/dev/null \
    || { cp "$extracted_bin" "$install_dir/bithuman" && chmod 755 "$install_dir/bithuman"; }
else
  cp "$extracted_bin" "$install_dir/bithuman"
  chmod 755 "$install_dir/bithuman"
fi

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
if [ -n "$extracted_lk" ]; then
  cp "$extracted_lk" "$install_dir/livekit-server"
  chmod 755 "$install_dir/livekit-server"
  [ -f "$bundle_root/LICENSE.livekit-server" ] && cp "$bundle_root/LICENSE.livekit-server" "$install_dir/LICENSE.livekit-server"
  info "installed livekit-server (the room \`bithuman run\` stands up)"
fi

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

if ! "$install_dir/bithuman" --version >/dev/null 2>&1; then
  err "install completed but '$install_dir/bithuman --version' failed."
  err "Likely causes:"
  err "  * Bundled lib/ missing or @loader_path/rpath not resolving."
  err "  * Architecture mismatch (downloaded $target on $(uname -m))."
  err "Try running it directly to see the error:"
  err "    $install_dir/bithuman --version"
  exit 1
fi

# `--version` prints several lines (libessence, bithuman, build, engine); name the
# CLI itself, not the engine library that happens to come first.
ver_line=$("$install_dir/bithuman" --version 2>/dev/null | grep '^bithuman ' | head -1 | tr -s ' ' || true)
[ -z "$ver_line" ] && ver_line=$("$install_dir/bithuman" --version 2>/dev/null | head -1)

if ! command -v ffmpeg >/dev/null 2>&1; then
  ffmpeg_hint="sudo apt install -y ffmpeg"
  [ "$os" = "apple-darwin" ] && ffmpeg_hint="brew install ffmpeg"
  info ""
  info "Note: \`bithuman render\` writes MP4 through ffmpeg, which is not on your PATH:"
  info "    $ffmpeg_hint"
fi
if [ ! -x "$install_dir/livekit-server" ] && ! command -v livekit-server >/dev/null 2>&1; then
  lk_hint="curl -sSL https://get.livekit.io | bash"
  [ "$os" = "apple-darwin" ] && lk_hint="brew install livekit"
  info ""
  info "Note: \`bithuman run\` stands up a LiveKit room and needs livekit-server:"
  info "    $lk_hint"
fi

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
