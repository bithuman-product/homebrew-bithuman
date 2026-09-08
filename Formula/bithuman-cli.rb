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
#   pip install bithuman          # Python SDK (library) -- current (2.10.0)
#   pip install bithuman-cli      # Python CLI bundle -- ★STALE + macOS-ONLY.
#                                 #   2.3.25, 2026-06-05, two files ever, both
#                                 #   py3-none-macosx_11_0_arm64. It exits 1 on
#                                 #   Linux, and on macOS it puts a June
#                                 #   Mach-O `bithuman` (internal version
#                                 #   2.3.6) on PATH that routes local-vs-cloud
#                                 #   from a FILENAME -- the defect cli-v2.5.1
#                                 #   was cut to disarm. Do not advertise it.
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
#   * On-device — set BITHUMAN_LOCAL=1, no API key needed. Requires the
#     whisper.cpp / llama.cpp / Supertonic Python deps; the exact line is
#     in `caveats` below and is resolved against live PyPI by the CLI repo's
#     scripts/check-printed-install-coordinates.sh.
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
  # Current published release: cli-v2.6.4. A key the metering service
  # REJECTS (HTTP 401 / 402 / 403 — revoked, from another environment, out
  # of credits) now gets a grace of 300 s from the first rejection, behind a
  # countdown line once a minute, re-checked every minute; still rejected at
  # 300 s the session STOPS (`run` closes the preview, `render` exits
  # METERING_REFUSED / 77 with no output). A meter that cannot be REACHED
  # (no network, timeout, 5xx) still never stops a render — loud line, keep
  # trying, however long. The same rule and number apply to the Python
  # package, the Apple engine and the Android SDK. Billing is unchanged
  # from 2.6.3 (wall-clock for a live session, clip duration for a render,
  # nothing for a download). Both halves of cli-v2.6.4 were built from ONE
  # commit (01325a3), each tarball's clock is that commit's time, and each
  # tarball's PROVENANCE.json says dirty:false.
  #
  # cli-v2.6.3 (superseded) billed a self-hosted session on WALL-CLOCK
  # while it is live, idle animation included, at the published self-host
  # rate (2 credits per minute) — the pricing page's definition — and an
  # offline `bithuman render` on the duration of the clip it writes. 2.6.2
  # counted frames delivered / fps, which under-counted a live preview on a
  # slow-painting machine (a 90 s essence-2 session on an M4 was recorded
  # as 7.5 s). The live preview also holds its nominal frame rate (2.6.2
  # settled at a third of it on a Mac whose timers coalesce). Both halves
  # from ONE commit (b7a1005).
  #
  # cli-v2.6.2 (superseded) made a self-hosted session on macOS meter at
  # all (the CLI carries the beat where the macOS render tool does not;
  # metering never stops a render — a missing or rejected key is a loud
  # `★ UNMETERED RENDER` line, BITHUMAN_METER_ENFORCE=1 makes it a refusal;
  # a model download is free) and made `run --help` say where a model
  # renders. Both halves from ONE commit (679b9a6).
  #
  # cli-v2.6.1 (superseded) put the essence-2 native runtime
  # INSIDE the tarball (lib/lible_core.dylib, Developer ID signed with
  # the rest), so `bithuman render` and `bithuman run` play a downloaded
  # essence-2 <CODE>.imx locally on Apple Silicon — the thing 2.6.0 refused
  # (exit 69). Measured from the published tarball on a real served avatar:
  # a 5.0 s clip exits 0 with 125 frames, every speech frame with the real
  # mouth. Both halves of cli-v2.6.1 were built from ONE commit (d946a1d).
  #
  # cli-v2.6.0 (superseded) fixed `bithuman render` on
  # macOS, which used to stop short of the end of the audio and refuse the
  # command: measured at five clip lengths on Apple Silicon, three of the five
  # came up as much as 11 frames short. Every length now exits 0 with
  # ceil(seconds x 20) frames and a playable file. It also stops a refused
  # render leaving a partial file at --output, and makes `run` accept the name
  # `pull` hands out. Both halves of cli-v2.6.0 were built from ONE commit
  # (3d69679) and each tarball carries a PROVENANCE.json naming it.
  #
  # cli-v2.5.1 (superseded) was the CLI that had to be installed
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
  # tarball on the same release was cut the same way for cli-v2.6.4 — on
  # lafayette, in the manylinux image, packed by the CLI repo's own
  # scripts/release_pack.sh so both halves carry one commit. This formula
  # stays mac-only, matching 2.4.0/2.4.2.
  #
  # Apple Silicon (arm64). The macOS tarball is self-contained AND ships the
  # expression-2 render engine next to the binary (expression2-model +
  # embody.model blessed 90e4cf31cf71 + engines/mac-arm64-1.0.0.engine), so
  # `bithuman run` renders Wise Pup out of the box with ZERO engine fetch.
  # ★CORRECTED 2026-09-08 — THIS BLOCK DESCRIBED A TARBALL THAT IS FOUR
  # RELEASES OLD. From 2026-09-02 through cli-v2.6.1/2/3/4 it said the macOS
  # tarball "ships NO essence-2 engine … BITHUMAN_TARBALL_NO_ESSENCE2=1" and
  # that `bithuman render <essence-2>.imx` exits "69 UNAVAILABLE naming
  # libessence2.dylib, which is an honest refusal, not a render". cli-v2.6.1
  # vendored the essence-2 runtime into BOTH tarballs; the sentence was never
  # re-measured and survived three formula bumps, because nothing in the tap
  # reads the tarball back.
  #
  # MEASURED 2026-09-08 on the very bytes this formula pins (sha256
  # ed827aaa…), extracted from a quarantined anonymous download on echelon:
  # the tarball ships the essence-2 runtime as `lib/lible_core.dylib`, and
  # `bithuman render <essence-2>.imx -a speech.wav -o out.mp4 --json` returns
  # rc=0 — 300 frames, 1920x1080 @25 fps, on the CLI's own local render path.
  # It is a render, on this machine, with no engine fetch, and the mouth
  # tracks the drive audio. (`libessence2.dylib` is the APPLE/Swift engine — a
  # different artifact on a different axis; it is indeed not in this tarball
  # and the CLI does not use it.)
  # (Engine core stays libessence 2.3.8 / ABI 7 — a separate axis; the
  # version below is scanned from the cli-v* tag in the URL.)
  url "https://github.com/bithuman-product/homebrew-bithuman/releases/download/cli-v2.6.4/bithuman-aarch64-apple-darwin.tar.gz"
  sha256 "ed827aaa0b3918100e6c6776ca0527d7b7cabb8e4618f3ce91ef437f205f1bbc"
  # ★CORRECTED 2026-09-05 — THIS FIELD WAS A LIVE LICENSING MISSTATEMENT.
  # It read `license "Apache-2.0"`, which is what `brew info bithuman-cli`
  # printed to every customer and what every SPDX scanner recorded. The tarball
  # this formula installs is NOT Apache-2.0 and never was:
  #
  #   * the `bithuman` binary STATICALLY LINKS `libessence.a`, built from the
  #     PRIVATE bithuman-product/bithuman-models — no public source, no
  #     Apache grant;
  #   * the tarball vendors proprietary model weights (`expression2-model`,
  #     `embody.model`, `engines/mac-arm64-1.0.0.engine`);
  #   * this repo's own docs/CONSOLIDATION.md §H calls it, in those words, a
  #     "shipped proprietary binary", and measured FFmpeg (LGPL-2.1) statically
  #     linked into it (47 `third_party/ffmpeg/libav*` paths in the published
  #     2.5.1 Linux tarball, against 0 in `expression2-model` and 0 in
  #     `lib/libonnxruntime.so.1` as controls);
  #   * the tarball ships 37 members and not one LICENSE or NOTICE file, so
  #     nothing inside it ever carried an Apache grant either.
  #
  # `:cannot_represent` is Homebrew's own value for a licence with no SPDX
  # identifier, and it is the honest one here. The Apache-2.0 badge on this
  # repo's README covers the TAP and the EXAMPLE code, which really are
  # Apache-2.0 — it does not reach the binary this formula downloads.
  # Terms for the installed software: https://www.bithuman.ai/terms
  license :cannot_represent

  depends_on arch: :arm64
  depends_on macos: :sonoma

  # ★ffmpeg is a RUNTIME REQUIREMENT, and leaving it undeclared broke BOTH of
  # the two commands this formula's own quick-start teaches. MEASURED
  # 2026-09-08 on echelon against the published cli-v2.6.4 macOS tarball,
  # PATH=/usr/bin:/bin:/usr/sbin:/sbin — a Mac that has Homebrew but has not
  # run `brew install ffmpeg`:
  #
  #   $ bithuman run <essence-2>.imx --json
  #   {"error":{"code":"UNAVAILABLE","command":"run", …}}     # rc=69, no serve
  #   $ bithuman render <essence-2>.imx -a a.wav -o out.mp4 --json
  #   {"error":{"code":"UNAVAILABLE","command":"render", …}}  # rc=69, no MP4
  #
  #   GREEN CONTROL — the same `run`, same host, /opt/homebrew/bin back on
  #   PATH: engine loads, "teeth: ready … (1024 references)", and it serves
  #   "essence-2 preview at http://127.0.0.1:8088/".
  #
  # The binary SHELLS OUT to an `ffmpeg` EXECUTABLE (the CLI's cmd/mux.rs):
  # `render` to write the MP4, `run` to expand `target_frames` + `P.f16` at
  # activate. The FFmpeg statically linked into `bithuman` is a decode-only
  # subset — no MP4 muxer, no H.264, no AAC encoder — so it cannot be the
  # sink, and the tarball vendors no `ffmpeg` of its own.
  #
  # This is why the "no runtime deps" rule below does NOT reach it: that rule
  # is about DYLIBS resolved through @loader_path at a fixed soname, where a
  # Homebrew bump can break a linked binary. A subprocess invoked as
  # `ffmpeg -i … out.mp4` has no such coupling — a newer ffmpeg still muxes.
  depends_on "ffmpeg"

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
                                           # (2.6.4 prints the same report with
                                           #  or without ffmpeg; grading it landed
                                           #  on main after 2.6.4 was cut and
                                           #  reaches you in the next release)
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
        On-device (no key, no outbound network):
          pip install 'livekit-agents[silero]~=1.5' supertonic pywhispercpp llama-cpp-python soxr
          BITHUMAN_LOCAL=1 bithuman run <model.imx>
        (llama-cpp-python has no wheel on macOS or Linux and builds from
        source, so this needs a C++ toolchain.)
        ~860 MB models auto-download from HuggingFace on first run.
        Docs: https://docs.bithuman.ai/guides/local-mode

      Avatar metering needs a free bitHuman API key — get one at
      https://www.bithuman.ai/#developer and export it:
        export BITHUMAN_API_KEY=...

      Offline tooling:
        bithuman info   avatar.imx                       # inspect .imx

      `bithuman render` (offline MP4) WORKS on macOS on 2.6.1+.
      ★The paragraph that stood here said the opposite — "does NOT work
      on macOS today … for offline renders use a Linux host" — measured
      2026-09-04 on 2.5.1 and never re-measured. RE-MEASURED 2026-09-08
      on the bytes this formula pins (cli-v2.6.4, arm64), Apple silicon:
        essence-2     rc=0 · 300 frames · 1920x1080 @25 fps
        expression-2  rc=0 · 240 frames · 416x720 @20 fps
      Both audio-driven and both verified frame-by-frame against the
      drive audio. essence-1 is not renderable by this CLI on any
      platform and is unchanged by that.
      Offline renders need ffmpeg on PATH, and this formula installs it
      for you: `depends_on "ffmpeg"` as of the 2026-09-08 revision, which
      serves 2.6.4. If you took the tarball instead of `brew install`,
      run `brew install ffmpeg` yourself.

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
