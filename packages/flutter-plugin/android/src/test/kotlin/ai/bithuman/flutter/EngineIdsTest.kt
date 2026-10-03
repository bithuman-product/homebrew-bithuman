// The engine names load(engine:) accepts on Android (EngineIds.kt). Plain JVM, no device.
//
// Run from any Flutter app that depends on this plugin:
//   packages/flutter-plugin/scripts/test_android_unit.sh <app dir>

package ai.bithuman.flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class EngineIdsTest {

    @Test fun thePublicModelIds_areAccepted() {
        assertEquals(EngineIds.ESSENCE2, EngineIds.canonical("essence-2"))
        assertEquals(EngineIds.EXPRESSION2, EngineIds.canonical("expression-2"))
    }

    @Test fun thePluginSlugs_stillWork() {
        assertEquals(EngineIds.ESSENCE2, EngineIds.canonical("essence2"))
        assertEquals(EngineIds.ESSENCE2, EngineIds.canonical("elevate"))
        assertEquals(EngineIds.EXPRESSION2, EngineIds.canonical("expression2"))
        assertEquals(EngineIds.EXPRESSION2, EngineIds.canonical("embody"))
    }

    /** The Dart default until 2.6.36 ('essence') names no engine: refused by name, never guessed. */
    @Test fun anUnknownName_isRefused() {
        assertNull(EngineIds.canonical("essence"))
        assertNull(EngineIds.canonical("essence-1"))
        assertNull(EngineIds.canonical(""))
        assertTrue(EngineIds.unknownMessage("essence").contains("'essence'"))
    }
}
