package ai.bithuman.flutter.brain

import com.k2fsa.sherpa.onnx.FeatureConfig
import com.k2fsa.sherpa.onnx.OfflineModelConfig
import com.k2fsa.sherpa.onnx.OfflineMoonshineModelConfig
import com.k2fsa.sherpa.onnx.OfflineNemoEncDecCtcModelConfig
import com.k2fsa.sherpa.onnx.OfflineRecognizerConfig
import com.k2fsa.sherpa.onnx.OfflineTransducerModelConfig
import com.k2fsa.sherpa.onnx.OfflineWhisperModelConfig
import java.io.File

/**
 * The speech-to-text model of the on-device brain, picked by what its directory holds — so a
 * different model is a different download, not a different build. Every layout is sherpa-onnx's
 * own export (the `asr-models` release); int8 files are preferred when both are present.
 *
 *   moonshine     preprocess.onnx encode.int8.onnx uncached_decode.int8.onnx cached_decode.int8.onnx tokens.txt
 *   moonshine-v2  encoder_model.ort decoder_model_merged.ort tokens.txt          (Moonshine, 2026-02 export)
 *   whisper       <n>-encoder[.int8].onnx <n>-decoder[.int8].onnx <n>-tokens.txt
 *   transducer    encoder[.int8].onnx decoder[.int8].onnx joiner[.int8].onnx tokens.txt
 *                 (NVIDIA Parakeet / NeMo when the directory name says nemo or parakeet)
 *   nemo-ctc      model[.int8].onnx tokens.txt
 *
 * The VAD (silero_vad.onnx) sits in the same directory.
 */
internal object SpeechIn {
    data class Model(val kind: String, val config: OfflineRecognizerConfig)

    fun detect(dir: String, threads: Int, sampleRate: Int = ConverseEngine.INPUT_SAMPLE_RATE): Model {
        val d = File(dir)
        require(d.isDirectory) { "missing speech-to-text model directory: $dir" }
        val names = d.list()?.toSet() ?: emptySet()
        fun pick(vararg candidates: String): String? = candidates.firstOrNull { it in names }?.let { File(d, it).path }
        fun need(p: String?, what: String): String = requireNotNull(p) { "missing $what in $dir" }
        fun pickGlob(suffixes: List<String>): String? =
            suffixes.firstNotNullOfOrNull { suf -> names.sorted().firstOrNull { it.endsWith(suf) } }?.let { File(d, it).path }
        val feat = FeatureConfig(sampleRate = sampleRate, featureDim = 80)
        val nemo = d.name.contains("nemo", true) || d.name.contains("parakeet", true)
        val (kind, mc) = when {
            "encoder_model.ort" in names && "decoder_model_merged.ort" in names -> "moonshine-v2" to OfflineModelConfig(
                moonshine = OfflineMoonshineModelConfig(
                    encoder = File(d, "encoder_model.ort").path,
                    mergedDecoder = File(d, "decoder_model_merged.ort").path),
                tokens = need(pick("tokens.txt"), "tokens.txt"))
            "preprocess.onnx" in names -> "moonshine" to OfflineModelConfig(
                moonshine = OfflineMoonshineModelConfig(
                    preprocessor = File(d, "preprocess.onnx").path,
                    encoder = need(pick("encode.int8.onnx", "encode.onnx"), "encode.onnx"),
                    uncachedDecoder = need(pick("uncached_decode.int8.onnx", "uncached_decode.onnx"), "uncached_decode.onnx"),
                    cachedDecoder = need(pick("cached_decode.int8.onnx", "cached_decode.onnx"), "cached_decode.onnx")),
                tokens = need(pick("tokens.txt"), "tokens.txt"))
            names.any { it.endsWith("-encoder.int8.onnx") || it.endsWith("-encoder.onnx") } -> "whisper" to OfflineModelConfig(
                whisper = OfflineWhisperModelConfig(
                    encoder = need(pickGlob(listOf("-encoder.int8.onnx", "-encoder.onnx")), "whisper encoder"),
                    decoder = need(pickGlob(listOf("-decoder.int8.onnx", "-decoder.onnx")), "whisper decoder"),
                    language = "en", task = "transcribe"),
                tokens = need(pickGlob(listOf("-tokens.txt", "tokens.txt")), "whisper tokens"))
            names.any { it.startsWith("joiner") } -> (if (nemo) "nemo-transducer" else "transducer") to OfflineModelConfig(
                transducer = OfflineTransducerModelConfig(
                    encoder = need(pickGlob(listOf("encoder.int8.onnx", "encoder.onnx")), "encoder"),
                    decoder = need(pickGlob(listOf("decoder.int8.onnx", "decoder.onnx")), "decoder"),
                    joiner = need(pickGlob(listOf("joiner.int8.onnx", "joiner.onnx")), "joiner")),
                modelType = if (nemo) "nemo_transducer" else "",
                tokens = need(pick("tokens.txt"), "tokens.txt"))
            "model.int8.onnx" in names || "model.onnx" in names -> "nemo-ctc" to OfflineModelConfig(
                nemo = OfflineNemoEncDecCtcModelConfig(model = need(pick("model.int8.onnx", "model.onnx"), "model.onnx")),
                tokens = need(pick("tokens.txt"), "tokens.txt"))
            else -> error("no speech-to-text model recognised in $dir (${names.sorted().take(8)})")
        }
        mc.numThreads = threads
        return Model(kind, OfflineRecognizerConfig(featConfig = feat, modelConfig = mc))
    }
}
