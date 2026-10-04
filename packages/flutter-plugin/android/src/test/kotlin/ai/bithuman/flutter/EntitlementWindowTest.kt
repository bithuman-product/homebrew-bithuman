// The owner's offline window on Android (2.6.36, security; EntitlementWindow.kt): the door's last yes to a
// credential opens a code's avatar for 24 h with the door down, never past that, and never for another
// account. A loopback socket stands in for bitHuman's owner-scoped door (the bodies are production's,
// 2026-10-03; the JDK's com.sun HttpServer is not on Android's unit-test classpath). Plain JVM, no device,
// no real network.
//
// Run from any Flutter app that depends on this plugin:
//   (cd <app>/android && ./gradlew :bithuman:testDebugUnitTest --tests 'ai.bithuman.flutter.EntitlementWindowTest')
// or packages/flutter-plugin/scripts/test_android_unit.sh <app dir>.

package ai.bithuman.flutter

import java.io.File
import java.net.InetAddress
import java.net.ServerSocket
import java.net.SocketException
import java.net.URL
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test

class EntitlementWindowTest {
    private val owner = "sk_test_owner"
    private val other = "sk_test_other"
    private val code = "A99LTC2401"
    private val notFound = """{"error": {"code": "NOT_FOUND", "message": "Agent not found for code: A99LTC2401", "httpStatus": 404}, "status": "error", "status_code": 404}"""
    private val notReady = """{"error": {"code": "MODEL_ARTIFACT_NOT_READY", "message": "not downloadable yet", "httpStatus": 404}}"""

    private lateinit var dir: File
    private lateinit var server: ServerSocket
    private var now = 1_791_000_000_000L
    /** What the door answers: (status, body, Location) for the request's key. */
    private var rule: (String?) -> Triple<Int, String, String?> = ::ownerScoped
    /** What the store's member door (a request with `member=`) answers; null: the same [rule]. */
    private var memberRule: ((String?) -> Triple<Int, String, String?>)? = null
    private val asked = ArrayList<String?>()
    /** Each request's path and query, in order. */
    private val targets = ArrayList<String>()
    private val background = ArrayList<Runnable>()
    private var dead = 0

    private fun ownerScoped(key: String?): Triple<Int, String, String?> = when (key) {
        owner -> Triple(200, """{"success": true, "data": {"url": "https://example.invalid/x"}}""", null)
        null -> Triple(401, """{"error": {"code": "MISSING_AUTH"}}""", null)
        else -> Triple(404, notFound, null)
    }

    @Before
    fun setUp() {
        dir = Files.createTempDirectory("entitlement_window").toFile()
        server = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
        // One request per connection: read the head, answer by the rule, close.
        Thread({
            while (true) {
                val sock = try { server.accept() } catch (_: SocketException) { break }
                sock.use { c ->
                    val r = c.getInputStream().bufferedReader(Charsets.ISO_8859_1)
                    var key: String? = null
                    val target = (r.readLine() ?: "").split(' ').getOrElse(1) { "" }
                    while (true) {
                        val line = r.readLine() ?: break
                        if (line.isEmpty()) break
                        val i = line.indexOf(':')
                        if (i > 0 && line.substring(0, i).trim().equals("api-secret", ignoreCase = true)) key = line.substring(i + 1).trim()
                    }
                    synchronized(asked) { asked += key; targets += target }
                    val (status, body, location) = (if (target.contains("member=")) memberRule else null)?.invoke(key) ?: rule(key)
                    val bytes = body.toByteArray()
                    val head = StringBuilder("HTTP/1.1 $status X\r\nContent-Type: application/json\r\nContent-Length: ${bytes.size}\r\nConnection: close\r\n")
                    if (location != null) head.append("Location: $location\r\n")
                    head.append("\r\n")
                    c.getOutputStream().apply { write(head.toString().toByteArray(Charsets.ISO_8859_1)); write(bytes); flush() }
                }
            }
        }, "door").apply { isDaemon = true }.start()
        dead = ServerSocket(0).use { it.localPort }
    }

    @After
    fun tearDown() {
        server.close()
        dir.deleteRecursively()
    }

    private fun window(up: Boolean = true, member: Boolean = false) = EntitlementWindow(
        dir,
        clock = { now },
        door = { c, m -> URL("http://127.0.0.1:${if (up) server.localPort else dead}/v1/agent/$c/model/download?model=$m&redirect=false") },
        timeoutMs = 3_000,
        background = { r -> background += r },
        // The store's member door on the same loopback (the plugin's is EntitlementWindow.storeDoor).
        publicDoor = if (!member) null else { c, m ->
            URL("http://127.0.0.1:${if (up) server.localPort else dead}/v1/agent/$c/model/download?model=$m&member=catalog&redirect=false")
        },
    )

