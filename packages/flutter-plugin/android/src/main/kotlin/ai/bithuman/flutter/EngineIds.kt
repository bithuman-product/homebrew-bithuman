// The engine names `BithumanAvatar.load(engine:)` accepts on Android (2.6.36).
//
// The public model ids `essence-2` and `expression-2` were refused here (`unsupported`) while the Apple
// half and the Dart registry accepted them. This is the same table as the Apple half's EngineRegistry:
// the canonical slug plus every alias it accepts. Plain JVM: EngineIdsTest runs it without a device.

package ai.bithuman.flutter

internal object EngineIds {
    const val ESSENCE2 = "essence2"
    const val EXPRESSION2 = "expression2"

    private val essence2 = setOf(ESSENCE2, "essence-2", "elevate", "essence-2-light", "essence-2-mobile")
    private val expression2 = setOf(EXPRESSION2, "expression-2", "embody")

    /** The canonical slug for [engine], or null when no engine on Android has that name. */
    fun canonical(engine: String): String? = when (engine) {
        in essence2 -> ESSENCE2
        in expression2 -> EXPRESSION2
        else -> null
    }

    /** The `unsupported` message for a name [canonical] does not know. */
    fun unknownMessage(engine: String): String =
        "unknown engine '$engine': pass engine: 'expression2' or 'essence2' (also accepted: 'expression-2', 'essence-2'); " +
            "on Android 'path' is the agent code (e.g. A23WJF0199)"
}
