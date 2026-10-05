package ai.bithuman.flutter

import android.os.Build
import android.util.Log

/**
 * Whether the on-device brain can run here, probed once; [reason] says why not.
 *
 * Its native code is OPT-IN at build time (android/build.gradle): `bithuman.hybridBrain=true` in the
 * app's gradle.properties builds speech in + Supertonic out (libsherpa-onnx-jni.so) — the HYBRID brain,
 * the reply streamed in by the app; `bithuman.localLlm=true` adds llama.cpp (libbhbrain.so) for LOCAL
 * mode's on-device LLM. An app that set neither carries no brain library at all.
 *
 *  - [available]: the brain's speech in/out loads (an arm64 device on Android 10+, built in).
 *  - [llmAvailable]: [available] plus the on-device LLM (replyMode "local", a .gguf).
 */
internal object LocalBrainSupport {
    @Volatile var reason: String = ""
        private set
    @Volatile var llmReason: String = ""
        private set

    private val ok: Boolean by lazy {
        when {
            !BuildConfig.BH_HYBRID_BRAIN -> {
                reason = "the on-device brain is not built into this app: set bithuman.hybridBrain=true " +
                    "(or bithuman.localLlm=true) in its android/gradle.properties"
                false
            }
            Build.VERSION.SDK_INT < 29 -> { reason = "Android ${Build.VERSION.SDK_INT} < 29"; false }
            "arm64-v8a" !in Build.SUPPORTED_ABIS -> { reason = "no arm64-v8a ABI"; false }
            else -> try {
                System.loadLibrary("sherpa-onnx-jni")
                true
            } catch (t: Throwable) {
                reason = "the brain library did not load: ${t.message}"
                Log.w("bhbrain", reason)
                false
            }
        }
    }

    private val llmOk: Boolean by lazy {
        when {
            !ok -> { llmReason = reason; false }
            !BuildConfig.BH_LOCAL_LLM -> {
                llmReason = "this app was built without the on-device LLM: set bithuman.localLlm=true in its " +
                    "android/gradle.properties (the hybrid brain, replyMode \"host\", needs no LLM on the device)"
                false
            }
            else -> try {
                System.loadLibrary("bhbrain")
                true
            } catch (t: Throwable) {
                llmReason = "the on-device LLM library did not load: ${t.message}"
                Log.w("bhbrain", llmReason)
                false
            }
        }
    }

    fun available(): Boolean = ok

    fun llmAvailable(): Boolean = llmOk
}
