package ai.bithuman.flutter

import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.security.MessageDigest
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * The owner's offline window on Android (2.6.36, security).
 *
 * On Android the plugin loads an avatar by code, and the SDK's model store keeps it. From
 * essence2-android 0.9.4 and expression2-android 0.6.0 (bithuman-models #1827 / #1828) a cache hit needs
 * the store's entitlement mark for the credential, but that mark never expires: with the door down it
 * opens the cached avatar for as long as the mark exists. The owner's rule (2026-10-03) is the one the
 * Dart caches enforce (lib/src/door_gate.dart): an account reopens its own avatar with the door down for
 * up to 24 h after the door last said yes to its credential, and never past that without asking.
 *
 * So the plugin keeps its own record of the door's last yes per (model, code, credential), under
 * `<filesDir>/bithuman/door-auth/`, and checks it BEFORE the store is asked:
 *  * a yes within 24 h: the load goes on at once (the store's own mark still gates the cache hit), and
 *    the door is asked again in the background: its yes renews the record, its no drops it;
 *  * no record, or an older one: the door is asked first. Its yes writes the record; its no (401, 403,
 *    or 404 `NOT_FOUND`) fails the load with `entitlement_refused`; no answer (offline, a timeout, a 5xx,
 *    404 `MODEL_ARTIFACT_NOT_READY`) fails it with `entitlement_unconfirmed` (fail closed).
 *
 * Every Android load carries a credential (both engines refuse a load without one), so the 7-day window
 * for a public avatar (a yes to a request with NO credential) never applies here: a keyed yes is 24 h,
 * as it is in the Dart caches.
 *
 * The record holds the time of the yes, sealed with an HMAC keyed by the credential, under the native
 * stores' credential tag (32 hex of SHA-256 over "bithuman.door.auth.v1\0" + the credential). The
 * credential itself is never written. A record that does not verify, or is dated more than five minutes
 * ahead of the clock, counts as none.
 *
 * The door is the platform's: `GET https://api.bithuman.ai/v1/agent/<code>/model/download?model=<model>&redirect=false`,
 * owner-scoped (another account's key gets 404 NOT_FOUND), the key in the `api-secret` header,
 * redirects not followed. One request; the file is never fetched here.
 *
 * ★WHO MAY OPEN, AS THE STORES SEE IT (PR #202 round 3). The platform lets an account render an avatar it
 * owns, one shared into a workspace it is an active member of, or a public / featured one (P11, platform
 * #1324). The container door above serves the first two and bitHuman's showcase; another account's PUBLIC
 * avatar outside the showcase gets 404 NOT_FOUND there, while the member door the stores fetch from
 * (`&member=web_manifest.json` for Expression 2, `&member=android_store.v1.json&plane=android` for
 * Essence 2) serves it to any credential. So a 404 NOT_FOUND from the container door is asked again, once,
 * at the store's member door ([publicDoor]): its yes is a yes (what the store itself would fetch); anything
 * else leaves the container's no, so the record is dropped (fail closed). When the member door did not
 * answer (a 5xx, a 429, a timeout) the load still fails as `entitlement_unconfirmed`, not
 * `entitlement_refused`: the avatar may be public, and the next load asks again. Through 2.6.35 the stores
 * loaded such an avatar; this window does not narrow that.
 */
internal class EntitlementWindow(
    private val dir: File,
    private val clock: () -> Long = { System.currentTimeMillis() },
    /** The container door; null: bitHuman's ([platformDoor]). */
    door: ((code: String, model: String) -> URL)? = null,
    private val timeoutMs: Int = 20_000,
    private val background: (Runnable) -> Unit = { r -> Thread(r, "bh-door-auth").apply { isDaemon = true }.start() },
    /**
     * The store's member door for a PUBLIC avatar (see the class note). Null: bitHuman's ([storeDoor]) when
     * [door] is bitHuman's too, and none for a window on another door (a test's loopback), so a test never
     * reaches the real door by accident.
     */
    publicDoor: ((code: String, model: String) -> URL?)? = null,
) {
    private val door: (code: String, model: String) -> URL = door ?: { c, m -> platformDoor(c, m) }
    private val publicDoor: (code: String, model: String) -> URL? =
        publicDoor ?: if (door == null) { c, m -> storeDoor(c, m) } else { _, _ -> null }

    /** The door refused ([refused] true) or could not be asked when the record was missing or too old. */
    class Refused(message: String, val refused: Boolean, val status: Int?) : Exception(message) {
        /** The method-channel error code the Dart side maps to BithumanEntitlementException. */
        val channelCode: String get() = if (refused) "entitlement_refused" else "entitlement_unconfirmed"
    }

    /**
     * What the door answered one request, or that it could not be asked ([status] null). [memberUnanswered]:
     * set on the container door's "not yours" when the member door asked next did not answer ([askEntitled]);
     * the answer is still the container's no (the record follows it), only the refusal's wording changes.
     */
    data class Answer(val status: Int?, val code: String? = null, val error: Throwable? = null, val memberUnanswered: Answer? = null) {
        /** 2xx (the JSON grant), or a 3xx to the signed file URL. */
        val granted: Boolean get() = status != null && status in 200..399
        /** 401/403, or 404 with error.code NOT_FOUND. Not a no: 404 MODEL_ARTIFACT_NOT_READY, a 5xx. */
        val denied: Boolean get() = status == 401 || status == 403 || (status == 404 && code == "NOT_FOUND")
        override fun toString(): String =
            if (status == null) "no answer (${error?.javaClass?.simpleName}: ${error?.message})"
            else "HTTP $status${code?.let { " $it" } ?: ""}${memberUnanswered?.let { "; the public-avatar door: $it" } ?: ""}"
    }

    private val renewing = HashSet<String>()

    /**
     * Returns when [credential] may open [code]'s [model] now; throws [Refused] when it may not. A fresh
     * record answers at once (and the door is asked in the background); otherwise the door is asked first.
     */
    fun admit(code: String, model: String, credential: String) {
        if (fresh(code, model, credential)) {
            val k = "$model|$code|${credentialTag(credential)}"
            val start = synchronized(renewing) { renewing.add(k) }
            if (start) background(Runnable {
                try { renew(code, model, credential) } catch (_: Throwable) {} finally { synchronized(renewing) { renewing.remove(k) } }
            })
            return
        }
        val a = renew(code, model, credential)
        if (!a.granted) throw refusal(code, model, a)
    }

    /** One door ask with [credential]: its yes (re)writes the record, its no drops it, no answer leaves it. */
    fun renew(code: String, model: String, credential: String): Answer {
        val a = askEntitled(code, model, credential)
        when {
            a.granted -> write(code, model, credential)
            a.denied -> drop(code, model, credential)
        }
        return a
    }

    /** True when the door said yes to [credential] for [code]'s [model] within the last 24 h. */
    fun fresh(code: String, model: String, credential: String): Boolean {
        val tag = credentialTag(credential)
        val entry = entry(code, model)
        val lines = try { markFile(code, model, credential).readText().split('\n') } catch (_: Exception) { return false }
        if (lines.size != 5 || lines[0] != "v1" || lines[1] != entry || lines[2] != tag) return false
        val checked = lines[3].toLongOrNull() ?: return false
        val want = seal(credential, code, model, tag, checked)
        if (!MessageDigest.isEqual(want.toByteArray(), lines[4].toByteArray())) return false
        val now = clock()
        if (checked > now + FUTURE_SKEW_MS) return false
        return now - checked <= OWN_WINDOW_MS
    }

    /** Where [credential]'s record for [code]'s [model] lives (tests). */
    fun markFile(code: String, model: String, credential: String): File =
        File(dir, "${safe(model)}/${safe(code)}/${credentialTag(credential)}")

    private fun write(code: String, model: String, credential: String) {
        try {
            val f = markFile(code, model, credential)
            f.parentFile?.mkdirs()
            val tag = credentialTag(credential)
            val entry = entry(code, model)
            val at = clock()
            val tmp = File(f.path + ".tmp")
            tmp.writeText("v1\n$entry\n$tag\n$at\n${seal(credential, code, model, tag, at)}")
            if (!tmp.renameTo(f)) { f.delete(); tmp.renameTo(f) }
        } catch (_: Exception) {
            // Best effort: no record means the next load asks the door first.
        }
    }

    private fun drop(code: String, model: String, credential: String) {
        try { markFile(code, model, credential).delete() } catch (_: Exception) {}
    }

    /**
     * The container door's answer, and for its 404 NOT_FOUND the store's member door's (a PUBLIC avatar
     * outside the showcase; see the class note): its yes is the answer; anything else leaves the container's
     * no, so [renew] drops the record (fail closed: a member door that is down, rate limited or slow never
     * keeps a record the container door just took away). A no-answer rides along as [Answer.memberUnanswered]
     * for the refusal's wording. A 401 / 403 is about the key and is not asked again.
     */
    fun askEntitled(code: String, model: String, credential: String): Answer {
        val a = ask(code, model, credential)
        if (!(a.denied && a.status == 404)) return a
        val pub = publicDoor(code, model) ?: return a
        val m = askUrl(pub, credential)
        return when {
            m.granted -> m
            m.denied -> a
            else -> a.copy(memberUnanswered = m)
        }
    }

    /** One GET of [code]'s container door with exactly [credential], redirects not followed. Never throws. */
    fun ask(code: String, model: String, credential: String): Answer = askUrl(door(code, model), credential)

    /** One GET of [url] with exactly [credential], redirects not followed. Never throws. */
    fun askUrl(url: URL, credential: String): Answer {
        var c: HttpURLConnection? = null
        return try {
            c = (url.openConnection() as HttpURLConnection).apply {
                instanceFollowRedirects = false
                connectTimeout = timeoutMs
                readTimeout = timeoutMs
                requestMethod = "GET"
                setRequestProperty("api-secret", credential)
            }
            val status = c.responseCode
            // A redirect is the door's yes only when it points at the signed file URL the door minted: https,
            // off the asked host and off bitHuman's door hosts, compared as DNS compares names (case, a
            // trailing dot); the Dart gate's rule, door_gate.dart `ask`.
            if (status in 300..399) {
                val asked = c.url
                val next = c.getHeaderField("Location")?.takeIf { it.isNotEmpty() }?.let { runCatching { URL(asked, it) }.getOrNull() }
                if (next == null || next.protocol != "https" || normalizeHost(next.host) == normalizeHost(asked.host) ||
                    normalizeHost(next.host) in DOOR_HOSTS) {
                    return Answer(null, error = IllegalStateException("HTTP $status to ${next?.host ?: "no location"}: a redirect within bitHuman's door hosts (or not https) is no answer"))
                }
            }
            var errorCode: String? = null
            if (status == 401 || status == 403 || status == 404) {
                val body = try {
                    (c.errorStream ?: c.inputStream)?.use { s ->
                        val buf = ByteArray(4096); var n = 0
                        while (n < buf.size) { val r = s.read(buf, n, buf.size - n); if (r < 0) break; n += r }
                        String(buf, 0, n, Charsets.UTF_8)
                    } ?: ""
                } catch (_: Exception) { "" }
                errorCode = CODE.find(body)?.groupValues?.get(1)
            }
            Answer(status, errorCode)
        } catch (e: Exception) {
            Answer(null, error = e)
        } finally {
            try { c?.disconnect() } catch (_: Exception) {}
        }
    }

    private fun refusal(code: String, model: String, a: Answer): Refused =
        if (a.denied && a.memberUnanswered == null) Refused(
            "$model:$code: bitHuman refused this credential for this avatar ($a). A private avatar opens only " +
                "for the account that owns it; pass that account's apiSecret (the copy kept on this device was not opened)",
            refused = true, status = a.status)
        else Refused(
            "$model:$code: bitHuman could not confirm that this credential may open this avatar ($a), and the " +
                "door has not said yes to it in the last 24 h. Try again online",
            refused = false, status = a.status)

    companion object {
        /** An account's own avatar: how long after the door's last yes it opens with the door down. */
        const val OWN_WINDOW_MS: Long = 24L * 3600 * 1000

        /** A record dated further ahead of the clock than this is not believed. */
        const val FUTURE_SKEW_MS: Long = 5L * 60 * 1000

        /** bitHuman's door hosts: a redirect to one of them is never a door's yes. */
        val DOOR_HOSTS: Set<String> = setOf("api.bithuman.ai", "www.bithuman.ai", "bithuman.ai")

        private val CODE = Regex("\"code\"\\s*:\\s*\"([A-Za-z0-9_]+)\"")

        /** The native stores' (and the Dart caches') credential tag: never the credential. */
        fun credentialTag(credential: String?): String {
            val d = MessageDigest.getInstance("SHA-256").digest("bithuman.door.auth.v1\u0000${credential ?: ""}".toByteArray(Charsets.UTF_8))
            return d.joinToString("") { "%02x".format(it) }.substring(0, 32)
        }

        fun platformDoor(code: String, model: String): URL =
            URL("https://api.bithuman.ai/v1/agent/${URLEncoder.encode(code, "UTF-8")}/model/download" +
                "?model=${URLEncoder.encode(model, "UTF-8")}&redirect=false")

        /**
         * The member door [model]'s store fetches its catalog from (expression2-android
         * `MeteredDoorResolver`: `member=web_manifest.json`; essence2-android: `member=android_store.v1.json`
         * on `plane=android`), asked for a JSON grant. Null for a model with no store.
         */
        fun storeDoor(code: String, model: String): URL? {
            val member = when (model) {
                "expression-2" -> "member=web_manifest.json"
                "essence-2" -> "member=android_store.v1.json&plane=android"
                else -> return null
            }
            return URL("https://api.bithuman.ai/v1/agent/${URLEncoder.encode(code, "UTF-8")}/model/download" +
                "?model=${URLEncoder.encode(model, "UTF-8")}&$member&redirect=false")
        }

        /** [host] as DNS compares it: lower case, without the root's trailing dot. */
        fun normalizeHost(host: String): String = host.lowercase(java.util.Locale.ROOT).trimEnd('.')

        private fun safe(s: String) = s.replace(Regex("[^A-Za-z0-9_-]"), "_")
        private fun entry(code: String, model: String) = "${safe(model)}/${safe(code)}"

        /**
         * The record's seal: an HMAC keyed by the credential over the RAW model and code (not the file-name-safe
         * [entry], so two codes that spell the same safe name never share a seal), the tag and the time.
         */
        private fun seal(credential: String, code: String, model: String, tag: String, checkedMs: Long): String {
            val mac = Mac.getInstance("HmacSHA256")
            mac.init(SecretKeySpec("bithuman.door.mark.v1\u0000$credential".toByteArray(Charsets.UTF_8), "HmacSHA256"))
            return mac.doFinal("v2\n$model\u0000$code\n$tag\n$checkedMs\n0".toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it) }
        }
    }
}
