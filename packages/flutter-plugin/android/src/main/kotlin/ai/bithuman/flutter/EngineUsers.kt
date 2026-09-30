// The threads that use an engine, and the one order in which an engine may be let go of:
// stop them, JOIN them, then close it. Nothing here imports Android or Flutter, so the rule
// runs on a plain JVM (src/test/kotlin/ai/bithuman/flutter/EngineUsersTest.kt).
//
// ★WHY (2.6.23). `dispose` closed the engine while the player's threads were still inside it.
// AvatarPlayer.stop() only lowered a flag: its producer could be in the middle of decoding an
// idle frame (Expression2IdleLoop.next, whose decoder the engine's close() releases), its
// feeder in the middle of `feed`, its writer about to read the head position of an AudioTrack
// that stop() had just released. Each of those throws IllegalStateException on its own
// thread, and an exception nobody catches on ANY thread ends an Android app. Seen 2026-09-29
// in bitHuman Live: a character the person had switched away from finished loading, the app
// disposed it at once, and the app died with IllegalStateException in bh-produce. (The app
// worked around it with setIdleHold(true) and a 300 ms wait before dispose.)
//
// Now: every thread that runs on an engine is started through [EngineUsers.newWorkers], and
// [EngineUsers.close] stops all of them, waits until every one has returned, and only then
// closes the engine, once. So `dispose` is safe at any moment — mid idle decode, mid feed, mid
// barge-in, straight after load, while a held player is still winding down, or twice.

package ai.bithuman.flutter

/**
 * Threads started together and stopped together: one player's feeder, producer and writer.
 * [running] is the flag their loops test; [stop] lowers it; [join] waits for them to return.
 */
class Workers internal constructor(private val onDied: (String, Throwable) -> Unit) {
    @Volatile var running = true
        private set
    private val threads = ArrayList<Thread>()

    /**
     * Runs [body] on a new thread named [name]. An exception that escapes [body] ends that
     * thread and is handed to the owner's `onDied` — it is not rethrown, because an uncaught
     * exception on any thread kills the app, and a player thread that dies must cost a frozen
     * picture and a log line, not the app. Does nothing once [stop] has been called.
     */
    @Synchronized
    fun spawn(name: String, body: () -> Unit): Thread? {
        if (!running) return null
        val t = Thread({
            try {
                body()
            } catch (e: Exception) {
                onDied(name, e)
            }
        }, name)
        threads += t
        t.start()
        return t
    }

    /** Asks every thread to return. Does not wait: see [join]. */
    fun stop() {
        running = false
    }

    /** Waits up to [timeoutMs] for every thread to return. True when none is still running. */
    fun join(timeoutMs: Long): Boolean {
        val deadline = System.nanoTime() + timeoutMs * 1_000_000L
        val me = Thread.currentThread()
        for (t in snapshot()) {
            if (t === me) continue
            val left = (deadline - System.nanoTime()) / 1_000_000L
            if (left > 0) t.join(left)
        }
        return alive().isEmpty()
    }

    /** Names of the threads still running. */
    fun alive(): List<String> = snapshot().filter { it.isAlive && it !== Thread.currentThread() }.map { it.name }

    @Synchronized private fun snapshot(): List<Thread> = threads.toList()
}

/**
 * One engine and every [Workers] set that has run on it — a player, and after an idle hold a
 * fresh player on the same engine. The engine is closed exactly once, and only after every
 * thread of every set has returned.
 */
class EngineUsers(
    private val engine: AutoCloseable,
    private val log: (String) -> Unit = {},
) {
    private val sets = ArrayList<Workers>()
    private var closing = false

    /** True once [close] has begun: no new threads may use the engine. */
    val isClosing: Boolean @Synchronized get() = closing

    /** A new set of threads that will use the engine. Throws once [close] has begun. */
    @Synchronized
    fun newWorkers(onDied: (String, Throwable) -> Unit): Workers {
        check(!closing) { "the engine is being closed" }
        return Workers(onDied).also { sets += it }
    }

    /**
     * Waits up to [timeoutMs] until every set that has been STOPPED has returned — what a fresh
     * player waits for, so two producers never share one engine. Running sets are not waited on.
     */
    fun awaitStopped(timeoutMs: Long): Boolean {
        val stopped = synchronized(this) { sets.filter { !it.running } }
        val deadline = System.nanoTime() + timeoutMs * 1_000_000L
        for (w in stopped) {
            val left = (deadline - System.nanoTime()) / 1_000_000L
            if (!w.join(maxOf(left, 0L))) return false
        }
        synchronized(this) { sets.removeAll(stopped.toSet()) }
        return true
    }

    /**
     * Stops every set, waits until all of their threads have returned, then closes the engine.
     * Blocking: call it off the platform thread. Waits up to [giveUpMs], logging every [warnMs];
     * if a thread is STILL inside the engine then, the engine is left open (a leak, logged)
     * rather than closed under that thread (a crash). Returns true when the engine was closed
     * by this call; false when it was left open, or when another call already closed it.
     */
    fun close(warnMs: Long = WARN_MS, giveUpMs: Long = GIVE_UP_MS): Boolean {
        val all = synchronized(this) {
            if (closing) return false
            closing = true
            sets.toList()
        }
        all.forEach { it.stop() }
        val t0 = System.nanoTime()
        while (true) {
            if (all.all { it.join(warnMs) }) break
            val waited = (System.nanoTime() - t0) / 1_000_000L
            val names = all.flatMap { it.alive() }
            if (waited >= giveUpMs) {
                log("engine NOT closed: $names still inside it after $waited ms; left open rather than closed under them")
                return false
            }
            log("engine close waits for $names ($waited ms)")
        }
        try {
            engine.close()
        } catch (e: Exception) {
            log("engine close: $e")
        }
        synchronized(this) { sets.clear() }
        return true
    }

    companion object {
        const val WARN_MS = 2_000L
        const val GIVE_UP_MS = 30_000L
    }
}
