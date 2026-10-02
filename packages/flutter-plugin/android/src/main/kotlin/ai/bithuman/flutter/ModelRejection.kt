// MODEL_REJECTED (2.6.29): the engine refused to create from the model file. The load answers
// with this code — never the generic `load_failed` — so the app hears one typed, terminal error
// (`BithumanModelRejected` in Dart; the same code a realtime session reports) carrying the
// engine's native code and its own sentence. Kept free of Android and of the SDK types (they
// are matched by name) so the classification is tested on the JVM (ModelRejectionTest).
package ai.bithuman.flutter

class ModelRejection(val engine: String, val nativeCode: Int?, val message: String) {
    /** The `details` of the platform error (Dart: `BithumanModelRejected.fromMap`). */
    fun details(): Map<String, Any?> = mapOf("engine" to engine, "nativeCode" to nativeCode, "message" to message)

    companion object {
        const val CODE = "MODEL_REJECTED"
        /** The sentence the engine refuses an out-of-date avatar file with (Apple: be_essence2_create -4). */
        private const val OUTDATED = "REFUSED for identity '"
        /** Apple's be_essence2_create code for the same refusal; Android's engine says it in words only. */
        const val ESSENCE2_OUTDATED = -4

        /**
         * [t], thrown by `Essence2Avatar.create`, as a model refusal — or null when it is not one.
         * The engine refuses a bundle BY NAME: `nativeCreate` (and every step of the engine's
         * create) throws an IllegalStateException whose sentence says REFUSED (an out-of-date
         * avatar file: "… REFUSED for identity '<code>' …"; a bundle missing members: "REFUSED:
         * this bundle is …"). A metering refusal is an
         * IllegalStateException TOO (`MeteringRefused`) — the credential's problem, not the
         * file's — and stays out, as does any other IllegalStateException (a device that could
         * not start the renderer is not the file's fault either). The audio frontend refusing to
         * open over the bundle is the store's exception with a fixed opening. Anything else (no
         * bundle directory, the network) is the load's ordinary failure.
         */
        fun essence2(t: Throwable): ModelRejection? {
            val m = t.message.orEmpty()
            val refused = when {
                t.isNamed("MeteringRefused") -> false
                t is IllegalStateException -> m.contains("REFUSED")
                t.isNamed("Essence2StoreException") && m.startsWith("the audio frontend would not open") -> true
                else -> false
            }
            if (!refused) return null
            val code = if (m.contains(OUTDATED)) ESSENCE2_OUTDATED else null
            return ModelRejection("essence2", code,
                "Essence 2 refused the model file (essence2-android create${code?.let { ", $it" } ?: ""}: " +
                    "${t.javaClass.simpleName}): ${m.ifBlank { "no reason given" }}")
        }

        /**
         * [t], thrown by `Expression2Avatar.create`, as a model refusal — or null. The engine's
         * refusal is an `Expression2Exception` with its own words; the meter's is the same class
         * and always opens "refusing to serve" (the credential, not the file); an out-of-memory
         * create is the device's.
         */
        fun expression2(t: Throwable): ModelRejection? {
            val m = t.message.orEmpty()
            if (!t.isNamed("Expression2Exception")) return null
            if (m.startsWith("refusing to serve") || m.contains("out of memory") || m.contains("is closed") ||
                m.startsWith("interrupted")) return null
            return ModelRejection("expression2", null,
                "Expression 2 refused the model file (expression2-android create: ${t.javaClass.simpleName}): " +
                    m.ifBlank { "no reason given" })
        }

        private fun Throwable.isNamed(simpleName: String): Boolean {
            var c: Class<*>? = javaClass
            while (c != null) { if (c.simpleName == simpleName) return true; c = c.superclass }
            return false
        }
    }
}

/** A load that ended in the engine refusing the model: answered as [ModelRejection.CODE]. */
class ModelRejectedException(val rejection: ModelRejection, cause: Throwable) : Exception(rejection.message, cause)
