// Stand-in declarations (see ../README.md): the piper-phonemize types sherpa-onnx v1.13.8 uses.
#ifndef BH_NO_PIPER_PHONEME_IDS_HPP_
#define BH_NO_PIPER_PHONEME_IDS_HPP_
#include <cstdint>
#include <map>
#include <memory>
#include <vector>
#include "phonemize.hpp"
namespace piper {
typedef int64_t PhonemeId;
typedef std::map<Phoneme, std::vector<PhonemeId>> PhonemeIdMap;
struct PhonemeIdConfig {
  Phoneme pad = U'_';
  Phoneme bos = U'^';
  Phoneme eos = U'$';
  bool interspersePad = true;
  bool addBos = true;
  bool addEos = true;
  std::shared_ptr<PhonemeIdMap> phonemeIdMap;
};
}  // namespace piper
#endif
