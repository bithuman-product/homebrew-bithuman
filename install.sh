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