    private fun refused(expectRefused: Boolean, block: () -> Unit) {
        try {
            block()
            fail("expected EntitlementWindow.Refused(refused=$expectRefused)")
        } catch (e: EntitlementWindow.Refused) {
            assertEquals(expectRefused, e.refused)
            assertEquals(if (expectRefused) "entitlement_refused" else "entitlement_unconfirmed", e.channelCode)
        }
    }

    @Test
    fun anotherAccountIsRefusedAfterOneDoorAskAndGetsNoRecord() {
        window().admit(code, "essence-2", owner)
        refused(true) { window().admit(code, "essence-2", other) }
        assertEquals(listOf(owner, other), synchronized(asked) { asked.toList() })
        assertFalse(window().markFile(code, "essence-2", other).exists())
        // ...and with the door down, the other account (no record) fails closed.
        refused(false) { window(up = false).admit(code, "essence-2", other) }
    }

    @Test
    fun theOwnerOpensWithTheDoorDownFor24hAfterTheDoorsYesThenFailsClosed() {
        window().admit(code, "expression-2", owner)
        now += 23 * 3600_000L
        window(up = false).admit(code, "expression-2", owner)   // fresh: no ask before the load
        assertEquals("one ask in the background, none before", 1, background.size)
        background.forEach { it.run() }   // the door is down: the record keeps its age
        now += 2 * 3600_000L   // 25 h
        refused(false) { window(up = false).admit(code, "expression-2", owner) }
        // Online again: the door's yes opens and renews the 24 h.
        window().admit(code, "expression-2", owner)
        now += 20 * 3600_000L
        window(up = false).admit(code, "expression-2", owner)
    }

    @Test
    fun aFreshRecordAsksInTheBackgroundAndTheDoorsNoDropsIt() {
        window().admit(code, "essence-2", owner)
        rule = { Triple(401, """{"error": {"code": "MISSING_AUTH"}}""", null) }   // the key was revoked
        window().admit(code, "essence-2", owner)
        background.forEach { it.run() }
        assertFalse(window().fresh(code, "essence-2", owner))
        refused(true) { window().admit(code, "essence-2", owner) }
    }

    @Test
    fun notReadyAnOutageOrAStorageAnswerAreNotANo() {
        window().admit(code, "essence-2", owner)
        rule = { Triple(404, notReady, null) }
        window().renew(code, "essence-2", owner)
        assertTrue("MODEL_ARTIFACT_NOT_READY keeps the record", window().fresh(code, "essence-2", owner))
        rule = { Triple(503, "", null) }
        window().renew(code, "essence-2", owner)
        assertTrue(window().fresh(code, "essence-2", owner))
    }

    @Test
    fun aRedirectWithinBitHumansDoorHostsIsNoAnswerOneOffThemIsAYes() {
        rule = { Triple(307, "", "https://www.bithuman.ai/api/agents/$code/model/download") }
        val a = window().ask(code, "essence-2", other)
        assertNull(a.status)
        assertFalse(a.granted)
        refused(false) { window().admit(code, "essence-2", other) }
        rule = { Triple(308, "", "/v1/agent/$code/model/download") }   // the same host (a trailing slash)
        refused(false) { window().admit(code, "essence-2", other) }
        rule = { Triple(302, "", "https://storage.example.invalid/signed/x.imx") }   // the signed file URL
        window().admit(code, "essence-2", owner)
        assertTrue(window().fresh(code, "essence-2", owner))
    }

    @Test
    fun aTamperedCopiedOrFutureDatedRecordCountsAsNone() {
        window().admit(code, "essence-2", owner)
        val mark = window().markFile(code, "essence-2", owner)
        val original = mark.readText()
        // Re-dated: the seal breaks.
        val lines = original.split('\n').toMutableList()
        lines[3] = (now + 3600_000L).toString()
        mark.writeText(lines.joinToString("\n"))
        assertFalse(window().fresh(code, "essence-2", owner))
        // Copied under another credential's name: does not verify for it.
        mark.writeText(original)
        window().markFile(code, "essence-2", other).apply { parentFile?.mkdirs(); writeText(original) }
        assertFalse(window().fresh(code, "essence-2", other))
        refused(false) { window(up = false).admit(code, "essence-2", other) }
        // Copied to another code: does not verify there.
        window().markFile("A11AAA0001", "essence-2", owner).apply { parentFile?.mkdirs(); writeText(original) }
        assertFalse(window().fresh("A11AAA0001", "essence-2", owner))
        // Sealed correctly but dated a day ahead of the clock (written 25 h on: past the window, so asked).
        now += 25 * 3600_000L
        window().admit(code, "essence-2", owner)
        now -= 25 * 3600_000L
        assertFalse(window().fresh(code, "essence-2", owner))
    }

