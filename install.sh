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

# ----- self-test -------------------------------------------------------------
# `sh install.sh --self-test`. A `curl | sh` never passes an argument, so this
# is unreachable on the install path. It is a LIVE probe against the real
# releases, and it is built so that a blind instrument fails it: the SAME target
# must come back MISSING on the release that dropped it and OK on the release
# that carries it, so "MISSING for everything" cannot pass.
if [ "${1:-}" = "--self-test" ]; then
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
  api_url="https://api.github.com/repos/${GITHUB_REPO}/releases"
  tags=$(curl -fsSL "$api_url" \
    | grep '"tag_name"' \
    | sed -e 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
  version=$(printf '%s\n' "$tags" | grep '^cli-v' | head -1)
  [ -z "$version" ] && version=$(printf '%s\n' "$tags" | grep -E '^v[0-9]' | grep -v -- '-mac$' | head -1)
  if [ -z "$version" ]; then
    err "could not determine latest CLI release from $api_url"
    err "set BITHUMAN_VERSION=cli-vX.Y.Z (or vX.Y.Z) to pin a specific release."
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
        err "  aarch64 Linux was published through cli-v2.3.27 and dropped at cli-v2.4.0,"
        err "  when the tarball began vendoring the expression-2 render engine and only an"
        err "  x86_64 Linux engine was built. Options, in order of preference:"
        err "    * use an x86_64 Linux host (or run the x86_64 build under emulation);"
        err "    * pin the last aarch64 release — note it predates engine vendoring, so"
        err "      \`bithuman run\` cannot render locally on it:"
        err "          BITHUMAN_VERSION=cli-v2.3.27 sh install.sh"
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
