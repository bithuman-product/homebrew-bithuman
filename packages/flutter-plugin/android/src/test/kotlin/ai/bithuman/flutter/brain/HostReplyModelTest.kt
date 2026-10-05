// Plain JVM, no device: HostReplyModel takes its clock as a parameter.
package ai.bithuman.flutter.brain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class HostReplyModelTest {
    private val now = { System.nanoTime() / 1_000_000 }

    /** A host that answers each request on its own thread with [answer]. */
    private class Host(val answer: (id: Int, m: HostReplyModel) -> Unit) {
        val requests: MutableList<Int> = Collections.synchronizedList(ArrayList())
        val cancels: MutableList<Int> = Collections.synchronizedList(ArrayList())
        val heard: MutableList<Int?> = Collections.synchronizedList(ArrayList())
        val turns: MutableList<Pair<String, Boolean>> = Collections.synchronizedList(ArrayList())
        lateinit var model: HostReplyModel
        fun build(firstMs: Long = 2_000, stallMs: Long = 2_000, clock: () -> Long): HostReplyModel {
            model = HostReplyModel(
                request = { id, _, _, text, continuation -> requests.add(id); turns.add(text to continuation); Thread { answer(id, model) }.start() },
                cancelRequest = { id, heardChars -> cancels.add(id); heard.add(heardChars) },
                firstPieceTimeoutMs = firstMs, stallTimeoutMs = stallMs, clock = clock)
            return model
        }
    }

    private fun run(m: HostReplyModel, stopAfter: Int = Int.MAX_VALUE): Pair<Int, List<String>> {
        val got = ArrayList<String>()
        val n = m.generate(listOf("user" to "hi"), 64, 0.7f) { got.add(it); got.size < stopAfter }
        return n to got
    }

    @Test fun streamsPiecesInOrderAndEndsOnDone() {
        val h = Host { id, m -> listOf("Hello", " there", "!").forEach { m.push(id, it, false) }; m.push(id, "", true) }
        val (n, got) = run(h.build(clock = now))
        assertEquals(3, n)
        assertEquals(listOf("Hello", " there", "!"), got)
        assertEquals(HostReplyModel.RESULT_OK, h.model.lastResult)
        assertTrue("a finished stream is not cancelled", h.cancels.isEmpty())
    }

    @Test fun piecesForAnotherRequestAreNeverSpoken() {
        val h = Host { id, m -> m.push(id + 7, "stale", false); m.push(id, "fresh", false); m.push(id, "", true) }
        val (_, got) = run(h.build(clock = now))
        assertEquals(listOf("fresh"), got)
    }

    @Test fun engineStoppingEarlyCancelsTheHostStream() {
        val h = Host { id, m -> repeat(10) { m.push(id, "s$it. ", false) } }
        val (n, got) = run(h.build(clock = now), stopAfter = 2)
        assertEquals(2, n)
        assertEquals(2, got.size)
        assertEquals(listOf(h.requests.single()), h.cancels.toList())
    }

    @Test fun bargeInCancelEndsTheWaitAndTellsTheHost() {
        val started = CountDownLatch(1)
        val h = Host { id, m -> m.push(id, "One", false); started.countDown() }   // then silence
        val m = h.build(clock = now)
        Thread { started.await(1, TimeUnit.SECONDS); Thread.sleep(30); m.cancel() }.start()
        val t0 = now()
        val (n, _) = run(m)
        assertEquals(1, n)
        assertTrue("cancel returns promptly", now() - t0 < 1_000)
        assertEquals(listOf(h.requests.single()), h.cancels.toList())
    }

    @Test fun noFirstPieceIsAnErrorTheEngineCanSpeakFor() {
        val h = Host { _, _ -> }   // the host never answers
        val (n, got) = run(h.build(firstMs = 60, clock = now))
        assertEquals(-1, n)
        assertTrue(got.isEmpty())
        assertEquals(HostReplyModel.RESULT_ERROR, h.model.lastResult)
        assertEquals(1, h.cancels.size)
    }

    @Test fun aStalledStreamKeepsWhatItSaid() {
        val h = Host { id, m -> m.push(id, "Half a", false) }   // no done
        val (n, got) = run(h.build(stallMs = 60, clock = now))
        assertEquals(1, n)
        assertEquals(listOf("Half a"), got)
        assertEquals(1, h.cancels.size)
    }

    @Test fun hostErrorAfterWordsKeepsThemAndBeforeWordsFails() {
        val after = Host { id, m -> m.push(id, "Partial", false); m.push(id, "", true, HostReplyModel.RESULT_ERROR) }
        assertEquals(1, run(after.build(clock = now)).first)
        val before = Host { id, m -> m.push(id, "", true, HostReplyModel.RESULT_REFUSED) }
        assertEquals(-1, run(before.build(clock = now)).first)
        assertEquals(HostReplyModel.RESULT_REFUSED, before.model.lastResult)
    }

    @Test fun theTurnTravelsWithTheRequestAndTheIdComesBack() {
        val h = Host { id, m -> m.push(id, "Sure.", false); m.push(id, "", true) }
        val m = h.build(clock = now)
        val turn = ReplyTurn("hi there how are you", continuation = true)
        m.generate(turn, listOf("user" to "hi there how are you"), 64, 0.7f) { true }
        assertEquals(listOf("hi there how are you" to true), h.turns.toList())
        assertEquals(h.requests.single(), turn.hostId)
    }

    @Test fun cancelsCarryWhatWasHeard() {
        // A barge: the engine says how much of the text was heard.
        val started = CountDownLatch(1)
        val b = Host { id, m -> m.push(id, "One two", false); started.countDown() }
        val mb = b.build(clock = now)
        Thread { started.await(1, TimeUnit.SECONDS); Thread.sleep(30); mb.cancel(4) }.start()
        run(mb)
        assertEquals(listOf<Int?>(4), b.heard.toList())
        // The engine has its sentences: the cancel names the text it kept.
        val s = Host { id, m -> repeat(10) { m.push(id, "s$it. ", false) } }
        val ms = s.build(clock = now)
        ms.generate(listOf("user" to "hi"), 64, 0.7f) { ms.stopAt(8); false }
        assertEquals(listOf<Int?>(8), s.heard.toList())
        // Cut after the stream ended: reported by the engine, once.
        ms.reportCancel(s.requests.single(), 3)
        assertEquals(listOf<Int?>(8, 3), s.heard.toList())
    }
}
