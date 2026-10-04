package ai.bithuman.flutter

import java.util.concurrent.atomic.AtomicLong

/**
 * Whose credential an engine is created with, on Android (2.6.36, security; PR #202 round 3).
 *
 * The engines read the process-wide credential (`Expression2Credential`, `Essence2Credential`) once, when
 * they are created: the meter arms in `Expression2Avatar.create` / `Essence2Avatar.create` and bills every
 * frame after that to that key. The stores do not need it: each load builds its store with its own
 * `MeteredDoorResolver(secret)`. Until round 3 a load set the process-wide value FIRST, before the door was
 * asked and before a fetch that can take minutes, so:
 *  * account A's first load still downloading, sign-out, account B signs in and loads (the value is now
 *    B's), A's fetch finishes and A's avatar is created with B's key: billed to B, idle time included;
 *  * a load the door refused left the value set to its key.
 *
 * Now the value is set only by [create], immediately before the engine is created, inside one lock (so a
 * second load cannot set its own between this load's set and its create), and only when no
 * [clear] came since the load began ([begin]: a generation number [clear] bumps). A clear that comes while
 * the engine is being created closes it the moment it exists. Either way the load ends with
 * [Cleared], which the plugin answers as `load_cancelled`. [clear] also cancels every load still running
 * (their fetches stop at the next read) and never waits for the lock, so sign-out never blocks the
 * platform thread behind an engine being created.
 *
 * Because [clear] takes no lock, it can land between [create]'s generation check and its set: the set then
 * writes the signed-out key after [clear] emptied the process-wide credentials. So [create] checks the
 * generation again right after the set and, on a clear, empties them again ([clearGlobals]) under the lock
 * before it throws [Cleared] (PR #202 round-3 review LOW): the signed-out key never stays in the
 * process-wide credential, where a host app's own use of the native SDK (its default store or meter) would
 * act as that account.
 */
internal class LoadCredentials(
    /** Empties the process-wide credentials (`Expression2Credential`, `Essence2Credential`). */
    private val clearGlobals: () -> Unit,
) {
    private val lock = Any()
    private val generation = AtomicLong(0)

    /** The load could not keep its credential: the app cleared the credentials while it ran. */
    class Cleared(message: String) : Exception(message)

    /** Call when a load begins (on the platform thread, in call order with [clear]). */
    fun begin(): Long = generation.get()

    /**
     * Sign-out: every load begun before this never creates an engine with its credential; [cancelLoads]
     * stops the ones still running, [clearGlobals] empties the process-wide credentials. No lock.
     */
    fun clear(cancelLoads: () -> Unit) {
        generation.incrementAndGet()
        cancelLoads()
        clearGlobals()
    }

    /**
     * Sets the load's credential ([set]) and creates its engine ([create]) under the lock, only if no
     * [clear] came since [gen]. A clear that lands just before the set (it takes no lock) is caught right
     * after it: the process-wide credentials are emptied again and nothing is created. A clear during
     * [create] closes the engine ([close]). Either way the load throws [Cleared].
     */
    fun <A> create(gen: Long, set: () -> Unit, create: () -> A, close: (A) -> Unit): A = synchronized(lock) {
        if (generation.get() != gen) throw Cleared(CLEARED)
        set()
        if (generation.get() != gen) {
            // [clear] ran between the check above and the set: the set wrote the signed-out key back.
            clearGlobals()
            throw Cleared(CLEARED)
        }
        val a = create()
        if (generation.get() != gen) {
            runCatching { close(a) }
            throw Cleared(CLEARED)
        }
        a
    }

    companion object {
        const val CLEARED = "the app cleared the credentials (BithumanAvatar.clearCredentials) while this load ran: " +
            "it was cancelled, and nothing was created or billed with its credential"
    }
}

/**
 * The order of one Android load (both engines), as a function the unit tests drive with fakes:
 *  1. a load without a credential is refused, before anything is asked or fetched;
 *  2. the owner's offline window ([admit], EntitlementWindow): the door's yes for THIS credential;
 *  3. the store's fetch ([fetch]), with this load's own resolver, never the process-wide credential;
 *  4. the process-wide credential set to this load's ([setCredential]) and the engine created ([create]),
 *     under [credentials] ([LoadCredentials.create]).
 * A refusal at any step leaves the process-wide credential untouched.
 */
internal fun <M, A> loadInOrder(
    code: String,
    model: String,
    secret: String?,
    gen: Long,
    credentials: LoadCredentials,
    admit: (code: String, model: String, secret: String) -> Unit,
    fetch: (secret: String) -> M,
    setCredential: (secret: String) -> Unit,
    create: (M) -> A,
    close: (A) -> Unit,
    blankMessage: String,
): A {
    if (secret.isNullOrBlank()) throw IllegalArgumentException(blankMessage)
    admit(code, model, secret)
    val fetched = fetch(secret)
    return credentials.create(gen, { setCredential(secret) }, { create(fetched) }, close)
}
