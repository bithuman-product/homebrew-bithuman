// MODEL_REJECTED on Android (ModelRejection.kt): which create failures are the engine refusing
// the model file — answered as MODEL_REJECTED with the native code and the engine's sentence —
// and which stay the load's ordinary failure. The SDK's exception types are matched by name;
// stand-ins with the same names (and the same supertypes) are declared here.
// Plain JVM, no device:
//   (cd <app>/android && ./gradlew :bithuman:testDebugUnitTest --tests 'ai.bithuman.flutter.ModelRejectionTest')

package ai.bithuman.flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** essence2-android: the meter's refusal IS an IllegalStateException. */
class MeteringRefused(message: String) : IllegalStateException(message)
/** Any other refusal the engine throws at create: an IllegalStateException subclass with its sentence. */
class CreateStepRefused(message: String) : IllegalStateException(message)
class Essence2StoreException(message: String) : RuntimeException(message)
/** expression2-android: one class for the engine's refusal and the meter's. */
class Expression2Exception(message: String) : RuntimeException(message)

class ModelRejectionTest {
    private val outdated = "Renderer: REFUSED for identity 'A52DHS2219' (b1_fp32): this avatar file " +
        "was published before the mouth-corner fix; download it again"

    @Test
    fun an_out_of_date_avatar_file_is_model_rejected_with_the_native_code() {
        val r = ModelRejection.essence2(IllegalStateException(outdated))!!
        assertEquals("essence2", r.engine)
        assertEquals(-4, r.nativeCode)
        assertTrue(r.message, r.message.startsWith("Essence 2 refused the model file (essence2-android create, -4: IllegalStateException): "))
        assertTrue(r.message.contains("REFUSED for identity 'A52DHS2219'"))
        assertEquals(mapOf("engine" to "essence2", "nativeCode" to -4, "message" to r.message), r.details())
        assertEquals("MODEL_REJECTED", ModelRejection.CODE)
    }

    @Test
    fun other_refusals_the_engine_names_are_model_rejected_without_a_number() {
        val members = ModelRejection.essence2(IllegalStateException("REFUSED: this bundle is missing teeth members"))!!
        assertNull(members.nativeCode)
        assertTrue(members.message.contains("REFUSED: this bundle"))
        assertNotNull(ModelRejection.essence2(CreateStepRefused("REFUSED: the teeth members are unreadable")))
        assertNull(ModelRejection.essence2(CreateStepRefused("the GPU queue could not start")))
        assertNotNull(ModelRejection.essence2(Essence2StoreException("the audio frontend would not open over /x: bad graph")))
    }

    @Test
    fun the_credential_the_device_and_the_network_are_not_the_model() {
        // The meter refuses with an IllegalStateException too: it is the credential's problem.
        assertNull(ModelRejection.essence2(MeteringRefused("refusing to serve: REFUSED key (401)")))
        assertNull(ModelRejection.essence2(IllegalStateException("OpenCL: no device could start the renderer")))
        assertNull(ModelRejection.essence2(IllegalArgumentException("not a bundle directory: /x")))
        assertNull(ModelRejection.essence2(Essence2StoreException("the shared audio frontend is missing: /x")))
        assertNull(ModelRejection.essence2(java.net.UnknownHostException("api.bithuman.ai")))
    }

    @Test
    fun expression2_refusals_and_its_meter() {
        val r = ModelRejection.expression2(Expression2Exception("engine create threw: decoder member dec_p2 is unreadable"))!!
        assertEquals("expression2", r.engine)
        assertNull(r.nativeCode)
        assertTrue(r.message, r.message.startsWith("Expression 2 refused the model file (expression2-android create: Expression2Exception): engine create threw"))
        assertNull(ModelRejection.expression2(Expression2Exception("refusing to serve: this account has no credits remaining (402)")))
        assertNull(ModelRejection.expression2(Expression2Exception("out of memory creating the expression-2 engine")))
        assertNull(ModelRejection.expression2(IllegalStateException("REFUSED")))
    }
}
