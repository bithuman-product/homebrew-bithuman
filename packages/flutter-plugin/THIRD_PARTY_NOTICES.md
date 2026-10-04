# Third-party notices — the on-device brain (LOCAL mode)

LOCAL mode (`LocalConverseTransport`) runs a conversation entirely on the
device: Apple SpeechAnalyzer (speech to text, part of the OS) → an LLM through
llama.cpp → the Supertonic voice through ONNX Runtime. The native brain,
`libconverse.xcframework`, is built from bitHuman's libconverse and links the
code below. The **models** are downloaded by your app (see
`LocalBrainModels` in `lib/src/local_brain.dart`); their licenses apply to your
app and its users.

**The full texts.** Every licence below is in [`licenses/`](licenses/), copied byte for byte from
upstream ([`licenses/SOURCES.md`](licenses/SOURCES.md) gives each file's source URL, revision,
retrieval date and SHA-256). The plugin registers them with Flutter's `LicenseRegistry` when the
app starts (`BithumanLicenses`, `lib/src/third_party_licenses.dart`), so the app's licence page
(`showLicensePage`) lists them with no code. Two files there are notices bitHuman wrote, not
licences: [`licenses/supertonic-3/MODIFICATIONS.txt`](licenses/supertonic-3/MODIFICATIONS.txt)
(Open RAIL-M paragraph 4(c)) and
[`licenses/parakeet-tdt_ctc-110m/ATTRIBUTION.txt`](licenses/parakeet-tdt_ctc-110m/ATTRIBUTION.txt)
(CC BY 4.0 Section 3(a)).

## Code in libconverse.xcframework

| Component | Version | License |
|---|---|---|
| [llama.cpp](https://github.com/ggml-org/llama.cpp) incl. ggml (Metal, CPU, BLAS backends) | b8110 (`237958db3`), linked statically | MIT — Copyright (c) 2023-2024 The ggml authors |
| [Supertonic](https://github.com/supertone-inc/supertonic) C++ inference helper | `1e9799e9` | MIT — Copyright (c) 2025 Supertone Inc. |
| [nlohmann/json](https://github.com/nlohmann/json) | 3.11.3 | MIT — Copyright (c) 2013-2022 Niels Lohmann |
| [miniaudio](https://github.com/mackron/miniaudio) (resampler) | 0.11.22 | Public domain (Unlicense) or MIT-0 — David Reid |
| [ONNX Runtime](https://github.com/microsoft/onnxruntime) (linked by the app) | — | MIT — Copyright (c) Microsoft Corporation |

No GPL code is linked. The voice needs no phonemizer (no espeak-ng).

## Models your app downloads

### Llama 3.2 1B Instruct — Llama 3.2 Community License

* License: <https://www.llama.com/llama3_2/license/> · Acceptable Use Policy:
  <https://www.llama.com/llama3_2/use-policy/>
* Your app must display **"Built with Llama"** prominently — in its user
  interface, About page, website or documentation
  (`LocalBrainNotices.builtWithLlama`).
* If you redistribute the model file, include a copy of the license and this
  notice (`LocalBrainNotices.llamaNotice`):
  "Llama 3.2 is licensed under the Llama 3.2 Community License, Copyright © Meta
  Platforms, Inc. All Rights Reserved."
* Use must comply with the Acceptable Use Policy.

### Supertonic 3 voice — BigScience OpenRAIL-M

* License: <https://huggingface.co/supertone-oss-archive/supertonic-3/blob/main/LICENSE>
  (BigScience Open RAIL-M, dated 2022-08-18).
* The **use restrictions in its Attachment A must be passed on to your end
  users**: include them as an enforceable provision of your terms of use and
  let users know about them (§4(a)); give recipients a copy of the license
  (§4(b)).
* `LocalBrainModels` lists a half-precision *storage* build of the four ONNX
  graphs (weights stored as float16 and converted back to float32 when loaded).
  These are modified files: each graph records the modification in its ONNX
  metadata (`bithuman.modification`), as §4(c) requires.
* The Android brain runs sherpa-onnx's int8 build of Supertonic 3
  (`sherpa-onnx-supertonic-3-tts-int8-2026-05-11`), also a modified version.
* Both modifications are described, with who made them and when, in
  [`licenses/supertonic-3/MODIFICATIONS.txt`](licenses/supertonic-3/MODIFICATIONS.txt), the
  notice paragraph 4(c) asks for; the licence page shows it with the licence.
  `BithumanLicenses.supertonicAttachmentA()` returns Attachment A verbatim for your terms (see the
  README, "Licences of on-device models").

## The hybrid brain's speech-to-text on iOS (optional: `scripts/build-sherpa-ios.sh`)

| Component | Version | License |
|---|---|---|
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) C API (static, no TTS, no CoreML EP) | v1.13.8 | Apache-2.0 — Copyright (c) Xiaomi Corporation and the k2-fsa authors |
| [kaldi-native-fbank](https://github.com/csukuangfj/kaldi-native-fbank) | v1.22.3 | Apache-2.0 |
| [KISS FFT](https://github.com/mborgerding/kissfft) (linked by kaldi-native-fbank) | `febd4cae` | BSD-3-Clause — Copyright (c) 2003-2010 Mark Borgerding |
| [kaldi-decoder](https://github.com/k2-fsa/kaldi-decoder), [kaldifst](https://github.com/k2-fsa/kaldifst) | v0.3.0, v1.8.0 | Apache-2.0 |
| [OpenFst](https://github.com/csukuangfj/openfst) (subset) | v1.8.5-2026-07-09 | Apache-2.0 |
| [simple-sentencepiece](https://github.com/pkufool/simple-sentencepiece) | v0.7 | Apache-2.0 |
| [Eigen](https://gitlab.com/libeigen/eigen) (header-only, unmodified) | 5.0.1 | MPL-2.0 |
| [hclust-cpp](https://github.com/csukuangfj/hclust-cpp) (fastcluster) | 2026-02-25 | BSD-2-Clause |
| [nlohmann/json](https://github.com/nlohmann/json) | v3.12.0 | MIT |

Versions are the ones sherpa-onnx v1.13.8 pins. The Android brain builds the same sherpa-onnx
(with TTS, without espeak-ng) and links ONNX Runtime 1.28.2 statically.

Models the app downloads for it:

* **NVIDIA Parakeet TDT-CTC 110M** (`nvidia/parakeet-tdt_ctc-110m`, int8 ONNX export by sherpa-onnx:
  `sherpa-onnx-nemo-parakeet_tdt_transducer_110m-en-36000-int8`) — **CC BY 4.0**: commercial use
  allowed with attribution ("Parakeet TDT-CTC 110M © NVIDIA Corporation, CC BY 4.0"), e.g. in the
  app's About / licences page. The attribution, the change note (sherpa-onnx's ONNX export and int8
  quantization) and the licence are on the licence page already
  ([`licenses/parakeet-tdt_ctc-110m/`](licenses/parakeet-tdt_ctc-110m/)).
* **Silero VAD** (`silero_vad.onnx`) — MIT, Copyright (c) 2020-present Silero Team.
* (Alternative) **Moonshine** English models — MIT. Moonshine's NON-English models are under the
  Moonshine Community License, which is **non-commercial**: do not ship those.

