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
  version "0.8.0"
  url "https://github.com/bithuman-product/homebrew-bithuman/releases/download/v#{version}/bithuman-cli-#{version}.zip"
  sha256 "af774167d672af8828f52b1c453533aee3746b3b0e1b463fe282107572f2d5d5"
  license "Apache-2.0"

  depends_on macos: :tahoe
  depends_on arch: :arm64

  def install
    # The release zip layout is flat: the binary plus its sibling
    # resource bundles + frameworks all live at the top level. MLX's
    # bundle lookup is RELATIVE to the binary, and libwebrtc loads
    # WebRTC.framework via `@executable_path` rpath, so we install
    # everything into libexec and put a tiny exec-wrapper in bin so
    # the binary's runtime neighbours are still next to it after
    # Homebrew links. (As of 0.7.0, `*.framework` covers libwebrtc
    # for the new `voice --openai` backend.)
    libexec.install Dir["bithuman-cli", "*.bundle", "*.framework"]
    (bin/"bithuman-cli").write <<~EOS
      #!/bin/bash
      exec "#{libexec}/bithuman-cli" "$@"
    EOS
    (bin/"bithuman-cli").chmod 0755
  end

  test do
    # --help exits 0 with non-trivial output. Mic permissions can't
    # be granted from `brew test`, so a real boot is out of scope.
    assert_match "bithuman-cli", shell_output("#{bin}/bithuman-cli --help")
  end
end
