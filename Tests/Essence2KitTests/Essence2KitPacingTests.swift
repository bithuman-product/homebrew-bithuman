// Essence2KitPacingTests — the frame clock and the reply boundaries of Essence2Kit (2.17.0).
//
// ★WHY. Through 2.16.0 `pull()` handed out the engine's idle frames as fast as it was called:
// measured on an M4 (Swift 2.16.0, sofia-ramirez, a 20.34 s clip), a loop that slept only on
// nil got 509 speech frames by 4.4 s and then ~405 idle frames a second, forever, and never a
// nil after the reply. These tests hold the two things that replace that: at most 25 frames a
// second whoever asks, and exactly one end-of-reply per reply.
//
// The clock and the tracker are pure, so they are graded here with a virtual clock and scripted
// frame kinds; the engine-driven proof (a tight loop, the docs' loop, flushTail) runs against a
// real identity on a Mac and an iPhone (bithuman-models perf/harness).

import XCTest
import Essence2
@testable import Essence2Kit

final class Essence2KitPacingTests: XCTestCase {

    /// Ask for a frame every `step` seconds for `seconds` (call i at 1000 + i*step + jitter(i),
    /// computed, not accumulated); return when the clock handed one out.
    private func delivered(step: Double, seconds: Double, jitter: (Int) -> Double = { _ in 0 }) -> [Double] {
        var clock = Essence2FrameClock(fps: 25)
        var out: [Double] = []
        let calls = Int((seconds / step).rounded())
        for i in 0..<calls {
            let now = 1000.0 + Double(i) * step + jitter(i)
            if clock.isDue(now) { clock.delivered(at: now); out.append(now) }
        }
        return out
    }

    /// A tight loop (a call every 0.1 ms) gets 25 frames a second, never more.
    func testATightLoopGetsAtMostTheFrameRate() {
        let got = delivered(step: 0.0001, seconds: 10)
        XCTAssertLessThanOrEqual(got.count, 251, "25 fps over 10 s (+1 for the first frame)")
        XCTAssertGreaterThanOrEqual(got.count, 249)
        let gaps = zip(got.dropFirst(), got).map { $0 - $1 }
        XCTAssertGreaterThanOrEqual(gaps.min() ?? 0, 0.040 - 0.0021, "no two frames closer than one period")
    }

    /// The docs' loop (sleep 40 ms, wake a little late or a hair early) gets every frame.
    func testADisplayPacedCallerGetsEveryFrame() {
        let got = delivered(step: 0.040, seconds: 10, jitter: { i in [0.0, 0.0012, -0.0015, 0.003][i % 4] })
        XCTAssertEqual(got.count, 250, "one frame per call at 25 calls a second")
    }

    /// A 60 Hz display link also gets 25 a second (3:2 cadence), not 60.
    func testA60HzDisplayLinkGets25() {
        let got = delivered(step: 1.0 / 60, seconds: 10)
        XCTAssertEqual(Double(got.count), 250, accuracy: 2)
    }

    /// After a stall the clock pays back at most two frames, then re-anchors.
    func testAStallIsNotPaidBackWithABurst() {
        var clock = Essence2FrameClock(fps: 25)
        clock.delivered(at: 0)                       // frame 0; next due 0.04
        var burst = 0
        var t = 1.0                                  // a 1 s stall, then a tight loop
        while t < 1.0 + 0.001 { if clock.isDue(t) { clock.delivered(at: t); burst += 1 }; t += 0.0001 }
        XCTAssertEqual(burst, 1, "a stall longer than the lag window re-anchors instead of bursting")

        var c2 = Essence2FrameClock(fps: 25)
        c2.delivered(at: 0)
        var b2 = 0
        t = 0.100                                    // 60 ms late: within the 2-frame window
        while t < 0.101 { if c2.isDue(t) { c2.delivered(at: t); b2 += 1 }; t += 0.0001 }
        XCTAssertEqual(b2, 2, "a short lag is caught up, at most two frames back to back")
    }

