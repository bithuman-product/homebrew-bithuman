#!/bin/bash
# build-sherpa-ios.sh — OPTIONAL: stage sherpa-onnx (the hybrid brain's own speech-to-text on iOS:
# Silero VAD + an offline Parakeet TDT / Moonshine recognizer, SherpaAsr.swift) into
# ios/Vendor/sherpa-onnx/ as a plain static library + its C API header. The podspec turns
# SHERPA_ASR_AVAILABLE on from the staged bytes; without them the app runs Apple's SpeechAnalyzer.
#
# Built from source against the onnxruntime.xcframework THIS pod already vendors (run
# scripts/bootstrap.sh first), with the CoreML EP off and TTS off — so the app links ONE onnxruntime.
# ios-arm64 device slice only (the simulator keeps Apple's recognizer).
#
#   scripts/build-sherpa-ios.sh            # sherpa-onnx v1.13.8, ~4 min on an M-series Mac
#   SHERPA_REF=v1.13.8 SHERPA_SRC=<checkout> scripts/build-sherpa-ios.sh
#
# Licences: sherpa-onnx Apache-2.0; Silero VAD MIT. The MODELS are downloaded by the app, not
# bundled (THIRD_PARTY_NOTICES.md lists them: Parakeet TDT CC-BY-4.0, Moonshine English MIT).
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
REF=${SHERPA_REF:-v1.13.8}
ORTX=$HERE/ios/Frameworks/onnxruntime.xcframework
[ -d "$ORTX/ios-arm64/onnxruntime.framework" ] || { echo "run scripts/bootstrap.sh first (no $ORTX)"; exit 2; }
ORTH=$ORTX/ios-arm64/onnxruntime.framework/Headers
WORK=${SHERPA_WORK:-$HERE/build/sherpa-onnx}
SRC=${SHERPA_SRC:-$WORK/src}
if [ ! -d "$SRC/.git" ] && [ -z "${SHERPA_SRC:-}" ]; then
  mkdir -p "$WORK"
  git clone --depth 1 --branch "$REF" https://github.com/k2-fsa/sherpa-onnx.git "$SRC"
fi
B=$WORK/build-ios-arm64
rm -rf "$B"; mkdir -p "$B"
export SHERPA_ONNXRUNTIME_LIB_DIR=$ORTX/ios-arm64 SHERPA_ONNXRUNTIME_INCLUDE_DIR=$ORTH
cmake -S "$SRC" -B "$B" -DCMAKE_TOOLCHAIN_FILE="$SRC/toolchains/ios.toolchain.cmake" \
  -DPLATFORM=OS64 -DENABLE_BITCODE=0 -DENABLE_ARC=1 -DENABLE_VISIBILITY=0 -DDEPLOYMENT_TARGET=16.0 \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DCMAKE_INSTALL_PREFIX="$B/install" \
  -DSHERPA_ONNX_ENABLE_TTS=OFF -DBUILD_PIPER_PHONMIZE_EXE=OFF -DBUILD_PIPER_PHONMIZE_TESTS=OFF \
  -DBUILD_ESPEAK_NG_EXE=OFF -DBUILD_ESPEAK_NG_TESTS=OFF -DSHERPA_ONNX_ENABLE_PYTHON=OFF \
  -DSHERPA_ONNX_ENABLE_BINARY=OFF -DSHERPA_ONNX_ENABLE_TESTS=OFF -DSHERPA_ONNX_ENABLE_CHECK=OFF \
  -DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF -DSHERPA_ONNX_ENABLE_JNI=OFF -DSHERPA_ONNX_ENABLE_C_API=ON \
  -DSHERPA_ONNX_ENABLE_WEBSOCKET=OFF -DCMAKE_CXX_FLAGS=-DSHERPA_ONNX_DISABLE_COREML > "$WORK/cmake.log" 2>&1
cmake --build "$B" -j "$(sysctl -n hw.ncpu)" > "$WORK/build.log" 2>&1
cmake --build "$B" --target install >> "$WORK/build.log" 2>&1
OUT=$HERE/ios/Vendor/sherpa-onnx
rm -rf "$OUT"; mkdir -p "$OUT/include"
# Every sherpa static archive EXCEPT onnxruntime (the pod's xcframework provides it), merged into one.
libtool -static -o "$OUT/libsherpa-onnx.a" $(ls "$B"/lib/*.a | grep -v onnxruntime) 2>&1 | grep -v "has no symbols" || true
cp "$B/install/include/sherpa-onnx/c-api/c-api.h" "$OUT/include/sherpa_onnx_c_api.h"
echo "$REF" > "$OUT/VERSION"
ls -la "$OUT" "$OUT/include"
echo "staged sherpa-onnx $REF → ios/Vendor/sherpa-onnx (pod install again to pick it up)"
