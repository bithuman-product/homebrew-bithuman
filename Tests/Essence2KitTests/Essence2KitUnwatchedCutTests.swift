// Essence2KitUnwatchedCutTests — a session nobody watches ends after 60 s; the next frame opens a
// new one (Swift package 2.20.4).
//
// The owner's interim protection (API spec v1.1 §13 Q2): until the meter can pause, the app in the
// background for 60 s, or no frame asked for in 60 s, ENDS the session (Essence2Kit releases the
// engine handle, whose final beat bills it up to the cut, as a close does), and the next frame
// asked for in the foreground opens a new session. MODEL-FREE: the decision is driven on an
// injected clock with recording end/reopen closures; the handle half is checked on the iPhone.
import XCTest
@testable import Essence2Kit

final class Essence2KitUnwatchedCutTests: XCTestCase {

    private final class Clock: @unchecked Sendable {
        private let l = NSLock(); private var t: TimeInterval = 1_000
        func advance(_ d: TimeInterval) { l.lock(); t += d; l.unlock() }
        var read: () -> TimeInterval { { [self] in l.lock(); defer { l.unlock() }; return t } }
    }

    /// What the cut asked the engine to do, and when (on the test clock).
    private final class Engine: @unchecked Sendable {
        private let l = NSLock()
        private var _ends: [(Essence2UnwatchedCut.Reason, TimeInterval)] = []
        private var _reopens: [TimeInterval] = []
        var answer = true
        func end(_ r: Essence2UnwatchedCut.Reason, at t: TimeInterval) { l.lock(); _ends.append((r, t)); l.unlock() }
        func reopen(at t: TimeInterval) -> Bool { l.lock(); defer { l.unlock() }; _reopens.append(t); return answer }
        var ends: [(Essence2UnwatchedCut.Reason, TimeInterval)] { l.lock(); defer { l.unlock() }; return _ends }
        var reopens: [TimeInterval] { l.lock(); defer { l.unlock() }; return _reopens }
    }

    private let clock = Clock()
    private let engine = Engine()

    private func cut() -> Essence2UnwatchedCut {
        let c = clock, e = engine
        return Essence2UnwatchedCut(clock: c.read,
                                    end: { r in e.end(r, at: c.read()) },
                                    reopen: { e.reopen(at: c.read()) })
    }

    // ── the background ─────────────────────────────────────────────────────

    /// 60 s in the background ends the session once, at 60 s; nothing more while away.
    func testSixtySecondsInTheBackgroundEndsTheSession() {
        let c = cut()
        XCTAssertTrue(c.frameRequested())
        c.enteredBackground(granted: nil)
        clock.advance(59); c.tick(); XCTAssertTrue(c.drain(timeout: 2))
        XCTAssertEqual(engine.ends.count, 0, "59 s away: the same session")
        clock.advance(1); c.tick(); XCTAssertTrue(c.drain(timeout: 2))
        XCTAssertEqual(c.state, .cut(.background))
        XCTAssertEqual(engine.ends.count, 1)
        XCTAssertEqual(engine.ends.first?.0, .background)
        XCTAssertEqual(engine.ends.first?.1, 1_060, "ended at the cut, so billed up to it")
        clock.advance(3_600); c.tick(); XCTAssertTrue(c.drain(timeout: 2))
        XCTAssertEqual(engine.ends.count, 1, "ended once")
        XCTAssertFalse(c.frameRequested(), "in the background a frame asked for does not reopen")
        XCTAssertTrue(c.drain(timeout: 2))
        XCTAssertEqual(engine.reopens.count, 0)
    }

    /// Back in the foreground before 60 s: the session carries on.
    func testForegroundBeforeSixtySecondsContinues() {
        let c = cut()
        XCTAssertTrue(c.frameRequested())
        c.enteredBackground(granted: nil)
        clock.advance(59); c.tick()
        c.enteredForeground()
        clock.advance(59); c.tick()                   // a full minute again after coming back
        XCTAssertTrue(c.frameRequested())
        clock.advance(59); c.tick(); XCTAssertTrue(c.drain(timeout: 2))
        XCTAssertEqual(c.state, .live)
        XCTAssertEqual(engine.ends.count, 0)
    }