    @Test
    fun theRecordIsTheNativeStoresTagAndTheCredentialIsNeverWritten() {
        // sha256("bithuman.door.auth.v1\0sk_test_owner")[:32]: essence2-android 0.9.4, the Dart gate, Swift.
        assertEquals("6aa0c9c2b25dc45d3ab28b9b311939b2", EntitlementWindow.credentialTag(owner))
        window().admit(code, "essence-2", owner)
        val all = dir.walkTopDown().filter { it.isFile }.joinToString("\n") { it.path + "\n" + it.readText() }
        assertFalse(all.contains(owner))
        assertTrue(window().markFile(code, "essence-2", owner).path.endsWith("/essence-2/$code/6aa0c9c2b25dc45d3ab28b9b311939b2"))
    }

    // ── PR #202 round 3: the platform's own rule for who may render (P11, platform #1324) ──────────────────────
    // The container door serves an avatar to its owner, a member of the workspace it is shared into, and
    // bitHuman's showcase; another account's PUBLIC avatar outside the showcase is 404 NOT_FOUND there, while
    // the member door the stores fetch from serves it to any credential. The window asks that door once.

    @Test
    fun anotherAccountsPublicAvatarOpensWhenTheStoresMemberDoorSaysYes() {
        memberRule = { Triple(200, """{"success": true, "data": {"url": "https://example.invalid/m"}}""", null) }
        window(member = true).admit(code, "expression-2", other)
        assertTrue(window(member = true).fresh(code, "expression-2", other))
        val t = synchronized(asked) { targets.toList() }
        assertEquals(2, t.size)
        assertFalse("the container door first", t[0].contains("member="))
        assertTrue("then the member door, once", t[1].contains("member="))
        assertEquals(listOf(other, other), synchronized(asked) { asked.toList() })
    }

    @Test
    fun theMemberDoorsNoKeepsTheContainersNoAndNoAnswerIsUnconfirmed() {
        memberRule = { Triple(404, notFound, null) }   // not public: a private avatar of another account
        refused(true) { window(member = true).admit(code, "essence-2", other) }
        assertFalse(window(member = true).markFile(code, "essence-2", other).exists())
        memberRule = { Triple(503, "", null) }
        refused(false) { window(member = true).admit(code, "essence-2", other) }
        // A revoked key (401 at the container) is about the key: the member door is not asked.
        rule = { Triple(401, """{"error": {"code": "MISSING_AUTH"}}""", null) }
        memberRule = { Triple(200, "{}", null) }
        val before = synchronized(asked) { targets.size }
        refused(true) { window(member = true).admit(code, "essence-2", other) }
        assertEquals(before + 1, synchronized(asked) { targets.size })
    }

    @Test
    fun theOwnersYesNeverAsksTheMemberDoorAndAWindowOnAnotherDoorHasNone() {
        memberRule = { Triple(200, "{}", null) }
        window(member = true).admit(code, "essence-2", owner)
        assertEquals(1, synchronized(asked) { targets.size })
        // No publicDoor given with a test door: the container's no is the answer (never the real door).
        refused(true) { window().admit(code, "essence-2", other) }
        assertEquals(2, synchronized(asked) { targets.size })
    }

    @Test
    fun theDoorsTheWindowAsksAreTheStoresOwn() {
        assertEquals("https://api.bithuman.ai/v1/agent/A23WJF0199/model/download?model=expression-2&redirect=false",
            EntitlementWindow.platformDoor("A23WJF0199", "expression-2").toString())
        assertEquals("https://api.bithuman.ai/v1/agent/A23WJF0199/model/download?model=expression-2&member=web_manifest.json&redirect=false",
            EntitlementWindow.storeDoor("A23WJF0199", "expression-2").toString())
        assertEquals("https://api.bithuman.ai/v1/agent/A52DHS2219/model/download?model=essence-2&member=android_store.v1.json&plane=android&redirect=false",
            EntitlementWindow.storeDoor("A52DHS2219", "essence-2").toString())
        assertNull(EntitlementWindow.storeDoor("A52DHS2219", "essence-1"))
    }

    @Test
    fun hostsCompareAsDnsNamesAndOnlyAnHttpsRedirectIsAYes() {
        for (loc in listOf(
            "https://WWW.BITHUMAN.AI/api/agents/$code/model/download",   // letter case
            "https://www.bithuman.ai./api/agents/$code/model/download",  // the root's trailing dot
            "https://Api.Bithuman.Ai./v1/agent/$code/model/download",
            "http://storage.example.invalid/signed/x.imx",                // cleartext, off the door hosts
        )) {
            rule = { Triple(307, "", loc) }
            assertNull(loc, window().ask(code, "essence-2", owner).status)
            refused(false) { window().admit(code, "essence-2", other) }
        }
        assertEquals("api.bithuman.ai", EntitlementWindow.normalizeHost("API.Bithuman.AI."))
        rule = { Triple(302, "", "https://storage.example.invalid/signed/x.imx") }
        window().admit(code, "essence-2", owner)
        assertTrue(window().fresh(code, "essence-2", owner))
    }
}
