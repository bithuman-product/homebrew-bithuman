# no-espeak — build sherpa-onnx's TTS without espeak-ng (GPL-3.0)

sherpa-onnx's `SHERPA_ONNX_ENABLE_TTS` switch pulls in espeak-ng (GPL-3.0) and piper-phonemize
for its VITS/Piper, Kokoro, Matcha and Kitten voices. The brain uses only **Supertonic**, which
reads raw text through its own unicode indexer and never phonemizes. These two CMake modules are
placed FIRST on `CMAKE_MODULE_PATH` when sherpa-onnx is configured (sherpa only appends its own
`cmake/` dir), so its `include(espeak-ng-for-piper)` / `include(piper-phonemize)` resolve here and
build these stand-ins instead: the API sherpa compiles against (`espeak_Initialize`,
`AUDIO_OUTPUT_SYNCHRONOUS`, `piper::phonemize_eSpeak` and four piper types), with no-op
implementations. No espeak-ng or piper-phonemize code is compiled or linked. A VITS/Kokoro/Matcha
model would fail to initialise; Supertonic, the recognizers and the VAD are untouched.

Written for this plugin (Apache-2.0). The declarations mirror the public API of espeak-ng and of
piper-phonemize (MIT) only as far as sherpa-onnx v1.13.8 uses it.
