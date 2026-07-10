# Homebrew formula for `bithuman-cli` — the bitHuman SDK live-avatar
# CLI for macOS. https://www.bithuman.ai
#
# Install:
#   brew tap bithuman-product/bithuman
#   brew install bithuman-cli
#   bithuman doctor                       # host + auth + cache sanity check
#   bithuman run avatar.imx               # live browser-served avatar
#
# The installed binary is named `bithuman` (so users still type
# `bithuman run`, `bithuman doctor`, etc.). Only the Homebrew package
# name carries the `-cli` suffix, matching the PyPI convention:
#
#   pip install bithuman          # Python SDK (library)
#   pip install bithuman-cli      # Python CLI bundle
#   brew install bithuman-cli     # CLI (Homebrew)        <-- canonical
#   brew install bithuman         # CLI (deprecated alias)
#
# Engine: libessence 2.3.8 (ABI 7) — the engine core bundled in this
# CLI. Note the engine-core version is a SEPARATE axis from the CLI/SDK
# version (2.3.x); they are not the same number. One command
# (`bithuman run`) stands up the whole stack: embedded livekit-server,
# libessence runtime, conversation brain, browser landing page.
#
# Two brain paths:
#   * Cloud (default) — OPENAI_API_KEY for the OpenAI Realtime brain.
#   * On-device — set BITHUMAN_LOCAL=1, no API key needed. Requires
#     the Python wheel's [local] extra; see "On-device brain" caveat.
#
# Backwards compat:
#   Previously published as `bithuman` (which itself was a rename from
#   the original `bithuman-cli`). The `Aliases/bithuman` symlink keeps
#   `brew install bithuman` working as a deprecated alias for users
#   with the old name in scripts / muscle memory.
#
# This formula installs a prebuilt Rust binary built from the standalone
# bithuman-product/bithuman-cli against the bithuman-product/bithuman-models
# engine monorepo, models/essence-1 (libessence engine core 2.3.8, ABI 7),
# mirrored to the public homebrew-bithuman tap repo's own Releases
# (both upstream repos are private — anonymous brew downloads fail
# there with HTTP 404; the mirror is the workaround).
class BithumanCli < Formula
  desc "Live-avatar CLI for the bitHuman SDK (`bithuman run` for browser-served chat)"
  homepage "https://www.bithuman.ai"
  # Current published release: cli-v2.3.27 — standalone bithuman-cli vs
  # reconciled bithuman-models essence1-v2.3.11. Apple Silicon (arm64).
  # (Engine core stays libessence 2.3.8 / ABI 7 — a separate axis; the
  # version below is scanned from the cli-v* tag in the URL.)
  url "https://github.com/bithuman-product/homebrew-bithuman/releases/download/cli-v2.3.27/bithuman-aarch64-apple-darwin.tar.gz"
  sha256 "57c17ebb1aa6b2fecd8014fc3195d84723cc069115acba90c10f993fe4bc10a5"
  license "Apache-2.0"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  # No runtime `depends_on` dylibs. The macOS tarball is self-contained:
  # the `bithuman` binary references every third-party dylib (ONNX
  # Runtime, HDF5, FFmpeg, libjpeg-turbo, libwebp, the libcurl chain)
  # via @loader_path/lib/<name>, and those dylibs travel inside the
  # tarball's lib/ directory. `otool -L` on the binary and all bundled
  # dylibs shows 0 /opt/homebrew references; the only external links
  # are macOS system frameworks and OS-provided /usr/lib/* (libSystem,
  # libc++, libz, libcurl, libiconv). Dropping the Homebrew runtime
  # deps makes `brew install` lighter and removes version-pin breakage
  # that comes from Homebrew bumping e.g. onnxruntime/ffmpeg out from
  # under a binary linked at a fixed soname.

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
        bithuman doctor                    # host + auth + cache sanity check
        bithuman list                      # browse showcase avatars
        bithuman pull modern-court-jester  # download one
        bithuman run ~/.cache/bithuman/showcase/modern-court-jester.imx

      `bithuman run` prints a http://127.0.0.1:8088/<CODE> URL — open
      it, grant mic permission, talk.

      Conversational brain — included with your account:
        `bithuman run` bootstraps a managed brain on first use (a small
        Python venv under ~/.cache/bithuman/brain-venv, set up automatically
        — no `pip install` needed). The brain is billed to your credits
        (~10/min). Just sign in:
          bithuman login

      Advanced brains (optional):
        Bring your own OpenAI key (skips credit billing for the brain):
          export OPENAI_API_KEY=sk-...
        On-device (no key, no outbound network; needs the [local] extra):
          pip install 'bithuman[local]'
          BITHUMAN_LOCAL=1 bithuman run <model.imx>
        ~860 MB models auto-download from HuggingFace on first run.
        Docs: https://docs.bithuman.ai/guides/local-mode

      Avatar metering needs a free bitHuman API key — get one at
      https://www.bithuman.ai/#developer and export it:
        export BITHUMAN_API_KEY=...

      Offline tooling:
        bithuman render avatar.imx -a a.wav -o out.mp4   # MP4 render
        bithuman info   avatar.imx                       # inspect .imx

      Docs:    https://docs.bithuman.ai
      Source:  https://github.com/bithuman-product/homebrew-bithuman
    EOS
  end

  test do
    # Smoke: --version exits 0 + prints the libessence engine line.
    # NOTE: this only asserts the engine-core line (libessence X ABI Y);
    # it deliberately matches any version, so it CANNOT catch CLI/SDK
    # version skew (e.g. a 2.3.0 binary vs 2.3.6 source). It verifies the
    # engine-core axis is present, not that the CLI version is current.
    assert_match(/libessence \d+\.\d+\.\d+ ABI \d+/, shell_output("#{bin}/bithuman --version"))
    # Smoke: doctor runs (exit code may be 0 or 1 depending on env;
    # we just assert the binary linked + opens the cache dirs).
    output = shell_output("#{bin}/bithuman doctor 2>&1", 1) + shell_output("#{bin}/bithuman doctor 2>&1 || true")
    assert_match(/bithuman doctor/, output)
  end
end
