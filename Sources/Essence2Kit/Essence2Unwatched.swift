// Essence2Unwatched.swift — a session nobody is watching stops billing after 60 s (Swift 2.20.4).
//
// ★THE INTERIM PROTECTION (owner decision 2026-10-03, API spec v1.1 §13 Q2 / §4.2). Until the
// meter can PAUSE (the billing-escape review's R1, not shipped), a session bills its active time
// from its first frame to close, watched or not. So, for every customer:
//   * the app in the background for 60 s, or
//   * no frame asked for in 60 s (`pull`, `pullFrame`, `idle(into:)`, `nextFrame`, `frames()`),
// ENDS the session: the engine handle is released, and its final beat bills it up to that moment,
// exactly as if the app had closed. The next frame asked for while the app is in the foreground
// opens the identity again (a NEW session: a fresh session id and start beat, as if the app had
// reopened) and frames flow once it is ready (about 2-3 s on an iPhone 18 Pro, the compiled
// models cached); until then the call returns nil, as a refused frame does. Time on screen, idle
// or talking, still bills. To the service this is an app closing and reopening, so it opens no
// billing escape.
//
// ★iOS SUSPENDS A BACKGROUND APP LONG BEFORE 60 s. The cut therefore comes at 60 s or 5 s before
// the background time iOS grants (`backgroundTimeRemaining`), whichever is first, inside a
// background task so the final beat leaves before the app is suspended; the task's expiration
// cuts at once. On macOS "background" is the app hidden or none of its windows visible.
//
// The same decision as Expression 2's (bithuman-models Classes/Expression2Unwatched.swift); this
// engine ends a session by releasing its handle because libessence2's C interface has no other end.
import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The decision, with no timers and no platform in it: the engine feeds it the frame requests,
/// the app's background/foreground moves and a 1 s tick; it calls `end` and `reopen`.
final class Essence2UnwatchedCut: @unchecked Sendable {
    enum Reason: String, Sendable { case background, unobserved }
    enum State: Equatable, Sendable { case live, cut(Reason), reopening }

    /// Seconds unwatched before the session ends (the owner's number).
    static let limit: TimeInterval = 60
    /// The cut leaves this much of the background time iOS grants, so the final beat can leave.
    static let suspendMargin: TimeInterval = 5
    /// A reopen the service refused is asked again after this, doubling up to `limit`.
    static let retryAfter: TimeInterval = 5

    private let lock = NSLock()
    private var stateValue: State = .live
    private var lastRequest: TimeInterval
    private var backgroundSince: TimeInterval?
    private var backgroundLimit: TimeInterval = Essence2UnwatchedCut.limit
    private var lastReopenAttempt = -TimeInterval.infinity
    private var refusedReopens = 0
    private var cutCount = 0, reopenCount = 0
    private let clock: () -> TimeInterval
    /// End the meter session (blocking: the final beat, bounded). Runs on `work`.
    private let end: (Reason) -> Void
    /// Open a new meter session (blocking: the service's answer, bounded). True: frames may flow.
    private let reopen: () -> Bool
    /// End and reopen run here, one at a time and in order, never on the caller's thread.
    private let work = DispatchQueue(label: "ai.bithuman.essence2.unwatched")
    /// Called on `work` after a cut's final beat left (the platform binding ends its background task).
    var afterCut: (() -> Void)?

    init(clock: @escaping () -> TimeInterval, end: @escaping (Reason) -> Void, reopen: @escaping () -> Bool) {
        self.clock = clock; self.end = end; self.reopen = reopen
        lastRequest = clock()
    }

    var state: State { lock.lock(); defer { lock.unlock() }; return stateValue }
    var counts: (cuts: Int, reopens: Int) { lock.lock(); defer { lock.unlock() }; return (cutCount, reopenCount) }

    /// A frame was asked for. True: it may leave. False: the session was cut — it is reopening
    /// (the caller gets nil this time) or waits for the app to come back to the foreground.
    func frameRequested() -> Bool {
        let now = clock()
        lock.lock()
        lastRequest = now
        guard case .cut = stateValue else {
            let live = stateValue == .live
            lock.unlock(); return live
        }
        // in the background nobody can see it: stay cut (no ping-pong with a background puller)
        let wait = min(Self.limit, Self.retryAfter * pow(2, Double(max(0, min(refusedReopens, 5) - 1))))   // 5, 10, 20, 40, 60 s
        guard backgroundSince == nil, refusedReopens == 0 || now - lastReopenAttempt >= wait else {
            lock.unlock(); return false
        }
        let was = stateValue
        stateValue = .reopening
        lastReopenAttempt = now
        lock.unlock()
        work.async { [self] in
            let ok = reopen()
            lock.lock()
            if ok { stateValue = .live; lastRequest = clock(); reopenCount += 1; refusedReopens = 0 }
            else { stateValue = was; refusedReopens += 1 }
            lock.unlock()
        }
        return false
    }

    /// The app went to the background. `granted`: seconds the system lets it run there (iOS's
    /// `backgroundTimeRemaining`), nil when it is not limited.
    func enteredBackground(granted: TimeInterval?) {
        lock.lock()
        backgroundSince = clock()
        backgroundLimit = min(Self.limit, granted.map { max(0, $0 - Self.suspendMargin) } ?? Self.limit)
        lock.unlock()
        tick()
    }

