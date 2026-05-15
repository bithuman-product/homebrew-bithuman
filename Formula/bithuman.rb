# Homebrew formula for `bithuman` — the bitHuman SDK on-device avatar
# runtime CLI for macOS. https://www.bithuman.ai
#
# Install:
#   brew tap bithuman-product/bithuman
#   brew install bithuman
#   bithuman --help
#
# Engine: libessence v1.17.5 — the unified bitHuman SDK release. Voice
# / text / avatar all run on-device (ASR + LLM + TTS + bitHuman
# expression engine); cloud backends are optional.
#
# Backwards compat:
#   Previously published as `bithuman-cli`. An `Aliases/bithuman-cli`
#   symlink keeps `brew install bithuman-cli` working as a deprecated
#   alias for users with the old name in scripts / muscle memory.
#
# This formula installs a prebuilt Rust binary from the
# bithuman-product/bithuman-sdk libessence-v1.17.5 GitHub Release.
# First launch downloads ~3 GB of model weights to ~/.cache/huggingface/hub/
# only if you opt into `--local` mode (cloud mode is the default and
# needs no on-disk weights).
class Bithuman < Formula
  desc "On-device avatar runtime CLI for the bitHuman SDK (voice/text/avatar, all local)"
  homepage "https://github.com/bithuman-product/bithuman-sdk"
  # Tarball mirrored to the public homebrew-bithuman tap repo's own
  # Releases. The upstream bithuman-sdk repo is private, which gates
  # anonymous downloads of its release assets with HTTP 404 — so brew
  # (which downloads anonymously, not via API) cannot fetch from there.
  # We mirror to the tap repo, which IS public, so `brew install` works
  # without any credentials.
  url "https://github.com/bithuman-product/homebrew-bithuman/releases/download/v1.17.5/bithuman-aarch64-apple-darwin.tar.gz"
  version "1.17.5"
  sha256 "117d42c29a2a43f517f9b84b744d22d0af44213f98de2d2ed2a49f05ca4b5f49"
  license "Apache-2.0"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  # No runtime `depends_on` dylibs. As of 1.17.5 the macOS tarball is
  # self-contained: the `bithuman` binary references every third-party
  # dylib (ONNX Runtime, HDF5, FFmpeg, libjpeg-turbo, libwebp, the
  # libcurl chain — 106 dylibs total) via @loader_path/lib/<name>, and
  # those dylibs travel inside the tarball's lib/ directory. `otool -L`
  # on the binary and all 106 bundled dylibs shows 0 /opt/homebrew
  # references; the only external links are macOS system frameworks and
  # OS-provided /usr/lib/* (libSystem, libc++, libz, libcurl, libiconv).
  # Dropping the Homebrew runtime deps makes `brew install` lighter and
  # removes the version-pin breakage that comes from Homebrew bumping
  # e.g. onnxruntime/ffmpeg out from under a binary linked at a fixed
  # soname.

  def install
    # Self-contained tarball: ./bithuman + ./lib/*.dylib, binary linked
    # with @loader_path/lib. Keep that relative layout intact by
    # installing the whole bundle under libexec and exposing a thin
    # symlink on PATH — @loader_path resolves through the symlink to
    # the real binary in libexec, so the bundled lib/ is found.
    libexec.install "bithuman", "lib"
    bin.install_symlink libexec/"bithuman"
  end

  def caveats
    <<~EOS
      Quick start:
        bithuman            # voice chat (the default)
        bithuman text       # type instead of speak
        bithuman avatar     # voice + lip-synced animated face
        bithuman doctor     # check what your machine can run
        bithuman --help     # full reference

      Cloud (instant, no downloads):
        export OPENAI_API_KEY=sk-...
        bithuman            # auto-picks the cloud backend

      Fully on-device (private, slower first run):
        bithuman voice  --local      # ~5 GB first-run download
        bithuman text   --local      # ~2 GB first-run download
        bithuman avatar --local      # ~7 GB first-run download

      Avatar mode also needs a free bitHuman API key — get one at
      https://www.bithuman.ai/#developer and either export it as
      BITHUMAN_API_KEY or save to:
        ~/Library/Application Support/com.bithuman.cli/bithuman-api-key

      Run `bithuman cleanup` to wipe cached downloads if you
      want a fresh start.

      Docs: https://github.com/bithuman-product/bithuman-sdk
    EOS
  end

  test do
    # --help exits 0 with non-trivial output. Mic permissions can't
    # be granted from `brew test`, so a real boot is out of scope.
    assert_match "bithuman", shell_output("#{bin}/bithuman --help")
    # `bithuman version` prints libessence + ABI + CLI versions.
    # Pins the contract: the libessence shared with the formula must
    # match the binary's stamped version, so a stale upload can't
    # silently drift from the published tag.
    assert_match version.to_s, shell_output("#{bin}/bithuman version")
  end
end
