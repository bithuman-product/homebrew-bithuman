// See README.md. Apache-2.0; (c) bitHuman.
#include <stdexcept>
#include "phonemize.hpp"
namespace piper {
void phonemize_eSpeak(std::string, eSpeakPhonemeConfig &, std::vector<std::vector<Phoneme>> &) {
  throw std::runtime_error("espeak-ng is not part of this build (GPL-free sherpa-onnx; Supertonic only)");
}
}  // namespace piper
