# Homebrew formula for `bithuman-cli` — on-device voice + video chat CLI
# for macOS, by bitHuman. Built on top of the bitHumanKit Swift SDK.
# https://www.bithuman.ai
#
# Install:
#   brew tap bithuman-product/bithuman
#   brew install bithuman-cli
#   bithuman-cli
#
# (Tap nickname `bithuman-product/bithuman` resolves to the
# `homebrew-bithuman` repo via Homebrew's convention — the leading
# `homebrew-` prefix is auto-prepended to the repo name.)
#
# This formula installs a prebuilt, Developer ID-signed and Apple-
# notarised binary. No Xcode required on the user's machine. First
# launch downloads ~3 GB of model weights to ~/.cache/huggingface/hub/.
class BithumanCli < Formula
  desc "On-device voice + video chat CLI for macOS (ASR + LLM + TTS + avatar, all local)"
  homepage "https://github.com/bithuman-product/homebrew-bithuman"
  version "0.19.5"
  url "https://github.com/bithuman-product/homebrew-bithuman/releases/download/v#{version}/bithuman-cli-#{version}.zip"
  sha256 "aeaaf99e891827eae4869c7d7ccb4e01ffb51f287ab46c27feabe02b7677f090"
  license "Apache-2.0"

  depends_on macos: :tahoe
  depends_on arch: :arm64

  def install
    # The release zip layout is flat: the binary plus its sibling
    # resource bundles + frameworks all live at the top level. MLX's
    # bundle lookup is RELATIVE to the binary, and libwebrtc loads
    # LiveKitWebRTC.framework via `@executable_path` rpath, so we
    # install everything into libexec and put a tiny exec-wrapper in
    # bin so the binary's runtime neighbours are still next to it
    # after Homebrew links.
    #
    # `*.framework.zip` matches frameworks shipped zipped to bypass
    # `fix_install_linkage`. The companion `post_install` block below
    # extracts them once relocation has run. See post_install for the
    # full rationale.
    libexec.install Dir["bithuman-cli", "*.bundle", "*.framework", "*.framework.zip"]
    (bin/"bithuman-cli").write <<~EOS
      #!/bin/bash
      exec "#{libexec}/bithuman-cli" "$@"
    EOS
    (bin/"bithuman-cli").chmod 0755
  end

  def post_install
    # Why frameworks ship zipped:
    #
    # Homebrew's `fix_install_linkage` walks every Mach-O in a keg
    # and calls `install_name_tool -id` to rewrite each dylib's
    # LC_ID_DYLIB to an absolute install path under
    # `/opt/homebrew/opt/<formula>/...`. That rewrite needs header-
    # pad room reserved at link time. Upstream third-party frameworks
    # — notably libwebrtc, shipped via `livekit/webrtc-xcframework` —
    # were linked WITHOUT `-Wl,-headerpad_max_install_names`, so
    # their LC_ID_DYLIB cmdsize is too small for the longer absolute
    # path brew wants. `install_name_tool` aborts with
    #   "Updated load commands do not fit in the header"
    # and brew emits a confusing (but functionally cosmetic) warning.
    #
    # Workaround: ship the framework as a `.zip`. Brew's Mach-O
    # walker only inspects raw Mach-O magic bytes — a zipped
    # framework is invisible to it. After `fix_install_linkage` has
    # run we extract the zip back into `libexec/`, restoring the
    # exact filesystem layout the binary's `@rpath` lookup expects.
    Dir.glob(libexec/"*.framework.zip") do |zip|
      system "ditto", "-x", "-k", zip.to_s, libexec.to_s
      rm zip
    end
  end

  def caveats
    <<~EOS
      Quick start:
        bithuman-cli            # voice chat (the default)
        bithuman-cli text       # type instead of speak
        bithuman-cli avatar     # voice + lip-synced animated face
        bithuman-cli doctor     # check what your machine can run
        bithuman-cli --help     # full reference

      Cloud (instant, no downloads):
        export OPENAI_API_KEY=sk-...
        bithuman-cli            # auto-picks the cloud backend

      Fully on-device (private, slower first run):
        bithuman-cli voice  --local      # ~5 GB first-run download
        bithuman-cli text   --local      # ~2 GB first-run download
        bithuman-cli avatar --local      # ~7 GB first-run download

      Avatar mode also needs a free bitHuman API key — get one at
      https://www.bithuman.ai/#developer and either export it as
      BITHUMAN_API_KEY or save to:
        ~/Library/Application Support/com.bithuman.cli/bithuman-api-key

      Run `bithuman-cli cleanup` to wipe cached downloads if you
      want a fresh start.

      Docs: https://github.com/bithuman-product/homebrew-bithuman
    EOS
  end

  test do
    # --help exits 0 with non-trivial output. Mic permissions can't
    # be granted from `brew test`, so a real boot is out of scope.
    assert_match "bithuman-cli", shell_output("#{bin}/bithuman-cli --help")
    # --version landed in 0.19.3. Pins the contract: the binary's
    # stamped version string must match the formula's version, so
    # release.sh's CLIVersion.swift sed-injection can't silently
    # drift from the published tag.
    assert_match version.to_s, shell_output("#{bin}/bithuman-cli --version")
  end
end
