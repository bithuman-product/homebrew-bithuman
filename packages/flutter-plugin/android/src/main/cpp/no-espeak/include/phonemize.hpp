// Stand-in declarations (see ../README.md): the piper-phonemize types sherpa-onnx v1.13.8 uses.
#ifndef BH_NO_PIPER_PHONEMIZE_HPP_
#define BH_NO_PIPER_PHONEMIZE_HPP_
#include <map>
#include <memory>
#include <string>
#include <vector>
namespace piper {
typedef char32_t Phoneme;
typedef std::map<Phoneme, std::vector<Phoneme>> PhonemeMap;
struct eSpeakPhonemeConfig {
  std::string voice = "en-us";
  Phoneme period = U'.';
  Phoneme comma = U',';
  Phoneme question = U'?';
  Phoneme exclamation = U'!';
  Phoneme colon = U':';
  Phoneme semicolon = U';';
  Phoneme space = U' ';
  bool keepLanguageFlags = false;
  std::shared_ptr<PhonemeMap> phonemeMap;
};
/* Always throws std::runtime_error: espeak-ng is not part of this build. */
void phonemize_eSpeak(std::string text, eSpeakPhonemeConfig &config,
                      std::vector<std::vector<Phoneme>> &phonemes);
}  // namespace piper
#endif
