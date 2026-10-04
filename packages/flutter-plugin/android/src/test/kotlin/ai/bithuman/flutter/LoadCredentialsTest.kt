// Whose credential an Android engine is created with (2.6.36, security; PR #202 round 3; LoadCredentials.kt).
//
// The engines read the process-wide credential once, at create (the meter arms there and bills every frame
// after it to that key). These arms drive `loadInOrder` and `LoadCredentials` with fakes for the window, the
// store, the setter and the engine, as BithumanPlugin's loadExpression2 / loadEssence2 do:
//  * a load without a credential is refused before anything is asked, fetched or set;
//  * the order is window -> fetch (with the load's own credential) -> set -> create, and a refusal at any step
//    leaves the process-wide credential untouched;
//  * sign-out (clear) while a load runs: that load never sets its credential or creates an engine, and an
//    engine it created meanwhile is closed; a later account's credential is never overwritten by it;
//  * set + create are one step under a lock: a second load cannot slip its credential in between.
// Plain JVM, no device.

package ai.bithuman.flutter

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class LoadCredentialsTest {
    /** The process-wide credential (Expression2Credential / Essence2Credential). */
    @Volatile private var global: String? = null
    private val steps = ArrayList<String>()
    private val closed = ArrayList<String>()
    private val credentials = LoadCredentials()

    private class Refusal : Exception("the window refused")

    /** One load, as the plugin runs it; [created] is the credential the fake engine was armed with. */
    private fun load(
        secret: String?,
        gen: Long = credentials.begin(),
        admit: (String) -> Unit = {},
        duringFetch: () -> Unit = {},
        duringCreate: () -> Unit = {},
    ): String = loadInOrder("A99LTC2401", "expression-2", secret, gen, credentials,
        admit = { _, _, s -> synchronized(steps) { steps += "admit:$s" }; admit(s) },
        fetch = { s -> synchronized(steps) { steps += "fetch:$s" }; duringFetch(); "model-of-$s" },
        setCredential = { s -> synchronized(steps) { steps += "set:$s" }; global = s },
        // The engine arms its meter with the process-wide credential as create begins.
        create = { m -> synchronized(steps) { steps += "create:$m" }; val armed = "engine armed with $global"; duringCreate(); armed },
        close = { a -> synchronized(closed) { closed += a } },
        blankMessage = "needs the app's credential")

    private fun cleared(block: () -> Unit) {
        try {
            block()
            fail("expected LoadCredentials.Cleared")
        } catch (e: LoadCredentials.Cleared) {
            assertTrue(e.message!!.contains("clearCredentials"))
        }
    }

    private fun clear() = credentials.clear(cancelLoads = { synchronized(steps) { steps += "cancel" } }, clearGlobals = { global = null })

    @Test
    fun aLoadWithoutACredentialIsRefusedBeforeAnythingIsAskedFetchedOrSet() {
        global = "sk_earlier_account"
        for (blank in listOf(null, "", "  ")) {
            try {
                load(blank)
                fail("expected IllegalArgumentException")
            } catch (e: IllegalArgumentException) {
                assertEquals("needs the app's credential", e.message)
            }
        }
        assertEquals(emptyList<String>(), steps)
        assertEquals("the earlier account's credential is not used, and not touched", "sk_earlier_account", global)
    }

    @Test
    fun theWindowThenTheFetchWithTheLoadsOwnCredentialThenSetAndCreate() {
        val engine = load("sk_a")
        assertEquals(listOf("admit:sk_a", "fetch:sk_a", "set:sk_a", "create:model-of-sk_a"), steps)
        assertEquals("engine armed with sk_a", engine)
        assertEquals("sk_a", global)
    }

    @Test
    fun aRefusedLoadNeverSetsItsCredentialOrFetches() {
        global = "sk_b"
        try {
            load("sk_a", admit = { throw Refusal() })
            fail("expected the window's refusal")
        } catch (_: Refusal) {}
        assertEquals(listOf("admit:sk_a"), steps)
        assertEquals("the window's refusal leaves the process-wide credential as it was", "sk_b", global)
        // A fetch that fails (the store refused, offline) leaves it too.
        steps.clear()
        try {
            load("sk_a", duringFetch = { throw IllegalStateException("404 Agent not found") })
            fail("expected the fetch's failure")
        } catch (_: IllegalStateException) {}
        assertEquals(listOf("admit:sk_a", "fetch:sk_a"), steps)
        assertEquals("sk_b", global)
    }

    @Test
    fun signOutDuringAFetchCancelsTheLoadAndALaterAccountKeepsItsCredential() {
        // A's first load is still downloading; sign-out; B signs in and loads (the global is now B's); A's
        // fetch finishes. Through round 2 A's avatar was then created with B's key (billed to B).
        val genA = credentials.begin()
        cleared {
            load("sk_a", gen = genA, duringFetch = {
                clear()
                assertEquals("engine armed with sk_b", load("sk_b"))
            })
        }
        assertEquals("B's credential is not overwritten by A's load", "sk_b", global)
        assertTrue("A never set its credential", "set:sk_a" !in steps)
        assertTrue("A created no engine", "create:model-of-sk_a" !in steps)
        assertTrue("the running loads were cancelled", "cancel" in steps)
    }

    @Test
    fun signOutWhileTheEngineIsBeingCreatedClosesIt() {
        cleared { load("sk_a", duringCreate = { clear() }) }
        assertEquals(listOf("engine armed with sk_a"), closed)
        assertNull("sign-out cleared the credential", global)
    }

    @Test
    fun aLoadBegunAfterSignOutRuns() {
        load("sk_a")
        clear()
        assertNull(global)
        assertEquals("engine armed with sk_b", load("sk_b"))
    }

    @Test
    fun setAndCreateAreOneStepUnderTheLock() {
        // Load A is inside create (its credential set) when load B reaches its own set: B waits for A's create
        // to return, so A's engine is armed with A's credential, never B's.
        val aInCreate = CountDownLatch(1)
        val releaseA = CountDownLatch(1)
        var armedA: String? = null
        val a = Thread {
            armedA = load("sk_a", duringCreate = {
                aInCreate.countDown()
                releaseA.await(5, TimeUnit.SECONDS)
            })
        }.apply { start() }
        assertTrue(aInCreate.await(5, TimeUnit.SECONDS))
        var armedB: String? = null
        val b = Thread { armedB = load("sk_b") }.apply { start() }
        b.join(300)
        assertTrue("B waits while A creates", b.isAlive)
        assertEquals("sk_a", global)
        releaseA.countDown()
        a.join(5000); b.join(5000)
        assertEquals("engine armed with sk_a", armedA)
        assertEquals("engine armed with sk_b", armedB)
        // Sign-out never waits for the lock (it would block the platform thread behind an engine create).
        val inCreate = CountDownLatch(1)
        val release = CountDownLatch(1)
        val c = Thread {
            try { load("sk_c", duringCreate = { inCreate.countDown(); release.await(5, TimeUnit.SECONDS) }) } catch (_: LoadCredentials.Cleared) {}
        }.apply { start() }
        assertTrue(inCreate.await(5, TimeUnit.SECONDS))
        val t = System.nanoTime()
        clear()
        assertTrue("clear returned while a create held the lock", (System.nanoTime() - t) < 1_000_000_000L)
        release.countDown()
        c.join(5000)
        assertTrue("the engine created across the sign-out was closed", closed.contains("engine armed with sk_c"))
    }
}
