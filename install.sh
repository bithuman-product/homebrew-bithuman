#!/bin/sh
# bithuman CLI installer: downloads the newest CLI release for this machine, checks its sha256, and
# installs it into ~/.local/bin (or $BITHUMAN_INSTALL_DIR).
#   curl -fsSL https://install.bithuman.ai | sh
# Environment: BITHUMAN_VERSION=cli-vX.Y.Z pins a release; BITHUMAN_INSTALL_DIR picks the directory.
# Docs: https://docs.bithuman.ai/sdk/cli

set -eu

GITHUB_REPO="bithuman-product/homebrew-bithuman"

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

assets_for_tag() {
  curl -fsSL "https://api.github.com/repos/${GITHUB_REPO}/releases/tags/$1" 2>/dev/null \
    | grep '"name"' \
    | sed -e 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' \
    | grep '^bithuman-.*\.tar\.gz$' || true
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
  sed -e "s/^$1//" \
    | sed -e 's/^\([0-9][0-9]*\)$/\1.0.0/' -e 's/^\([0-9][0-9]*\.[0-9][0-9]*\)$/\1.0/' \
    | sort -t. -k1,1nr -k2,2nr -k3,3nr \
    | sed -e "s/^/$1/"
}

pick_latest_real_release() {
  _cands=$(grep "^$1[0-9]" || true)
  [ -z "$_cands" ] && return 0
  _cands=$(printf '%s\n' "$_cands" | grep -v -- '-mac$' || true)
  [ -z "$_cands" ] && return 0
  _n=0
  for _t in $(printf '%s\n' "$_cands" | semver_desc "$1"); do
    _n=$((_n + 1))
    [ "$_n" -gt 8 ] && break
    case "$(release_state "$_t")" in
      RELEASE) printf '%s\n' "$_t"; return 0 ;;
      *)       ;;
    esac
  done
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
  printf 'install.sh --self-test  (live, against %s)\n' "$GITHUB_REPO"
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
  _rel_list=$(curl -fsSL "https://api.github.com/repos/${GITHUB_REPO}/releases?per_page=100" || true)
  _triples=$(printf '%s\n' "$_rel_list" \
    | grep -E '"(tag_name|draft|prerelease)"[[:space:]]*:' \
    | sed -e 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/T \1/' \
          -e 's/.*"draft"[[:space:]]*:[[:space:]]*\([a-z]*\).*/D \1/' \
          -e 's/.*"prerelease"[[:space:]]*:[[:space:]]*\([a-z]*\).*/P \1/' \
    | awk '$1=="T"{t=$2} $1=="D"{d=$2} $1=="P"&&t!=""{print t, d, $2}')
  _one_real=$(printf '%s\n' "$_triples" | awk '$2=="false" && $3=="false" {print $1; exit}')
  _one_pre=$(printf  '%s\n' "$_triples" | awk '$2=="false" && $3=="true"  {print $1; exit}')
  if [ -z "$_one_real" ]; then
    printf '  FAIL  %-58s %s\n' "the listing offers a REAL release to grade" "none — could not look"; _t_fail=1
  else
    _ts "a tag the API calls a real release -> RELEASE"       "$_one_real" RELEASE
  fi
  if [ -z "$_one_pre" ]; then
    printf '  FAIL  %-58s %s\n' "★the listing offers a PRE-RELEASE to grade" "none — could not look"; _t_fail=1
  else
    _ts "★a tag the API calls a pre-release -> PRERELEASE"     "$_one_pre" PRERELEASE
  fi
  _ts "a tag that cannot exist -> UNKNOWN"      cli-v0.0.0-nope UNKNOWN

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

  _formula_tag=$(curl -fsSL "https://raw.githubusercontent.com/${GITHUB_REPO}/main/Formula/bithuman-cli.rb" 2>/dev/null \
    | sed -n 's|.*releases/download/\([^/]*\)/bithuman-aarch64-apple-darwin\.tar\.gz.*|\1|p' | head -1)
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
  api_url="https://api.github.com/repos/${GITHUB_REPO}/releases?per_page=100"
  tags=$(curl -fsSL "$api_url" \
    | grep '"tag_name"' \
    | sed -e 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
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
        err "  aarch64 Linux is carried by cli-v2.7.1 and later (and by cli-v2.3.27 and"
        err "  earlier); $version was cut while only an x86_64 Linux render host existed."
        err "  Options, in order of preference:"
        err "    * ★INSTALL A RELEASE THAT CARRIES IT — the newest does; to pin the first:"
        err "          curl -sSL https://raw.githubusercontent.com/bithuman-product/homebrew-bithuman/main/install.sh | BITHUMAN_VERSION=cli-v2.7.1 sh"
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

ver_line=$("$install_dir/bithuman" --version 2>/dev/null | head -1)

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