    /// The app is back in the foreground: a live session carries on; a cut one reopens with the
    /// next frame asked for.
    func enteredForeground() {
        lock.lock()
        backgroundSince = nil
        lastRequest = clock()          // a full minute to ask for a frame again
        lock.unlock()
    }

    /// The watchdog (every second, and on every background move).
    func tick() {
        let now = clock()
        lock.lock()
        guard stateValue == .live else { lock.unlock(); return }
        var reason: Reason?
        if let since = backgroundSince, now - since >= backgroundLimit { reason = .background }
        else if now - lastRequest >= Self.limit { reason = .unobserved }
        guard let r = reason else { lock.unlock(); return }
        cutLocked(r)
    }

    /// Cut now, whatever the clock says (iOS: the background task is about to expire).
    func cutNow(_ r: Reason) {
        lock.lock()
        guard stateValue == .live else { lock.unlock(); return }
        cutLocked(r)
    }

    private func cutLocked(_ r: Reason) {   // caller holds `lock`; releases it
        stateValue = .cut(r)
        cutCount += 1
        lock.unlock()
        work.async { [self] in
            end(r)
            afterCut?()
        }
    }

    /// Blocks until every queued end/reopen has run, or `timeout` passes. False on timeout.
    @discardableResult
    func drain(timeout: TimeInterval) -> Bool {
        let s = DispatchSemaphore(value: 0)
        work.async { s.signal() }
        return s.wait(timeout: .now() + timeout) == .success
    }
}

/// Feeds a cut its timer and the app's background/foreground moves. Released with the engine.
final class Essence2UnwatchedBinding: @unchecked Sendable {
    let cut: Essence2UnwatchedCut
    private var timer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    #if canImport(UIKit) && !os(watchOS)
    private let taskLock = NSLock()
    private var task: UIBackgroundTaskIdentifier = .invalid   // under taskLock
    #endif

    init(cut: Essence2UnwatchedCut) {
        self.cut = cut
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(250))
        t.setEventHandler { [weak cut] in cut?.tick() }
        t.resume()
        timer = t
        observe()
    }

    /// No timer and no notifications: the owner drives `cut.tick()` and the background moves (tests).
    init(unboundCut cut: Essence2UnwatchedCut) { self.cut = cut }

    deinit { stop() }

    func stop() {
        timer?.cancel(); timer = nil
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        #if canImport(UIKit) && !os(watchOS)
        endTaskAnywhere()
        #endif
    }

    private func observe() {
        let nc = NotificationCenter.default
        #if canImport(UIKit) && !os(watchOS)
        // queue: .main — the handlers run on the main thread, where UIApplication lives.
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                                        queue: .main) { [weak self] _ in
            guard let s = self else { return }
            MainActor.assumeIsolated { s.didEnterBackground() }
        })
        observers.append(nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil,
                                        queue: .main) { [weak self] _ in
            guard let s = self else { return }
            MainActor.assumeIsolated { s.willEnterForeground() }
        })
        cut.afterCut = { [weak self] in self?.endTaskAnywhere() }
        #elseif canImport(AppKit)
        observers.append(nc.addObserver(forName: NSApplication.didHideNotification, object: nil,
                                        queue: .main) { [weak self] _ in self?.cut.enteredBackground(granted: nil) })
        observers.append(nc.addObserver(forName: NSApplication.didUnhideNotification, object: nil,
                                        queue: .main) { [weak self] _ in self?.cut.enteredForeground() })
        observers.append(nc.addObserver(forName: NSApplication.didChangeOcclusionStateNotification, object: nil,
                                        queue: .main) { [weak self] n in
            guard let app = n.object as? NSApplication else { return }
            if app.occlusionState.contains(.visible) { self?.cut.enteredForeground() }
            else { self?.cut.enteredBackground(granted: nil) }
        })
        #endif
    }

    #if canImport(UIKit) && !os(watchOS)
    @MainActor private func didEnterBackground() {
        let app = UIApplication.shared
        endTaskOnMain()
        let id = app.beginBackgroundTask(withName: "bitHuman session end") { [weak self] in
            // the system is about to suspend the app (this handler runs on the main thread): end
            // the session now and give its final beat ~3 s
            guard let s = self else { return }
            s.cut.cutNow(.background)
            _ = s.cut.drain(timeout: 3)
            MainActor.assumeIsolated { s.endTaskOnMain() }
        }
        taskLock.lock(); task = id; taskLock.unlock()
        let left = app.backgroundTimeRemaining
        cut.enteredBackground(granted: left < 1e6 ? left : nil)   // DBL_MAX: not limited
    }

    @MainActor private func willEnterForeground() {
        cut.enteredForeground()
        endTaskOnMain()
    }

    @MainActor private func endTaskOnMain() {
        taskLock.lock(); let t = task; task = .invalid; taskLock.unlock()
        if t != .invalid { UIApplication.shared.endBackgroundTask(t) }
    }

    /// From any thread (the cut's queue, shutdown, deinit).
    private func endTaskAnywhere() {
        if Thread.isMainThread { MainActor.assumeIsolated { endTaskOnMain() }; return }
        DispatchQueue.main.async { [self] in MainActor.assumeIsolated { endTaskOnMain() } }
    }
    #endif
}