    /// iOS grants less than 60 s in the background: the cut comes 5 s before it runs out.
    func testABackgroundTimeLimitCutsFiveSecondsBeforeItRunsOut() {
        let c = cut()
        _ = c.frameRequested()
        c.enteredBackground(granted: 30)
        clock.advance(24); c.tick(); XCTAssertTrue(c.drain(timeout: 2))
        XCTAssertEqual(engine.ends.count, 0)
        clock.advance(1); c.tick(); XCTAssertTrue(c.drain(timeout: 2))
        XCTAssertEqual(engine.ends.map(\.1), [1_025])
        // and a background time already spent ends it at once (the expiration path)
        let d = cut()
        d.cutNow(.background); XCTAssertTrue(d.drain(timeout: 2))
        XCTAssertEqual(engine.ends.count, 2)
    }

    // ── nobody asking for frames ───────────────────────────────────────────

    /// No frame asked for in 60 s ends the session; asking every 59 s never does.
    func testNoFrameAskedForInSixtySecondsEndsTheSession() {
        let c = cut()
        for _ in 0..<5 { XCTAssertTrue(c.frameRequested()); clock.advance(59); c.tick() }
        XCTAssertTrue(c.drain(timeout: 2))
        XCTAssertEqual(engine.ends.count, 0)
        clock.advance(1); c.tick(); XCTAssertTrue(c.drain(timeout: 2))
        XCTAssertEqual(c.state, .cut(.unobserved))
        XCTAssertEqual(engine.ends.count, 1)
    }

    // ── the reopen ──────────────────────────────────────────────────────────

    /// After a cut the next frame asked for opens a new session (once), and frames flow after it.
    func testAFrameAskedForAfterTheCutOpensANewSession() {
        let c = cut()
        _ = c.frameRequested()
        clock.advance(60); c.tick(); XCTAssertTrue(c.drain(timeout: 2))
        clock.advance(300)
        XCTAssertFalse(c.frameRequested(), "the call that reopens gets no frame")
        XCTAssertFalse(c.frameRequested(), "nor does one while it opens")
        XCTAssertTrue(c.drain(timeout: 2))
        XCTAssertEqual(engine.reopens, [1_360], "one reopen")
        XCTAssertEqual(c.state, .live)
        XCTAssertTrue(c.frameRequested())
        XCTAssertEqual(c.counts.cuts, 1)
        XCTAssertEqual(c.counts.reopens, 1)
        clock.advance(59); c.tick(); XCTAssertTrue(c.drain(timeout: 2))
        XCTAssertEqual(engine.ends.count, 1, "the new session has its own minute")
    }

    /// A refused reopen stays cut and is asked again after 5 s, then 10 s, ...
    func testARefusedReopenIsAskedAgainLater() {
        let c = cut()
        _ = c.frameRequested()
        clock.advance(60); c.tick(); XCTAssertTrue(c.drain(timeout: 2))
        engine.answer = false
        XCTAssertFalse(c.frameRequested()); XCTAssertTrue(c.drain(timeout: 2))
        XCTAssertEqual(c.state, .cut(.unobserved))
        clock.advance(4)
        XCTAssertFalse(c.frameRequested()); XCTAssertTrue(c.drain(timeout: 2))
        XCTAssertEqual(engine.reopens.count, 1, "not again within 5 s")
        clock.advance(1)
        XCTAssertFalse(c.frameRequested()); XCTAssertTrue(c.drain(timeout: 2))
        XCTAssertEqual(engine.reopens.count, 2, "asked again at 5 s")
        clock.advance(9)
        XCTAssertFalse(c.frameRequested()); XCTAssertTrue(c.drain(timeout: 2))
        XCTAssertEqual(engine.reopens.count, 2, "then 10 s")
        engine.answer = true
        clock.advance(1)
        XCTAssertFalse(c.frameRequested()); XCTAssertTrue(c.drain(timeout: 2))
        XCTAssertEqual(engine.reopens.count, 3)
        XCTAssertEqual(c.state, .live)
    }
}
