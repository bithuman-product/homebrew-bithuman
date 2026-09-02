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
# bithuman-product/bithuman (repo renamed from bithuman-cli) against the bithuman-product/bithuman-models
# engine monorepo, models/essence-1 (libessence engine core 2.3.8, ABI 7),
# mirrored to the public homebrew-bithuman tap repo's own Releases
# (both upstream repos are private — anonymous brew downloads fail
# there with HTTP 404; the mirror is the workaround).
class BithumanCli < Formula
  desc "Live-avatar CLI for the bitHuman SDK (`bithuman run` for browser-served chat)"
  homepage "https://www.bithuman.ai"
  # Current published release: cli-v2.5.1 — the CLI that has to be installed
  # BEFORE platform 685b2c4b (the unified `<CODE>.imx` download filename) is
  # deployed. cmd/cloud.rs::route chose LOCAL Apple-Silicon render vs a PAID
  # cloud session by testing that server-supplied filename for `.avatar`, so
  # under the unified name an expression-2 agent would have stopped rendering
  # locally and quietly opened a billed cloud session. 2.5.1 also gives
  # `bithuman render` a family router: essence-2 and expression-2 containers
  # used to come back rc=70 "file corrupt" from the essence-1 loader.
  #
  # cli-v2.5.0 (superseded) carried `bithuman pull <CODE> --model <FAMILY>`
  # and the no-flag `pull` that names the families it did NOT hand you, read
  # off the download response's X-Bithuman-Model / -Model-Source /
  # -Supported-Models headers.
  #
  # ★FIRST SIGNED + NOTARIZED macOS TARBALL. Every mac `bithuman` up to and
  # including cli-v2.4.2 was AD-HOC signed (Signature=adhoc,
  # TeamIdentifier=not set, `spctl -a -t install` rejected). `brew install`
  # never noticed — Homebrew fetches with curl, which sets no
  # com.apple.quarantine, and Gatekeeper only evaluates quarantined files —
  # but a BROWSER download of the same tarball was quarantined, macOS
  # propagated that onto every extracted member, and the binary was SIGKILLed
  # on exec (rc=137, no message). This tarball carries `Developer ID
  # Application: bitHuman Inc. (G64NFNZX84)` under the hardened runtime and
  # an Apple notarization ticket; verified from a quarantined download,
  # `spctl -a -t install` = accepted, source=Notarized Developer ID, and the
  # binary runs rc=0.
  #
  # Cut on alpharetta rather than by release-cli.yml's mac lane: the signing
  # identity is in that host's login keychain and homebrew-bithuman holds
  # none of the MACOS_CERT_P12_* / NOTARY_* secrets, so the workflow's own
  # gate correctly REFUSES to publish from CI. Same scripts either way
  # (tap scripts/sign-macos.sh + notarize-macos.sh + verify-macos-release.sh,
  # cli scripts/bundle-macos.sh + check-engine-dedup.sh). The Linux x86_64
  # tarball on the same release IS workflow-built; this formula stays
  # mac-only, matching 2.4.0/2.4.2.
  #
  # Apple Silicon (arm64). The macOS tarball is self-contained AND ships the
  # expression-2 render engine next to the binary (expression2-model +
  # embody.model blessed 90e4cf31cf71 + engines/mac-arm64-1.0.0.engine), so
  # `bithuman run` renders Wise Pup out of the box with ZERO engine fetch.
  # It ships NO essence-2 engine, deliberately and declared
  # (BITHUMAN_TARBALL_NO_ESSENCE2=1), and ★the REASON has changed since this
  # comment was written, so read it again rather than trusting the old one.
  # It used to say the pinned essence2-libessence2-v1.0-a2x slices SYNTHESIZE
  # teeth and check-libessence2-borrows.sh refuses them. The pin moved: it now
  # resolves essence2-libessence2-v1.1-tessera, which the SAME gate passes
  # (rc 0, bank 6 / head 7, with v1.0-a2x kept as the rc-3 control). What
  # actually keeps the engine out is (a) no credential on this estate can read
  # bithuman-models RELEASE ASSETS from the mac build host, and (b) vendoring
  # it roughly DOUBLES the tarball (373 MB of resources + a 56 MB dylib on
  # top of today's 276 MB) — an owner-level product trade, not a packaging
  # oversight. Until it is made, `bithuman run <X.elevatedir>` and
  # `bithuman render <essence-2>.imx` exit 69 UNAVAILABLE naming
  # libessence2.dylib, which is an honest refusal, not a render.
  # (Engine core stays libessence 2.3.8 / ABI 7 — a separate axis; the
  # version below is scanned from the cli-v* tag in the URL.)
  url "https://github.com/bithuman-product/homebrew-bithuman/releases/download/cli-v2.5.1/bithuman-aarch64-apple-darwin.tar.gz"
  sha256 "94a282cf786a1b4fd37a2198a1f571e77a1c33ca0513a6d74f5522f94c7e6bbe"
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
    # with @loader_path/lib. The macOS release also vendors the expression-2
    # render engine next to the binary — the `expression2-model` render host,
    # the `embody.model` graph, and the versioned `engines/mac-arm64-1.0.0.engine`
    # — so `bithuman run` renders Wise Pup out of the box with zero engine fetch.
    # Install the whole bundle under libexec and expose a thin symlink on PATH:
    # @loader_path resolves through the symlink to the real binary in libexec
    # (so the bundled lib/ is found), and the CLI canonicalizes current_exe so
    # its exe-relative engine search resolves to libexec through the symlink too.
    #
    # ★INSTALL WHAT THE TARBALL CONTAINS, NOT A HAND-WRITTEN LIST. The line
    # here used to be exactly five names, which made this formula a THIRD
    # independent place the on-device essence-2 payload could be dropped after
    # every gate upstream had passed (the other two: the release job's env vars,
    # and its hand-written `tar` file list). The macOS tarball may also carry
    # `libessence2.dylib` plus the resources libessence2 resolves through
    # Bundle.main — the MLX/Expression *.bundle dirs and the a2x_w2v frontend —
    # and all of those must sit BESIDE the binary in libexec or
    # `bithuman run <X.elevatedir>` cannot render. Installing everything that
    # was shipped is also self-maintaining: the next payload added to the
    # tarball arrives without another edit here.
    #
    # Nothing else is in the archive — the release job builds it from a staging
    # dir it populates itself — so this cannot pick up strays.
    libexec.install Dir["*"]
    bin.install_symlink libexec/"bithuman"
  end

  def caveats
    <<~EOS
      Quick start:
        bithuman doctor                    # host + auth + cache sanity check
        bithuman list                      # browse showcase avatars
        bithuman pull modern-court-jester  # download one
        bithuman run ~/.cache/bithuman/showcase/modern-court-jester.imx

      Choosing a model family (new in 2.5.0):
        bithuman pull <CODE>                       # the server's default
        bithuman pull <CODE> --model essence-2     # ask for a family
        Plain `pull` now also NAMES the families it did not hand you, and
        says why you got the one you got.

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
