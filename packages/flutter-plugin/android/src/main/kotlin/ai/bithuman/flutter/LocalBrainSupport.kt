package ai.bithuman.flutter

import android.os.Build
import android.util.Log

/**
 * Whether LOCAL mode can run here: an arm64 device on Android 10+ whose two brain
 * libraries load (libbhbrain.so — llama.cpp; libsherpa-onnx-jni.so — speech in/out).
 * Probed once; [reason] says why not.
 */
internal object LocalBrainSupport {
    @Volatile var reason: String = ""
        private set

    private val ok: Boolean by lazy {
        when {
            Build.VERSION.SDK_INT < 29 -> { reason = "Android ${Build.VERSION.SDK_INT} < 29"; false }
            "arm64-v8a" !in Build.SUPPORTED_ABIS -> { reason = "no arm64-v8a ABI"; false }
            else -> try {
                System.loadLibrary("sherpa-onnx-jni")
                System.loadLibrary("bhbrain")
                true
            } catch (t: Throwable) {
                reason = "brain libraries did not load: ${t.message}"
                Log.w("bhbrain", reason)
                false
            }
        }
    }

    fun available(): Boolean = ok
}
