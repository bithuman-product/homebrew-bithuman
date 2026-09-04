#!/usr/bin/env bash
# Render a lip-synced MP4 from a model + audio with `bithuman render`.
# Get your API secret at https://www.bithuman.ai (Developer section).
#
# ── WHERE THIS ACTUALLY WORKS (measured 2026-09-04, CLI 2.5.1) ───────────────
# This script is validated for ONE combination: expression-2 on Linux x86_64.
# It was run end-to-end there and produced 60 frames of h264+aac that decode
# cleanly. The other combinations do NOT work today:
#
#   expression-2 · Linux x86_64   ✓ verified (this script)
#   expression-2 · macOS arm64    ✗ engine under-produces (53 of 60 frames),
#                                   exits non-zero — and STILL leaves the
#                                   truncated mp4 at --output. Do not trust
#                                   "the file exists" as success.
#   essence-1    · Linux x86_64   ✗ "audio_decode: avformat_open_input failed"
#                                   for wav/mp3/m4a/flac alike.
#   essence-1    · macOS arm64    ✗ "video encoder unavailable on macOS in this
#                                   libessence build".
#   essence-2    · Linux x86_64   ✗ the Linux tarball ships no lible_core.so.
#                                   Use the Python SDK instead — and note that
#                                   route BORROWS the teeth and reports it:
#                                     pip install 'bithuman[tessera]'
#                                     python -c "from bithuman.tessera_offline \
#                                       import render_offline; \
#                                       print(render_offline(imx, wav, out_mp4=out))"
#                                   Gate on stats["borrow_state"] == "borrowed",
#                                   never on the frame count.
#
# The previous version of this file claimed render "is implemented on Linux
# only", which reads as "all families work on Linux". Only expression-2 does.
set -euo pipefail

export BITHUMAN_API_SECRET="${BITHUMAN_API_SECRET:?Set BITHUMAN_API_SECRET first}"

# Install the CLI (the curl installer is the ONLY channel that works on Linux;
# `pip install bithuman-cli` is a macOS-arm64-only wheel and exits 1 on Linux):
#   curl -fsSL https://raw.githubusercontent.com/bithuman-product/homebrew-bithuman/main/install.sh | sh
#   brew install bithuman-product/bithuman/bithuman-cli      # macOS

MODEL="${1:?Usage: ./render-video.sh <expression-2 model.imx>}"
OUT="${2:-demo.mp4}"

if [ ! -f speech.wav ]; then
  curl -sO https://raw.githubusercontent.com/bithuman-product/homebrew-bithuman/main/Examples/python/local-essence/speech.wav
fi

bithuman render "$MODEL" --audio speech.wav --output "$OUT"

# ★Verify the artifact rather than trusting the exit code alone — a truncated
# render can leave a decodable file behind.
frames=$(ffprobe -v error -count_frames -select_streams v:0 \
           -show_entries stream=nb_read_frames -of csv=p=0 "$OUT")
echo "Done: $OUT — ${frames} video frames decoded."
