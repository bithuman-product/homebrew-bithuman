# Where each licence text comes from

Every file in this directory except this one and the two notices bitHuman wrote is an upstream file
copied **byte for byte**: never edit one by hand. To update a text, fetch the new upstream file, replace
the copy, and update its row (`test/third_party_licenses_test.dart` fails while a file and its SHA-256
here disagree). The files are Flutter assets of this package (`pubspec.yaml`) and are registered with
`LicenseRegistry` by `lib/src/third_party_licenses.dart`. This file is not an asset.

All texts retrieved 2026-10-04 (UTC).

## Upstream files (verbatim)

| file | sha256 | source | revision |
| --- | --- | --- | --- |
| `supertonic-3/LICENSE` | `0d944a9110fed9a9602d60e0423a272903e7bd21ab060490774efc77c2275e9f` | https://huggingface.co/Supertone/supertonic-3/resolve/main/LICENSE | `3cadd1ee6394adea1bd021217a0e650ede09a323` (the same bytes at https://huggingface.co/supertone-oss-archive/supertonic-3/resolve/main/LICENSE, `aafc6e32416a594460b32413efc49d7fe4ce6d46`) |
| `supertonic/LICENSE` | `0dfe0d0ba84416fe3879d9a34f4909d8d0137c78d1e95834177b0414ac096fa2` | https://raw.githubusercontent.com/supertone-inc/supertonic/main/LICENSE | `1e9799e964ea4c0dad7cde993b65c3c813a7b373` |
| `parakeet-tdt_ctc-110m/LICENSE` | `9ba9550ad48438d0836ddab3da480b3b69ffa0aac7b7878b5a0039e7ab429411` | https://creativecommons.org/licenses/by/4.0/legalcode.txt (the licence the model card names: https://huggingface.co/nvidia/parakeet-tdt_ctc-110m, `license: cc-by-4.0`) | model card `431a349f3051ab85c22b9b7a2741b5fe77065665` |
| `silero-vad/LICENSE` | `2e63e9a38b6e8fc0c7bc37ce174caca1862870856c6daf5697cfb785e925520b` | https://raw.githubusercontent.com/snakers4/silero-vad/master/LICENSE | `1e261b036686cd0017d500ee96acd1c4ba572a9d` |
| `llama-3.2/LICENSE` | `8cc15535a8a34b41888f644b339a1a9eb428af793a4f5e24df58a3e5b1487d74` | https://raw.githubusercontent.com/meta-llama/llama-models/main/models/llama3_2/LICENSE | `0e0b8c519242d5833d8c11bffc1232b77ad7f301` |
| `llama-3.2/USE_POLICY.md` | `40e2777d7faa6beaf98400654170f414d8ab29b921b5163ad4ea0a1d39894201` | https://raw.githubusercontent.com/meta-llama/llama-models/main/models/llama3_2/USE_POLICY.md | `0e0b8c519242d5833d8c11bffc1232b77ad7f301` |
| `sherpa-onnx/LICENSE` | `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30` | https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v1.13.8/LICENSE | tag `v1.13.8` (the tag has no NOTICE file) |
| `kaldi-native-fbank/LICENSE` | `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30` | https://raw.githubusercontent.com/csukuangfj/kaldi-native-fbank/v1.22.3/LICENSE | tag `v1.22.3` (pinned by sherpa-onnx v1.13.8) |
| `kaldi-decoder/LICENSE` | `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30` | https://raw.githubusercontent.com/k2-fsa/kaldi-decoder/v0.3.0/LICENSE | tag `v0.3.0` (pinned by sherpa-onnx v1.13.8) |
| `kaldifst/LICENSE` | `a682d6efd1ee5dee08a8e405c233c2c198ea70ae0718129daa83ab58cfe31c5d` | https://raw.githubusercontent.com/k2-fsa/kaldifst/v1.8.0/LICENSE | tag `v1.8.0` (pinned by kaldi-decoder v0.3.0) |
| `openfst/COPYING` | `4300529197035fd3452350718a0b8cee984e9412c9932d7f35fcde849fc97a4b` | https://raw.githubusercontent.com/csukuangfj/openfst/v1.8.5-2026-07-09/COPYING | tag `v1.8.5-2026-07-09` (pinned by sherpa-onnx v1.13.8) |
| `simple-sentencepiece/LICENSE` | `c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4` | https://raw.githubusercontent.com/pkufool/simple-sentencepiece/v0.7/LICENSE | tag `v0.7` (pinned by sherpa-onnx v1.13.8) |
| `kissfft/COPYING` | `a2840585f8411be8e6826a31ef15ae65c950bd74a2437a73b013398a934ad0c6` | https://raw.githubusercontent.com/mborgerding/kissfft/febd4caeed32e33ad8b2e0bb5ea77542c40f18ec/COPYING | commit `febd4caeed32e33ad8b2e0bb5ea77542c40f18ec` (pinned by kaldi-native-fbank v1.22.3) |
| `kissfft/BSD-3-Clause` | `4d6bcab46f27d6d0c878e8305d4bdcfe040d52bf6656b9771f04c9fb9902c0ed` | https://raw.githubusercontent.com/mborgerding/kissfft/febd4caeed32e33ad8b2e0bb5ea77542c40f18ec/LICENSES/BSD-3-Clause | commit `febd4caeed32e33ad8b2e0bb5ea77542c40f18ec` (upstream path `LICENSES/BSD-3-Clause`, the licence `COPYING` names) |
| `eigen/COPYING.MPL2` | `66a3107d5ad6a058aab753eaac2047ccb2ed0e39465dd0fe5844da3e300d5172` | https://gitlab.com/libeigen/eigen/-/raw/5.0.1/COPYING.MPL2 | tag `5.0.1` (pinned by sherpa-onnx v1.13.8; header-only, unmodified; source: https://gitlab.com/libeigen/eigen) |
| `hclust-cpp/LICENSE` | `e361d842da1d290351860ad6dcce2673a1e42e4f873a3ae1ff4eb92c6adaa882` | https://raw.githubusercontent.com/csukuangfj/hclust-cpp/2026-02-25/LICENSE | tag `2026-02-25` (pinned by sherpa-onnx v1.13.8; the file starts with a UTF-8 byte-order mark, kept) |
| `nlohmann-json/LICENSE.MIT-3.12.0` | `46a65cffd1ea955132d95a8dd921640714a8d6b537d2e4e482d31145ae95b603` | https://raw.githubusercontent.com/nlohmann/json/v3.12.0/LICENSE.MIT | tag `v3.12.0` (pinned by sherpa-onnx v1.13.8) |
| `nlohmann-json/LICENSE.MIT-3.11.3` | `86b998c792894ccb911a1cb7994f7a9652894e7a094c0b5e45be2f553f45cf14` | https://raw.githubusercontent.com/nlohmann/json/v3.11.3/LICENSE.MIT | tag `v3.11.3` (libconverse) |
| `onnxruntime/LICENSE` | `2f07c72751aed99790b8a4869cf2311df85a860b22ded05fa22803587a48922c` | https://raw.githubusercontent.com/microsoft/onnxruntime/v1.28.2/LICENSE | tag `v1.28.2` (the same bytes at `v1.26.0`) |
| `onnxruntime/ThirdPartyNotices.txt` | `0e07b95f3a8d6230037707c5c4a2b554d12c4cb67369669ac255635528ffcee2` | https://raw.githubusercontent.com/microsoft/onnxruntime/v1.28.2/ThirdPartyNotices.txt | tag `v1.28.2` (the same bytes at `v1.26.0`) |
| `llama.cpp/LICENSE` | `94f29bbed6a22c35b992c5c6ebf0e7c92f13b836b90f36f461c9cf2f0f1d010d` | https://raw.githubusercontent.com/ggml-org/llama.cpp/b8110/LICENSE | tag `b8110` (`237958db339300bdd8028608cc08b2ba2685ec33`) |
| `miniaudio/LICENSE` | `457f1b500e0adf6bc059edddfa78a2f62012e7c3bb43476c20e0bd23b25ba0eb` | https://raw.githubusercontent.com/mackron/miniaudio/0.11.22/LICENSE | tag `0.11.22` |

## Notices bitHuman wrote (not licences; edit when the facts change)

| file | what |
| --- | --- |
| `supertonic-3/MODIFICATIONS.txt` | OpenRAIL-M paragraph 4(c): what was changed in the Supertonic 3 files the brain runs (Apple: bitHuman's fp16-storage build; Android: sherpa-onnx's int8 build), by whom and when |
| `parakeet-tdt_ctc-110m/ATTRIBUTION.txt` | CC BY 4.0 Section 3(a): the attribution, the disclaimer notice and the changes (sherpa-onnx's ONNX export + int8 quantization) |
