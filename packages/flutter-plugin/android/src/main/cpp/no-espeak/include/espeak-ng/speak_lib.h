// Stand-in declarations (see ../../README.md): only what sherpa-onnx v1.13.8 references.
#ifndef BH_NO_ESPEAK_SPEAK_LIB_H_
#define BH_NO_ESPEAK_SPEAK_LIB_H_
#ifdef __cplusplus
extern "C" {
#endif
typedef enum {
  AUDIO_OUTPUT_PLAYBACK,
  AUDIO_OUTPUT_RETRIEVAL,
  AUDIO_OUTPUT_SYNCHRONOUS,
  AUDIO_OUTPUT_SYNCH_PLAYBACK
} espeak_AUDIO_OUTPUT;
/* Always fails (returns -1): espeak-ng is not part of this build. */
int espeak_Initialize(espeak_AUDIO_OUTPUT output, int buflength, const char *path, int options);
#ifdef __cplusplus
}
#endif
#endif