    /// `wait(until:)` says when to come back, and coming back then is on time.
    func testWaitPointsAtTheNextDueFrame() {
        var clock = Essence2FrameClock(fps: 25)
        XCTAssertEqual(clock.wait(until: 5), 0)
        clock.delivered(at: 5)
        let w = clock.wait(until: 5.010)
        XCTAssertEqual(w, 0.028, accuracy: 1e-9)
        XCTAssertTrue(clock.isDue(5.010 + w))
        XCTAssertFalse(clock.isDue(5.010 + w - 0.001))
    }

    // ── replies ──

    private func run(_ kinds: [Essence2FrameKind], interruptAt: Set<Int> = []) -> (events: [Essence2Event], ends: [Int]) {
        var t = Essence2ReplyTracker()
        var events: [Essence2Event] = []
        var ends: [Int] = []
        for (i, k) in kinds.enumerated() {
            if interruptAt.contains(i) { t.interrupted() }
            let r = t.note(k)
            events += r.events
            if r.endsReply { ends.append(i) }
        }
        return (events, ends)
    }

    private func frames(_ spec: String) -> [Essence2FrameKind] {
        spec.map { $0 == "s" ? .speech : $0 == "r" ? .ramp : .idle }
    }

    /// idle, a reply, its ramp, idle: one start, one end, on the first idle frame.
    func testOneReplyEndsExactlyOnce() {
        let r = run(frames("iiisssssrrrrrriiiiiiii"))
        XCTAssertEqual(r.events, [.replyStarted, .replyEnded])
        XCTAssertEqual(r.ends, [14], "the first idle frame after the ramp")
    }

    /// Three replies, three ends; idle-only stretches produce nothing.
    func testEveryReplyEndsOnceAndIdleProducesNothing() {
        XCTAssertEqual(run(frames("iiiiiiiiii")).events, [])
        let r = run(frames("ssssrri" + "iiii" + "sssrrriii" + "ssssssrrrrrri"))
        XCTAssertEqual(r.events, [.replyStarted, .replyEnded, .replyStarted, .replyEnded,
                                  .replyStarted, .replyEnded])
        XCTAssertEqual(r.ends.count, 3)
    }

    /// A reply that follows straight on from the previous ramp is still two replies.
    func testARampStraightIntoSpeechIsTwoReplies() {
        let r = run(frames("sssrrsssrri"))
        XCTAssertEqual(r.events, [.replyStarted, .replyEnded, .replyStarted, .replyEnded])
        XCTAssertEqual(r.ends, [5, 10])
    }

    /// A barge-in ends the reply once, whether a ramp is shown or the next reply starts at once.
    func testAnInterruptedReplyEndsOnce() {
        XCTAssertEqual(run(frames("sssssrrrriii"), interruptAt: [5]).events, [.replyStarted, .replyEnded])
        let r = run(frames("ssssssssiii"), interruptAt: [4])
        XCTAssertEqual(r.events, [.replyStarted, .replyEnded, .replyStarted, .replyEnded],
                       "speech after an interrupt is a new reply")
        XCTAssertEqual(run(frames("iiiii"), interruptAt: [2]).events, [], "an interrupt while idle is nothing")
    }

    /// The engine's tag wins; with no tag (-1) the speech counter decides.
    func testTheFrameKindReadsTheEngineTag() {
        XCTAssertEqual(Essence2FrameKind(engine: 0, speech: true), .idle)
        XCTAssertEqual(Essence2FrameKind(engine: 1, speech: false), .speech)
        XCTAssertEqual(Essence2FrameKind(engine: 2, speech: false), .ramp)
        XCTAssertEqual(Essence2FrameKind(engine: -1, speech: true), .speech)
        XCTAssertEqual(Essence2FrameKind(engine: -1, speech: false), .idle)
    }

    /// The pinned libessence2 exports the two calls Essence2Kit makes (a link-time proof on the
    /// pinned bytes: a package that pinned an older engine would not link this test).
    func testThePinnedEngineExportsTheReplyCalls() {
        XCTAssertEqual(be_essence2_end_utterance(nil), -1)
        XCTAssertEqual(be_essence2_last_frame_kind(nil), -1)
    }
}
