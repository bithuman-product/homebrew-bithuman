// Essence2Kit — a Swift engine for Essence 2 that reads like `Expression2Engine`.
//
// ★WHAT THIS FILE IS, AND IS NOT. It is a thin wrapper over the public C interface the
// `Essence2` product already ships (`be_essence2.h`): create, push audio, pull frames, the
// idle frame, reset, destroy. It opens nothing itself — the identity file is handed to
// `be_essence2_create` unread — and it contains no model-format logic of any kind. What it
// adds is the part every app had to write by hand: the credential, the engine's runtime
// resources (fetched once, checksum-pinned), readiness, and the refusal sentence behind -3.
//
//   import Essence2Kit
//   Essence2Credential.set(apiSecret)
//   let engine = try await Essence2Engine.create(identity: identityURL)
//   engine.feed(samples16kHz)                 // Float, mono, 16 kHz
//   engine.flushTail()                        // that was the whole reply
//   for await f in engine.frames(following: player) {   // 25 per second, on the player's audio
//       show(f.bgr, f.width, f.height)        // B, G, R bytes
//       if f.audioTime == 0 { player.stop(); player.scheduleBuffer(reply); player.play() }
//       if f.endsReply { break }              // the reply is over; idle frames follow
//   }
//   engine.interrupt()                        // barge-in: rides on the current frame
//   engine.shutdown()
//
// ★PACED SINCE 2.17.0 (essence2-v1.14.0). The engine hands out idle frames between replies
// for as long as it is asked, so until 2.16.0 a loop that called `pull()` without sleeping got
// ~405 frames a second and never a nil after a reply. `pull()`, `idle(into:)`, `nextFrame()`
// and `frames()` now hand out at most one frame per 1/25 s (the model's frame clock); a caller
// that asks sooner gets nil / 0, which already meant "keep showing the frame you have".
// `pacing = .unpaced` restores the old behaviour for offline rendering and benchmarks.
//
// Billing: a session bills its active session time, talking or idle, priced by the service
// (https://docs.bithuman.ai/pricing). Without an API secret `create` throws `.meteringRefused`
// (the engine's own sentence). bithuman-models #1224.

import Foundation
import CryptoKit
import AVFoundation
import Essence2

// MARK: - Credential

/// The API secret Essence 2 sessions bill to — the same name the engine's C setter
/// (`be_essence2_set_api_secret`) and Expression 2 (`Expression2Credential`) use.
/// Call it before `Essence2Engine.create`; `BITHUMAN_API_SECRET` is the fallback.
public enum Essence2Credential {
    public static func set(_ secret: String?) {
        let s = secret?.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock(); stored = (s?.isEmpty == false) ? s : nil; lock.unlock()
        if let s, !s.isEmpty {
            _ = s.withCString { be_essence2_set_api_secret($0) }
        } else {
            _ = be_essence2_set_api_secret(nil)
        }
    }

    /// The secret a download is made with: the one set here, else `BITHUMAN_API_SECRET`.
    static var current: String? {
        lock.lock(); defer { lock.unlock() }
        if let s = stored { return s }
        let e = ProcessInfo.processInfo.environment["BITHUMAN_API_SECRET"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (e?.isEmpty == false) ? e : nil
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stored: String?
}

// MARK: - Errors

public enum Essence2KitError: Error, CustomStringConvertible, Sendable {
    /// Metering refused the session: no API secret, a rejected one, or (retryable) a
    /// service that could not be reached at the first contact. `reason` is the engine's sentence.
    case meteringRefused(reason: String)
    /// The identity file could not be opened by the engine (-2 from `be_essence2_create`).
    case identityUnreadable(path: String)
    /// The engine's runtime resources could not be fetched or did not match their pinned checksum.
    case resourcesUnavailable(String)
    /// The engine never became ready within the timeout.
    case notReady(seconds: Double)
    /// The identity file is OUT OF DATE: published before the renderer this engine carries,
    /// which refuses it (-4 from `be_essence2_create`: the essence2 engines that carry the refusal;
    /// essence2-v1.15.4, which this package pins, still opens such a file). A file
    /// `Essence2Download` fetched is fetched again by `create` itself; this is thrown for a
    /// file your app keeps. Download it again (`Essence2Download.identity(agentCode:)`, or
    /// "Download model" in the agent's studio at bithuman.ai) — retrying the same file never
    /// works. `agentCode` is "" when the file names none; `reason` is the engine's sentence.
    case identityOutdated(path: String, agentCode: String, reason: String)

    public var description: String {
        switch self {
        case .meteringRefused(let r): return r
        case .identityUnreadable(let p): return "\(p): the Essence 2 engine could not open this identity file"
        case .resourcesUnavailable(let m): return "Essence 2 resources: \(m)"
        case .notReady(let s): return "the Essence 2 engine was not ready after \(Int(s)) s"
        case .identityOutdated(let p, let code, _):
            let who = code.isEmpty ? "<agent code>" : code
            return "\(p): this Essence 2 avatar file\(code.isEmpty ? "" : " (\(code))") is out of date — it was "
                + "published before the renderer in this SDK, which can no longer open it. Download it "
                + "again: Essence2Download.identity(agentCode: \"\(who)\"), or \"Download model\" in the "
                + "agent's studio at bithuman.ai."
        }
    }
}

// MARK: - Engine

public final class Essence2Engine: @unchecked Sendable {

    /// The model's frame clock: Essence 2 renders 25 frames per second of audio.
    public static let framesPerSecond: Double = 25

    private let handle: be_essence2_handle
    private let lock = NSLock()
    private var buffer: [UInt8]
    private var lastSpeech: Int32
    private var closed = false
    private var clock = Essence2FrameClock(fps: Essence2Engine.framesPerSecond)
    private var replies = Essence2ReplyTracker()
    private var handedOut = 0
    private var dropped = 0
    /// Speech frames of the current reply pulled so far (handed out or dropped): frame k shows
    /// the reply's audio from k/25 s.
    private var replySpeech = 0
    private var pacingValue = Essence2Pacing.realtime
    private let listenersLock = NSLock()
    private var listeners: [UUID: AsyncStream<Essence2Event>.Continuation] = [:]

    /// How frames are handed out. `.realtime` (the default): at most one frame per 1/25 s,
    /// whichever call asks. `.unpaced`: as fast as the engine renders, for offline rendering.
    public var pacing: Essence2Pacing {
        get { lock.lock(); defer { lock.unlock() }; return pacingValue }
        set { lock.lock(); pacingValue = newValue; clock.reset(); lock.unlock() }
    }

    /// Current frame geometry (it follows the identity's canvas).
    public var width: Int { lock.lock(); defer { lock.unlock() }; return dimsLocked().w }
    public var height: Int { lock.lock(); defer { lock.unlock() }; return dimsLocked().h }

    /// True once the engine can turn audio into speech frames.
    public var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return !closed && be_essence2_is_ready(handle) == 1
    }

    /// While metering refuses THIS session (its last pull or idle returned -3): the engine's
    /// sentence (`be_essence2_last_refusal`, essence2-v1.12.0+). nil while frames flow.
    public var meteringRefusal: String? {
        lock.lock(); let refused = refusedNow; lock.unlock()
        return refused ? Essence2Engine.lastRefusal() : nil
    }
    private var refusedNow = false

    private init(handle: be_essence2_handle) {
        self.handle = handle
        self.buffer = []
        self.lastSpeech = be_essence2_pulled_speech_frames(handle)
        fitBuffer()
    }

    /// The pull buffer is sized for the full canvas, which `be_essence2_get_info` reports as
    /// soon as `create` returns (a frame smaller than the canvas is read by its byte count).
    private func fitBuffer() {
        let d = dimsLocked()
        let need = max(d.w * d.h * 3, 1)
        if buffer.count < need { buffer = [UInt8](repeating: 0, count: need) }
    }

    deinit { shutdown() }

    /// Open an Essence 2 identity file and wait until the engine is ready.
    ///
    /// - Parameters:
    ///   - identity: the identity file as downloaded (`GET /v1/agent/{code}/model/download`).
    ///   - resourcesDirectory: a directory holding the engine's runtime resources. Omit it and
    ///     they are fetched once from the release this package pins, checked against their
    ///     sha256, and kept in Application Support.
    ///   - readyTimeout: seconds to wait for the warm-up.
    ///
    /// An identity file `Essence2Download` fetched that has gone out of date (published before
    /// the renderer this engine carries) is fetched again from the download door, ONCE, and
    /// opened — the app never sees the refusal. Any other out-of-date file throws
    /// `Essence2KitError.identityOutdated`, naming the agent and the fix.
    public static func create(identity: URL,
                              resourcesDirectory: URL? = nil,
                              readyTimeout: Double = 300) async throws -> Essence2Engine {
        try await create(identity: identity, resourcesDirectory: resourcesDirectory,
                         readyTimeout: readyTimeout,
                         fetchAgain: { code, dir in
                             // the door's CURRENT file: a cache hit would hand back the one refused
                             try await Essence2Download.identity(agentCode: code, directory: dir,
                                                                 io: .network, mode: .doorFirst)
                         })
    }

    /// `create` with the re-download as a parameter (tests serve a local file instead of the door).
    static func create(identity: URL,
                       resourcesDirectory: URL?,
                       readyTimeout: Double,
                       fetchAgain: (_ agentCode: String, _ directory: URL) async throws -> URL)
                       async throws -> Essence2Engine {
        try await openHealing(identity: identity,
                              open: { try await createOnce(identity: $0, resourcesDirectory: resourcesDirectory,
                                                           readyTimeout: readyTimeout) },
                              fetchAgain: fetchAgain)
    }

    /// ★A DOOR-FETCHED FILE HEALS ITSELF (2026-10-02): the door serves every live identity's
    /// current file, so the fix for an out-of-date one is to fetch it again — done here, ONCE.
    ///
    /// - `open(identity)` refuses with `identityOutdated` naming an agent, and `identity` is a
    ///   file the downloader wrote (`Essence2Download.isDownloaded`): `fetchAgain(code, its
    ///   directory)` once, then `open` the fresh file once. Only after that open succeeds is the
    ///   stale file removed. The second open is not healed again: its refusal is final.
    /// - The download fails, or hands back the same file (the door still serves those bytes):
    ///   the original `identityOutdated` is thrown and the stale file is kept.
    /// - Any other file (the app's own), or a refusal that names no agent: `identityOutdated`
    ///   as thrown, and nothing is downloaded. Every other error passes through untouched.
    ///
    /// Generic over what `open` returns so the decision is testable without an engine.
    static func openHealing<Opened>(identity: URL,
                                    open: (URL) async throws -> Opened,
                                    fetchAgain: (_ agentCode: String, _ directory: URL) async throws -> URL)
                                    async throws -> Opened {
        do {
            return try await open(identity)
        } catch Essence2KitError.identityOutdated(let path, let code, let reason)
                    where !code.isEmpty && Essence2Download.isDownloaded(identity) {
            let refused = Essence2KitError.identityOutdated(path: path, agentCode: code, reason: reason)
            let fresh: URL
            do {
                fresh = try await fetchAgain(code, identity.deletingLastPathComponent())
            } catch {
                throw refused
            }
            guard fresh.standardizedFileURL.resolvingSymlinksInPath()
                    != identity.standardizedFileURL.resolvingSymlinksInPath() else { throw refused }
            let opened = try await open(fresh)
            try? FileManager.default.removeItem(at: identity)   // the stale copy is never opened again
            return opened
        }
    }

    private static func createOnce(identity: URL,
                                   resourcesDirectory: URL?,
                                   readyTimeout: Double) async throws -> Essence2Engine {
        let res: URL
        if let given = resourcesDirectory { res = given } else { res = try await Essence2Resources.ensure() }
        Essence2Resources.point(at: res)
        var h: be_essence2_handle? = nil
        let rc = identity.path.withCString { be_essence2_create($0, nil, 0, &h) }
        switch rc {
        case 0: break
        case -3: throw Essence2KitError.meteringRefused(reason: lastRefusal()
                    ?? "refusing to serve: metering refused this session (see the engine's log line)")
        case -4:
            let why = lastRefusal() ?? "the avatar file was published before the renderer in this SDK"
            throw Essence2KitError.identityOutdated(path: identity.path,
                                                    agentCode: Essence2Download.agentCode(inRefusal: why),
                                                    reason: why)
        default: throw Essence2KitError.identityUnreadable(path: identity.path)   // -2 (and -1: bad argument)
        }
        guard let h else { throw Essence2KitError.identityUnreadable(path: identity.path) }
        let engine = Essence2Engine(handle: h)
        let t0 = Date()
        while !engine.isReady {
            if Date().timeIntervalSince(t0) > readyTimeout {
                engine.shutdown(); throw Essence2KitError.notReady(seconds: readyTimeout)
            }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        return engine
    }

    /// Feed 16 kHz mono audio as Float in [-1, 1]. Never blocks: what the engine's ring cannot
    /// take yet is kept here and handed over on the next `feed` or `pull()`, exactly as the C
    /// contract asks ("-2: pull frames, then push the same samples again").
    public func feed(_ samples: [Float]) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        pending.append(contentsOf: samples.map { Int16(max(-1, min(1, $0)) * 32767) })
        drainPending()
    }

    /// Samples accepted by `feed` that the engine has not taken yet.
    public var pendingSamples: Int { lock.lock(); defer { lock.unlock() }; return pending.count - pendingOffset }

    private var pending: [Int16] = []
    private var pendingOffset = 0

    private func drainPending() {   // caller holds `lock`
        while pendingOffset < pending.count {
            let n = min(3200, pending.count - pendingOffset)
            let rc = pending[pendingOffset..<pendingOffset + n].withUnsafeBufferPointer {
                be_essence2_push_audio(handle, $0.baseAddress!, Int32(n))
            }
            if rc != 0 { break }            // ring full or not ready: keep the rest for later
            pendingOffset += n
        }
        if pendingOffset == pending.count { pending.removeAll(keepingCapacity: true); pendingOffset = 0 }
    }

    /// The next frame (height*width*3 bytes in B, G, R order) and whether it is a speech frame;
    /// nil when none is due yet or none is ready — keep showing the frame you have.
    ///
    /// Paced (2.17.0): at most one frame per 1/25 s however often it is called, so a display
    /// loop, a timer or a tight loop all get 25 frames a second. Between replies the frames are
    /// idle motion (`speech: false`); it does not return nil forever after a reply. To know
    /// when a reply is over use ``pullFrame()`` (its `endsReply`), ``frames()`` or ``events()``.
    /// Returns nil while metering refuses — `meteringRefusal` then carries the engine's sentence.
    public func pull() -> (frame: [UInt8], speech: Bool)? {
        guard let f = pullFrame() else { return nil }
        return (f.bgr, f.isSpeech)
    }

    /// ``pull()`` with everything the engine knows about the frame: whether it is speech, and
    /// whether it is the first frame after a reply ended. nil when no frame is due or ready.
    ///
    /// - Parameter audioClock: seconds of the CURRENT reply's audio your audio device has played
    ///   (nil before it starts, e.g. `player.playerTime(forNodeTime:)` / sample rate). With it, a
    ///   reply's frames are handed out as the device plays them — lips follow the voice whatever
    ///   your output's start latency. Without it the reply is paced from its first speech frame.
    public func pullFrame(audioClock: (@Sendable () -> Double?)? = nil) -> Essence2Frame? {
        let a = audioClock?()
        let t = Essence2FrameClock.now()
        lock.lock()
        guard let got = takeLocked(now: t, into: nil, audio: a) else { lock.unlock(); return nil }
        let frame = Essence2Frame(bgr: Array(buffer.prefix(got.bytes)), width: got.width,
                                  height: got.height, isSpeech: got.kind == .speech,
                                  endsReply: got.endsReply, index: got.index, audioTime: got.audioTime)
        lock.unlock()
        emit(got.events)
        return frame
    }

    /// Wait for the next frame on the frame clock and return it; nil once the engine is shut
    /// down or the calling task is cancelled.
    public func nextFrame(audioClock: (@Sendable () -> Double?)? = nil) async -> Essence2Frame? {
        while !Task.isCancelled {
            guard let (paced, wait) = timeToNextFrame(audio: audioClock?()) else { return nil }
            if wait > 0 {
                try? await Task.sleep(nanoseconds: UInt64(min(wait, 0.04) * 1e9))
                continue
            }
            if let f = pullFrame(audioClock: audioClock) { return f }
            // Due but none rendered yet (the engine is computing a reply's first window).
            try? await Task.sleep(nanoseconds: paced ? 4_000_000 : 1_000_000)
        }
        return nil
    }

    /// (paced, seconds until the next frame is due), or nil once shut down. Synchronous: an
    /// NSLock may not be taken across an `await`.
    private func timeToNextFrame(audio: Double?) -> (Bool, Double)? {
        lock.lock(); defer { lock.unlock() }
        if closed { return nil }
        let paced = pacingValue == .realtime
        guard paced else { return (false, 0) }
        let now = Essence2FrameClock.now()
        if clock.anchored, let a = audio {
            let byAudio = max(0, Double(replySpeech) / Essence2Engine.framesPerSecond - clock.tolerance - a)
            return (true, min(byAudio, max(0, 3 * clock.period - clock.lateness(now))))
        }
        return (true, clock.wait(until: now))
    }

    /// The frames, paced to the frame clock (25 per second), for as long as you iterate:
    /// idle motion between replies, speech while a reply plays. The stream ends when the engine
    /// shuts down or your task is cancelled. One consumer per stream; every way of taking
    /// frames (`pull`, `idle(into:)`, `nextFrame`, `frames`) draws from the same engine.
    ///
    ///     for await f in engine.frames() {
    ///         show(f.bgr, f.width, f.height)
    ///         if f.endsReply { /* the reply is over */ }
    ///     }
    public func frames(audioClock: (@Sendable () -> Double?)? = nil) -> AsyncStream<Essence2Frame> {
        AsyncStream(unfolding: { [weak self] in await self?.nextFrame(audioClock: audioClock) })
    }

    /// Reply boundaries, derived from the frames actually handed out (by any call):
    /// `.replyStarted` with the first speech frame of a reply — start the reply's audio then to
    /// keep voice and lips together — and `.replyEnded` once the avatar is back at rest, exactly
    /// once per reply (an interrupted one too). Any number of listeners; each stream ends at
    /// `shutdown()`.
    public func events() -> AsyncStream<Essence2Event> {
        let id = UUID()
        return AsyncStream { continuation in
            listenersLock.lock()
            let open = !isClosedForListeners
            if open { listeners[id] = continuation }
            listenersLock.unlock()
            if !open { continuation.finish(); return }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.listenersLock.lock(); self.listeners[id] = nil; self.listenersLock.unlock()
            }
        }
    }
    private var isClosedForListeners = false

    /// No more audio for this reply: the engine renders the rest of it and eases back to rest
    /// now, instead of waiting for 0.6 s without audio (the same name as Expression 2's).
    /// Audio fed afterwards opens the next reply.
    public func flushTail() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        drainPending()
        _ = be_essence2_end_utterance(handle)
    }

    /// The next idle frame into `out` (B, G, R). Returns bytes written; 0 means keep showing the
    /// frame you have (it never means "show something else"). Paced like ``pull()``, and it
    /// draws from the same frames: a speech frame can come out of it while a reply plays.
    public func idle(into out: inout [UInt8]) -> Int {
        let t = Essence2FrameClock.now()
        lock.lock()
        let got = out.withUnsafeMutableBufferPointer { takeLocked(now: t, into: $0, audio: nil) }
        lock.unlock()
        guard let got else { return 0 }
        emit(got.events)
        return got.bytes
    }

    /// One frame from the engine, if one is due (paced) and ready. Caller holds `lock`.
    /// `into` nil: pull into `buffer`; otherwise the idle entry point into the caller's buffer.
    ///
    /// ★THE CLOCK, AND WHY IT CANNOT DRIFT FROM THE VOICE (2026-09-26). Monotonic time
    /// (mach uptime). Between replies frames follow a free-running 25 fps grid. A reply's
    /// FIRST speech frame re-anchors it — that frame is handed out at once, and it is the moment
    /// the documented loop starts the reply's audio — and from there frame k of the reply is due
    /// at anchor + k/25, never re-anchored. A frame that is already a full period late when it
    /// is pulled (a stall, or a caller slower than 25 Hz) is DROPPED when the next one is ready,
    /// so presentation stays within one frame of the reply's timeline instead of accumulating
    /// lag. What is left is the audio device's own clock against uptime (parts per million).
    /// `Essence2Frame.audioTime` carries each speech frame's place in the reply's audio for an
    /// app that presents by its audio device's playout position.
    private func takeLocked(now: Double, into out: UnsafeMutableBufferPointer<UInt8>?, audio: Double?)
        -> (bytes: Int, width: Int, height: Int, kind: Essence2FrameKind, endsReply: Bool,
            index: Int, audioTime: Double?, events: [Essence2Event])? {
        guard !closed else { return nil }
        drainPending()
        let paced = pacingValue == .realtime
        if paced {
            if clock.anchored, let a = audio {
                // By the device: the next speech frame goes when its audio is playing. If the device
                // stopped advancing (the reply's audio has ended), the grid takes over 3 frames late.
                let nextAudio = Double(replySpeech) / Essence2Engine.framesPerSecond
                guard a + clock.tolerance >= nextAudio || clock.lateness(now) >= 3 * clock.period else { return nil }
            } else if !clock.isDue(now) { return nil }
        }
        func pullOne() -> Int32 {
            if let out { return be_essence2_idle_frame(handle, out.baseAddress, Int32(out.count)) }
            guard be_essence2_frames_available(handle) > 0 else { return 0 }
            fitBuffer()
            return buffer.withUnsafeMutableBufferPointer { be_essence2_pull_frame(handle, $0.baseAddress, Int32($0.count)) }
        }
        var n = pullOne()
        if n == -3 { refusedNow = true; return nil }
        guard n > 0 else { return nil }
        refusedNow = false
        var events: [Essence2Event] = []
        var ends = false
        var kind = Essence2FrameKind.idle
        var audioTime: Double? = nil
        while true {
            let sc = be_essence2_pulled_speech_frames(handle)
            let speech = sc > lastSpeech
            lastSpeech = sc
            kind = Essence2FrameKind(engine: be_essence2_last_frame_kind(handle), speech: speech)
            let r = replies.note(kind)
            events += r.events
            ends = ends || r.endsReply
            if r.events.contains(.replyStarted) { replySpeech = 0 }
            audioTime = nil
            if kind == .speech {
                audioTime = Double(replySpeech) / Essence2Engine.framesPerSecond
                replySpeech += 1
            }
            guard paced else { break }
            if r.events.last == .replyStarted {
                clock.anchorReply(at: now)          // speech frame 0: shown now, its audio starts now
                break
            }
            if r.events.last == .replyEnded { clock.endReply() }
            // A full period late and the next frame is ready: this one is stale — drop it. By the
            // device when there is one (it has already played past this speech frame).
            let stale: Bool
            if let a = audio, let at = audioTime, clock.anchored {
                stale = a >= at + clock.period
            } else {
                stale = clock.isStale(now)
            }
            guard stale, be_essence2_frames_available(handle) > 0 else {
                clock.delivered(at: now)
                break
            }
            let next = pullOne()
            guard next > 0 else { clock.delivered(at: now); break }   // nothing newer: show this one
            clock.skipped()
            dropped += 1
            n = next
        }
        let d = dimsLocked()
        let index = handedOut
        handedOut += 1
        return (Int(n), d.w, d.h, kind, ends, index, audioTime, events)
    }

    private func emit(_ events: [Essence2Event]) {
        guard !events.isEmpty else { return }
        listenersLock.lock(); let ls = Array(listeners.values); listenersLock.unlock()
        for e in events { for c in ls { c.yield(e) } }
    }

    /// Barge-in: drop queued audio and frames; the video rides on from the current frame.
    public func interrupt() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        pending.removeAll(); pendingOffset = 0
        be_essence2_reset(handle)
        lastSpeech = be_essence2_pulled_speech_frames(handle)
        replies.interrupted()
        clock.endReply()
    }

    /// Frames this engine dropped to keep a reply's picture on its audio's timeline (a frame a
    /// full period late when a newer one was ready). 0 while the caller keeps up.
    public var droppedFrames: Int { lock.lock(); defer { lock.unlock() }; return dropped }

    /// End the session: the final billing beat is flushed, then the engine is released.
    public func shutdown() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        lock.unlock()
        listenersLock.lock()
        isClosedForListeners = true
        let ls = Array(listeners.values); listeners.removeAll()
        listenersLock.unlock()
        for c in ls { c.finish() }
        be_essence2_destroy(handle)
    }

    /// Set when this engine's own runtime failed and it stopped rather than hand back idle
    /// frames forever (`be_essence2_render_status`); nil while it is healthy.
    public var runtimeFailure: String? {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return nil }
        var buf = [CChar](repeating: 0, count: 512)
        var failures: Int64 = 0
        guard be_essence2_render_status(handle, &buf, Int32(buf.count), &failures) != 0 else { return nil }
        let r = Essence2Engine.text(buf)
        return r.isEmpty ? "the Essence 2 runtime stopped (\(failures) failure(s))" : r
    }

    /// Before the process exits: let every engine's last beat leave the machine.
    public static func quiesceAll(timeoutMs: Int32 = 5_000) { _ = be_essence2_quiesce_all(timeoutMs) }

    /// The engine's frame size. Caller holds `lock` (or is `init`). ★After `shutdown()` the handle
    /// is released, so the last size read is returned instead of asking a freed engine (2.17.1:
    /// until then `width`/`height`/`isReady`/`runtimeFailure` after `shutdown()` read freed memory
    /// and could crash the app).
    private func dimsLocked() -> (w: Int, h: Int) {
        guard !closed else { return lastDims }
        var w: Int32 = 0, h: Int32 = 0
        be_essence2_get_info(handle, &w, &h)
        lastDims = (Int(w), Int(h))
        return lastDims
    }
    private var lastDims: (w: Int, h: Int) = (0, 0)

    /// A NUL-terminated C buffer as UTF-8 text.
    static func text(_ buf: [CChar]) -> String {
        String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func lastRefusal() -> String? {
        var buf = [CChar](repeating: 0, count: 1024)
        let n = be_essence2_last_refusal(&buf, Int32(buf.count))
        guard n > 0 else { return nil }
        return Essence2Engine.text(buf)
    }
}

// MARK: - Following an AVAudioPlayerNode

extension Essence2Engine {
    /// ``frames(audioClock:)`` following an `AVAudioPlayerNode` that plays each reply FROM THE
    /// START when the reply's first speech frame arrives (`audioTime == 0`):
    /// `player.stop(); player.scheduleBuffer(reply); player.play()`. The reply's frames are then
    /// handed out as the player plays their audio, so lips follow the voice whatever the output's
    /// start latency (measured on a Mac: ~50-60 ms that a plain 25 fps loop shows too early).
    public func frames(following player: AVAudioPlayerNode) -> AsyncStream<Essence2Frame> {
        let clock = Essence2PlayerClock(player)
        return frames(audioClock: { clock.played() })
    }
}

/// Seconds of the current reply an `AVAudioPlayerNode` has played, from its own render timeline.
final class Essence2PlayerClock: @unchecked Sendable {
    private let player: AVAudioPlayerNode
    init(_ player: AVAudioPlayerNode) { self.player = player }
    func played() -> Double? {
        guard player.isPlaying, let nt = player.lastRenderTime, nt.isSampleTimeValid,
              let pt = player.playerTime(forNodeTime: nt), pt.sampleRate > 0 else { return nil }
        return max(0, Double(pt.sampleTime) / pt.sampleRate)
    }
}

// MARK: - Frames, pacing and replies

/// One frame from ``Essence2Engine``.
public struct Essence2Frame: Sendable {
    /// B, G, R bytes, `width * height * 3`.
    public let bgr: [UInt8]
    public let width: Int
    public let height: Int
    /// True while the mouth is driven by audio you fed; false for idle motion and for the short
    /// ease back to rest after a reply.
    public let isSpeech: Bool
    /// True on the first frame after a reply is over — normally an idle frame, the avatar back at
    /// rest; a speech frame if the next reply follows at once. Once per reply, interrupted ones too.
    public let endsReply: Bool
    /// This engine's frame count before this frame (0, 1, 2, …).
    public let index: Int
    /// For a speech frame: where it sits in the reply's audio, in seconds (frame k shows the
    /// audio from k/25 s). An app that presents by its audio device's playout position shows
    /// this frame once the device has played that much of the reply. nil for idle and ramp.
    public let audioTime: Double?
}

/// A reply boundary (``Essence2Engine/events()``).
public enum Essence2Event: Sendable, Equatable {
    /// The first speech frame of a reply was handed out.
    case replyStarted
    /// The reply is over and the avatar is back at rest (exactly once per reply).
    case replyEnded
}

/// How ``Essence2Engine`` hands out frames.
public enum Essence2Pacing: Sendable, Equatable {
    /// At most one frame per 1/25 s (the model's frame clock). The default.
    case realtime
    /// As fast as the engine renders, for offline rendering and benchmarks. Between replies the
    /// engine renders idle frames as fast as it is asked, so stop at `endsReply`.
    case unpaced
}

/// What a frame shows, from `be_essence2_last_frame_kind` (essence2-v1.14.0+).
enum Essence2FrameKind: Equatable {
    case idle, speech, ramp
    init(engine: Int32, speech: Bool) {
        switch engine {
        case 1: self = .speech
        case 2: self = .ramp
        case 0: self = .idle
        default: self = speech ? .speech : .idle   // no tag: the speech counter decides
        }
    }
}

/// The frame clock (see `Essence2Engine.takeLocked`). Between replies: frame k is due at
/// t0 + k/fps; a caller that asks early gets nothing; one that fell behind gets at most `maxLag`
/// frames back to back, then the grid re-anchors on it. Inside a reply (`anchored`): frame k is
/// due at anchor + k/fps and the grid NEVER re-anchors — lateness is paid by dropping stale
/// frames, so the picture cannot drift from the reply's audio. A caller up to `tolerance` early
/// is on time, so a 40 ms timer that wakes a hair early still gets every frame.
struct Essence2FrameClock {
    let period: Double
    let tolerance: Double
    let maxLag: Double
    private(set) var next: Double?
    private(set) var anchored = false

    init(fps: Double, tolerance: Double = 0.002, maxLag: Int = 2) {
        period = 1 / fps; self.tolerance = tolerance; self.maxLag = Double(maxLag); next = nil
    }

    func isDue(_ now: Double) -> Bool { next.map { now + tolerance >= $0 } ?? true }

    /// Seconds until the next frame is due (0 = now).
    func wait(until now: Double) -> Double { next.map { max(0, $0 - tolerance - now) } ?? 0 }

    /// How far past its due time the frame being handed out is (seconds; <= 0 on time).
    func lateness(_ now: Double) -> Double { next.map { now - $0 } ?? 0 }

    mutating func delivered(at now: Double) {
        guard let due = next else { next = now + period; return }
        if anchored { next = due + period; return }
        next = (now - due > maxLag * period) ? now + period : due + period
    }

    /// Inside a reply, the frame being handed out is a full period late: the next one is due.
    func isStale(_ now: Double) -> Bool { anchored && lateness(now) >= period }

    /// A stale frame was dropped: its slot passes and the next frame takes the one after.
    mutating func skipped() { if let due = next { next = due + period } }

    /// A reply's first speech frame was handed out at `now`: the reply's timeline starts here.
    mutating func anchorReply(at now: Double) { anchored = true; next = now + period }

    /// The reply is over (or cut): back to the free-running grid.
    mutating func endReply() { anchored = false }

    mutating func reset() { next = nil; anchored = false }

    static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
}

/// Reply boundaries from the kinds of the frames handed out. A reply opens with its first
/// speech frame and ends at the first idle frame after it (after the ramp back to rest, or at
/// once when the reply was interrupted and no ramp was shown); a ramp followed straight by
/// speech ends one reply and opens the next.
struct Essence2ReplyTracker {
    private(set) var inReply = false
    private var ramped = false

    /// A barge-in cut the reply: whatever speech comes next belongs to a new one.
    mutating func interrupted() { if inReply { ramped = true } }

    mutating func note(_ kind: Essence2FrameKind) -> (events: [Essence2Event], endsReply: Bool) {
        switch kind {
        case .speech:
            if !inReply { inReply = true; ramped = false; return ([.replyStarted], false) }
            if ramped { ramped = false; return ([.replyEnded, .replyStarted], true) }
            return ([], false)
        case .ramp:
            if inReply { ramped = true }
            return ([], false)
        case .idle:
            guard inReply else { return ([], false) }
            inReply = false; ramped = false
            return ([.replyEnded], true)
        }
    }
}

// MARK: - Download

/// Downloads an Essence 2 avatar file through the bitHuman download door.
///
/// It asks for the Apple slice of the avatar (`?slice=apple`): the members this engine reads,
/// smaller than the full file. The door answers with the slice and its sha256, or with the full
/// file when that avatar has no slice yet; either one opens with `Essence2Engine.create`. A slice
/// whose bytes do not match the door's sha256 is refused, never opened. Files are kept under
/// their content hash, so a second call for the same avatar downloads nothing.
///
/// ★A CACHE HIT NO LONGER WAITS FOR THE DOOR (2.20.1). Up to 2.20.0 every call asked the door
/// first and only then looked in the cache, so opening an avatar already on the device waited on
/// a network round trip (the same blocking check measured a 2.65 s median on Android), and a door
/// error FAILED the open even with a good copy on disk. Now the last file this downloader served
/// for the avatar (`revalidateInBackground`, on by default):
///  * is returned at once, after its sha256 is checked, and the door is asked in the background
///    (one request per avatar in flight);
///  * when the door names a different file, that file is downloaded and checked into a staging
///    area and a swap journal is written. The file the app is opening now is never touched;
///  * the next call finishes the swap from disk, with no network, and returns the new file;
///  * a door that is down, slow or refusing never fails a call that has a good copy.
/// With no copy on the device a call works exactly as before. `revalidateInBackground = false`
/// restores the blocking check: the door is asked before returning and a change lands on this
/// call (a door error still returns the copy on disk).
///
/// ★NOT IN THE USER'S BACKUPS (2.20.2). Every file this downloader writes — the `.imx` files, its
/// `.door/` bookkeeping and staging, and the default directory itself — carries
/// `isExcludedFromBackup`: an avatar is downloaded again on demand, so it must not fill the user's
/// iCloud or computer backup (Apple's data storage guidelines). A directory you pass in is never
/// flagged as a whole; only the files this downloader puts in it are.
///
/// ★A COPY OPENS ONLY FOR A CREDENTIAL THE DOOR HAS SAID YES TO (2.20.2, security). The download
/// directory belongs to the app, not to an account: in 2.20.1 account B, signed in where account A
/// had opened its PRIVATE avatar, got A's file back at once, and the door's refusal of B (it is
/// owner-scoped: 404 "Agent not found") was ignored; the session meter checks the key, not the
/// avatar. A copy is now returned only when the current credential holds an entitlement mark for
/// that avatar (`.door/<key>.auth/<tag>`, the tag a salted SHA-256 prefix of the credential, never
/// the credential): the door's 200 for that credential writes it, its 401/403/404 drops it. A
/// credential without a mark asks the door first, as in 2.20.0, and a refusal is thrown. A
/// credential with a mark keeps everything above: the open is instant and a door that is down
/// never fails it.
public enum Essence2Download {
    static let door = "https://api.bithuman.ai"
    /// Highest container ABI this engine reads.
    static let abiMax = 1
    /// The product the door is asked for.
    static let model = "essence-2"
    /// Seconds a revalidation waits for the door's answer (a call with no copy waits as before).
    static let revalidateTimeout: TimeInterval = 10

    /// True (the default): a call for an avatar already on the device returns that file at once
    /// and asks the door in the background; a change is staged and lands on the next call.
    /// False: the door is asked before returning, as up to 2.20.0, and a change lands on this
    /// call. Either way a door that is down, slow or failing never fails a call that has a good
    /// copy THIS credential has opened before (2.20.2); the door's refusal of the credential does.
    public static var revalidateInBackground: Bool {
        get { optionLock.lock(); defer { optionLock.unlock() }; return background }
        set { optionLock.lock(); background = newValue; optionLock.unlock() }
    }
    private static let optionLock = NSLock()
    nonisolated(unsafe) private static var background = true

    /// Downloads avatar `agentCode` (for example `A52DHS2219`) and returns the file to pass to
    /// `Essence2Engine.create(identity:)`. Uses the secret from `Essence2Credential.set`.
    public static func identity(agentCode: String, directory: URL? = nil) async throws -> URL {
        try await identity(agentCode: agentCode, directory: directory, io: .network,
                           mode: revalidateInBackground ? .background : .blocking)
    }

    /// How a call treats a copy already on the device.
    enum Mode: Sendable {
        /// Return the copy at once; ask the door in the background, stage a change.
        case background
        /// Ask the door first; a change lands now; a door error returns the copy.
        case blocking
        /// The door's current file, as up to 2.20.0: the heal's re-fetch (`Essence2Engine.create`),
        /// which must not be handed back the file the engine just refused.
        case doorFirst
    }

    /// `identity` with the door and the mode as parameters (tests script the door).
    static func identity(agentCode: String, directory: URL?, io: DoorIO, mode: Mode) async throws -> URL {
        guard agentCode.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil else {
            throw Essence2KitError.resourcesUnavailable("not an agent code: \(agentCode)")
        }
        let dir = directory ?? Essence2Download.defaultDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if directory == nil { excludeFromBackup(dir) }  // ours; a caller's directory is never flagged whole
        let store = DoorStore(dir: dir, key: "\(agentCode).\(model).apple.abi\(abiMax)")
        // ★ONE CREDENTIAL PER CALL (2.20.2): read once; the door's answer to the request that
        // carried it is the only thing that marks (or unmarks) it.
        let credential = Essence2Credential.current
        let tag = credentialTag(credential)
        if mode != .doorFirst {
            store.finishPendingSwap()                  // from disk: never a request
            if let hit = store.current(), store.isAuthorized(tag) {
                if mode == .background {
                    revalidateLater(agentCode: agentCode, store: store, io: io, credential: credential)
                    return excludeFromBackup(hit)
                }
                // nil: the door refused this credential just now; the door path below says how.
                if let url = await revalidateNow(agentCode: agentCode, store: store, hit: hit, io: io,
                                                 credential: credential) { return excludeFromBackup(url) }
            }
        }
        // No copy on the device, a copy this credential has no mark for, or the heal's re-fetch:
        // exactly the 2.20.0 path (the door first; a refusal or a door error fails the call).
        let g: Grant
        do { g = try await grant(agentCode: agentCode, io: io, timeout: nil, credential: credential) }
        catch let e as DoorAnswer { if e.isDenial { store.deny(tag) }; throw e.error }
        store.authorize(tag)
        if let want = g.sha256, let hit = try? cached(want, in: dir) {
            store.record(want)
            return excludeFromBackup(hit)
        }
        let tmp = try await fetch(agentCode: agentCode, grant: g, io: io)
        let dst = dir.appendingPathComponent(tmp.sha256 + ".imx")
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.moveItem(at: tmp.file, to: dst)
        store.record(tmp.sha256)
        return excludeFromBackup(dst)
    }

    /// Flags `url` (a file or a directory this SDK owns) `isExcludedFromBackup` and returns it.
    /// Best effort: a volume that cannot carry the flag still serves the file.
    @discardableResult
    static func excludeFromBackup(_ url: URL) -> URL {
        var u = url
        var v = URLResourceValues()
        v.isExcludedFromBackup = true
        try? u.setResourceValues(v)
        return url
    }

    /// The mark name for `credential`: 32 hex of SHA-256 over a fixed salt and the credential
    /// ("" when there is none). Never the credential itself.
    static func credentialTag(_ credential: String?) -> String {
        String(Essence2Resources.sha256Hex(Data(("bithuman.door.auth.v1\u{0}" + (credential ?? "")).utf8)).prefix(32))
    }

    /// The door's non-200 answer to a grant request, kept apart from an unreachable door: 401 and
    /// 403 refuse the credential and 404 the avatar for it (the door is owner-scoped).
    struct DoorAnswer: Error {
        let status: Int
        let error: Error
        /// `error.code` of the door's body (`NOT_FOUND`, `MODEL_ARTIFACT_NOT_READY`, ...), or nil.
        var code: String? = nil
        /// 401/403 refuse the credential, 404 NOT_FOUND ("Agent not found") the avatar for it. Not
        /// a "no": 404 MODEL_ARTIFACT_NOT_READY, which the door answers the OWNER while an avatar is
        /// re-baked or published (poll on it), or any other answer.
        var isDenial: Bool { status == 401 || status == 403 || (status == 404 && code == "NOT_FOUND") }
    }

    /// `error.code` of a door error body (`{"error": {"code": "NOT_FOUND", ...}}`), or nil.
    static func doorErrorCode(_ body: String) -> String? {
        guard let r = body.range(of: "\"code\"\\s*:\\s*\"[A-Za-z0-9_]+\"", options: .regularExpression) else { return nil }
        let m = body[r]
        guard let open = m.dropLast().lastIndex(of: "\"") else { return nil }
        return String(m[m.index(after: open)..<m.index(before: m.endIndex)])
    }

    // MARK: the two requests

    /// The door's answer for one avatar: where its file is, and the sha256 it must have.
    struct Grant: Sendable {
        let url: URL
        let sha256: String?
        let isSlice: Bool
    }

    /// The download's two requests, as parameters: tests serve a scripted door, the app gets `.network`.
    struct DoorIO: Sendable {
        /// The door's answer to `request`: (HTTP status, body). Throws when the door cannot be reached.
        var grant: @Sendable (URLRequest) async throws -> (Int, Data)
        /// The file at `url` in a temporary location the caller then owns: (HTTP status, file).
        var file: @Sendable (URL) async throws -> (Int, URL)

        static let network = DoorIO(
            grant: { req in
                let (body, resp) = try await URLSession.shared.data(for: req)
                return ((resp as? HTTPURLResponse)?.statusCode ?? -1, body)
            },
            file: { url in
                let (tmp, resp) = try await URLSession.shared.download(from: url)
                return ((resp as? HTTPURLResponse)?.statusCode ?? -1, tmp)
            })
    }

    /// Throws `DoorAnswer` (wrapping the error 2.20.1 threw) when the door answers but not 200, and
    /// passes through what `io` throws when the door cannot be reached.
    static func grant(agentCode: String, io: DoorIO, timeout: TimeInterval?,
                      credential: String?) async throws -> Grant {
        guard var c = URLComponents(string: door + "/v1/agent/" + agentCode + "/model/download") else {
            throw Essence2KitError.resourcesUnavailable("not an agent code: \(agentCode)")
        }
        c.queryItems = [URLQueryItem(name: "model", value: model),
                        URLQueryItem(name: "slice", value: "apple"),
                        URLQueryItem(name: "abi_max", value: String(abiMax)),
                        URLQueryItem(name: "redirect", value: "false")]
        var req = URLRequest(url: c.url!)
        if let timeout { req.timeoutInterval = timeout }
        if let s = credential { req.setValue(s, forHTTPHeaderField: "api-secret") }
        let (status, body) = try await io.grant(req)
        guard status == 200,
              let root = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let d = root["data"] as? [String: Any],
              let urlString = d["url"] as? String, let url = URL(string: urlString) else {
            let msg = String(decoding: body.prefix(300), as: UTF8.self)
            throw DoorAnswer(status: status, error: Essence2KitError.resourcesUnavailable(
                "\(agentCode): the download door answered HTTP \(status): \(msg)"), code: doorErrorCode(msg))
        }
        return Grant(url: url, sha256: (d["raw_sha256"] as? String) ?? (d["sha256"] as? String),
                     isSlice: (d["slice"] as? String).map { $0 != "universal" } ?? false)
    }

    /// Downloads the granted file and checks it against the door's sha256; the caller owns the file.
    static func fetch(agentCode: String, grant g: Grant, io: DoorIO) async throws -> (file: URL, sha256: String) {
        let (status, tmp) = try await io.file(g.url)
        guard status == 200 else {
            try? FileManager.default.removeItem(at: tmp)
            throw Essence2KitError.resourcesUnavailable("\(agentCode): the avatar file download failed (HTTP \(status))")
        }
        let got = try Essence2Resources.sha256(of: tmp)
        if let want = g.sha256, got != want {
            try? FileManager.default.removeItem(at: tmp)
            throw Essence2KitError.resourcesUnavailable("\(agentCode): the \(g.isSlice ? "apple slice" : "avatar file") is sha256 \(got), not the door's \(want); refused")
        }
        return (tmp, got)
    }

    // MARK: revalidation

    /// What one revalidation did. Internal: the app only ever sees a file. `keptDenied` (2.20.2):
    /// the door refused the credential the check carried (401/403/404); its mark is dropped.
    enum Revalidated: Sendable, Equatable { case unchanged, staged, swapped, keptUnreachable, keptFailed, keptDenied }

    /// The background half of a cache hit: at most one per avatar (and directory) in flight.
    static func revalidateLater(agentCode: String, store: DoorStore, io: DoorIO, credential: String?) {
        inFlight.start(store.id) { await stage(agentCode: agentCode, store: store, io: io, credential: credential) }
    }

    /// The blocking check (`revalidateInBackground = false`): stage, swap now, and hand back a
    /// verified file whatever happened — except a refusal of this credential: nil (never throws).
    static func revalidateNow(agentCode: String, store: DoorStore, hit: URL, io: DoorIO,
                              credential: String?) async -> URL? {
        let r = await stage(agentCode: agentCode, store: store, io: io, credential: credential)
        if r == .keptDenied { return nil }
        guard r == .staged else { return hit }
        store.finishPendingSwap()
        return store.current() ?? hit
    }

    /// Asks the door; when it names another file, downloads and checks it into the staging area
    /// and writes the swap journal. It never touches the file the app has open, and never throws.
    /// The door's answer marks (200) or unmarks (401/403/404) `credential` for this avatar.
    @discardableResult
    static func stage(agentCode: String, store: DoorStore, io: DoorIO, credential: String?) async -> Revalidated {
        let have = store.currentSha()
        let tag = credentialTag(credential)
        let g: Grant
        do { g = try await grant(agentCode: agentCode, io: io, timeout: revalidateTimeout, credential: credential) }
        catch let e as DoorAnswer {
            if e.isDenial { store.deny(tag); return .keptDenied }
            return .keptUnreachable
        } catch {
            return .keptUnreachable
        }
        store.authorize(tag)
        if let want = g.sha256 {
            if want == have { return .unchanged }
            if (try? cached(want, in: store.dir)) != nil { store.journal(want); return .staged }
        }
        let got: (file: URL, sha256: String)
        do { got = try await fetch(agentCode: agentCode, grant: g, io: io) } catch { return .keptFailed }
        if got.sha256 == have { try? FileManager.default.removeItem(at: got.file); return .unchanged }
        do { try store.stageFile(got.file, sha256: got.sha256) } catch {
            try? FileManager.default.removeItem(at: got.file)
            return .keptFailed
        }
        store.journal(got.sha256)
        return .staged
    }

    /// The revalidations in flight, by avatar and directory. Tests wait for them with `settle()`.
    static let inFlight = InFlight()

    /// Waits for every background revalidation in flight (tests; the app never needs to).
    static func settle() async { await inFlight.settle() }

    final class InFlight: @unchecked Sendable {
        private let lock = NSLock()
        private var tasks: [String: Task<Revalidated, Never>] = [:]
        private(set) var last: [String: Revalidated] = [:]

        func start(_ id: String, _ work: @escaping @Sendable () async -> Revalidated) {
            lock.lock(); defer { lock.unlock() }
            guard tasks[id] == nil else { return }       // one per avatar in flight
            tasks[id] = Task.detached(priority: .utility) { [weak self] in
                let r = await work()
                self?.finish(id, r)
                return r
            }
        }

        private func finish(_ id: String, _ r: Revalidated) {
            lock.lock(); tasks[id] = nil; last[id] = r; lock.unlock()
        }

        func lastOutcome(_ id: String) -> Revalidated? { lock.lock(); defer { lock.unlock() }; return last[id] }

        private func running() -> [Task<Revalidated, Never>] {
            lock.lock(); defer { lock.unlock() }; return Array(tasks.values)
        }

        func settle() async {
            while true {
                let running = running()
                if running.isEmpty { return }
                for t in running { _ = await t.value }
            }
        }
    }

    /// The bookkeeping beside the files, in `<directory>/.door/`: `<key>.current` names the file
    /// last served for an avatar, `<key>.pending` a staged one the next call swaps in, and
    /// `staging/<sha256>.imx` holds it until then. The `.imx` files themselves stay where they
    /// always were, named by their sha256, so a 2.20.0 cache is still a cache (its first call
    /// asks the door as before and records what it served).
    struct DoorStore: Sendable {
        let dir: URL
        let key: String
        var id: String { dir.standardizedFileURL.path + "|" + key }
        private var meta: URL { dir.appendingPathComponent(".door", isDirectory: true) }
        private var pointer: URL { meta.appendingPathComponent(key + ".current") }
        private var pending: URL { meta.appendingPathComponent(key + ".pending") }
        private var staging: URL { meta.appendingPathComponent("staging", isDirectory: true) }

        init(dir: URL, key: String) { self.dir = dir; self.key = key }

        /// Swaps run under one lock, so a journal is never written while a swap reads it.
        private static let swapLock = NSLock()

        /// `<key>.auth/<tag>`: the door said yes to the credential `tag` names for this avatar.
        private func mark(_ tag: String) -> URL {
            meta.appendingPathComponent(key + ".auth", isDirectory: true).appendingPathComponent(tag)
        }
        func isAuthorized(_ tag: String) -> Bool { FileManager.default.fileExists(atPath: mark(tag).path) }
        func authorize(_ tag: String) {
            let m = mark(tag)
            try? FileManager.default.createDirectory(at: m.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data().write(to: m, options: .atomic)
        }
        func deny(_ tag: String) { try? FileManager.default.removeItem(at: mark(tag)) }

        func currentSha() -> String? { Self.readSha(pointer) }

        /// The last file served for this avatar, if it is still on disk with its sha256.
        func current() -> URL? {
            guard let sha = currentSha() else { return nil }
            return try? cached(sha, in: dir)
        }

        /// What the no-copy path served: it becomes the current file, and any older journal goes.
        func record(_ sha: String) {
            Self.swapLock.lock(); defer { Self.swapLock.unlock() }
            Self.writeSha(sha, to: pointer)
            if let p = Self.readSha(pending), p != sha {
                try? FileManager.default.removeItem(at: staging.appendingPathComponent(p + ".imx"))
            }
            try? FileManager.default.removeItem(at: pending)
        }

        /// Moves a downloaded, checked file into the staging area.
        func stageFile(_ file: URL, sha256 sha: String) throws {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            Essence2Download.excludeFromBackup(meta)
            let dst = staging.appendingPathComponent(sha + ".imx")
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.moveItem(at: file, to: dst)
            Essence2Download.excludeFromBackup(dst)        // a rename keeps the flag when it is swapped in
        }

        /// The swap journal: the next call makes `sha` current.
        func journal(_ sha: String) {
            Self.swapLock.lock(); defer { Self.swapLock.unlock() }
            Self.writeSha(sha, to: pending)
        }

        /// Finishes a journalled swap from disk (no network): the staged file joins the others and
        /// becomes current. A journal whose file is gone is dropped. Safe to run again after a
        /// process died part-way.
        @discardableResult
        func finishPendingSwap() -> Bool {
            Self.swapLock.lock(); defer { Self.swapLock.unlock() }
            guard let sha = Self.readSha(pending) else { return false }
            let fm = FileManager.default
            let staged = staging.appendingPathComponent(sha + ".imx")
            let live = dir.appendingPathComponent(sha + ".imx")
            if fm.fileExists(atPath: staged.path) {
                if fm.fileExists(atPath: live.path) { try? fm.removeItem(at: staged) }
                else if (try? fm.moveItem(at: staged, to: live)) == nil { try? fm.removeItem(at: pending); return false }
            }
            guard fm.fileExists(atPath: live.path) else { try? fm.removeItem(at: pending); return false }
            Self.writeSha(sha, to: pointer)
            try? fm.removeItem(at: pending)
            return true
        }

        private static func readSha(_ u: URL) -> String? {
            guard let d = try? Data(contentsOf: u) else { return nil }
            let s = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return s.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil ? s : nil
        }

        private static func writeSha(_ sha: String, to u: URL) {
            try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            Essence2Download.excludeFromBackup(u.deletingLastPathComponent())   // `.door/`
            try? Data((sha + "\n").utf8).write(to: u, options: .atomic)
        }
    }

    /// Where downloads are kept when no directory is given: Caches/bitHuman/essence2/avatars.
    public static var defaultDirectory: URL {
        let root = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent("bitHuman/essence2/avatars", isDirectory: true)
    }

    /// True when `file` is one this downloader wrote: it names its files by their sha256.
    static func isDownloaded(_ file: URL) -> Bool {
        file.lastPathComponent.range(of: "^[0-9a-f]{64}\\.imx$", options: .regularExpression) != nil
    }

    /// The agent code the engine's out-of-date refusal names (`for identity '<code>'`), or "".
    static func agentCode(inRefusal sentence: String) -> String {
        guard let r = sentence.range(of: "for identity '[A-Za-z0-9_-]{1,64}'", options: .regularExpression)
        else { return "" }
        return String(sentence[r].dropFirst("for identity '".count).dropLast())
    }

    static func cached(_ sha: String, in dir: URL) throws -> URL? {
        let f = dir.appendingPathComponent(sha + ".imx")
        guard FileManager.default.fileExists(atPath: f.path) else { return nil }
        return try Essence2Resources.sha256(of: f) == sha ? f : nil
    }
}

// MARK: - Runtime resources

/// The engine's runtime resources — the audio frontend and its short-window pair — fetched once
/// from the GitHub release this package pins, and checked against sha256 values pinned HERE,
/// never against a checksum served beside the file.
public enum Essence2Resources {
    /// Must equal `essence2Tag` in Package.swift (the tap's check-apple-engine-pin.sh grades it).
    public static let releaseTag = "essence2-v1.15.4"
    static let base = "https://github.com/bithuman-product/homebrew-bithuman/releases/download/"
    static let files: [(name: String, sha256: String)] = [
        ("w2v_ess_fp16_v1.onnx", "7340a0350c340e059f0931d7381fad1ed8aa579cc4440fcc3223f136d9aaa8e5"),
        ("audio_encoder_fp16_window_trunk.onnx", "8cfc2a558236dcb787b46322c906e562e0cb1abe65a8f15f95f50d7cb8c86e88"),
        ("audio_encoder_fp16_window_head.onnx", "30b67891439db75b48a7a0469152e62b339298664c3aa72d5ab7426971940241"),
    ]

    /// Where fetched resources live (Application Support, so the OS does not purge them). The
    /// directory is excluded from the user's backups (2.20.2): the files are fetched again on demand.
    public static var directory: URL {
        let root = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent("bitHuman/essence2/\(releaseTag)", isDirectory: true)
    }

    /// Fetch (once) and verify the resources; returns their directory.
    public static func ensure() async throws -> URL {
        let dir = directory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Essence2Download.excludeFromBackup(dir)        // ~70 MB fetched again on demand: never backed up
        for f in files {
            let dst = dir.appendingPathComponent(f.name)
            if FileManager.default.fileExists(atPath: dst.path), (try? sha256(of: dst)) == f.sha256 { continue }
            guard let url = URL(string: base + releaseTag + "/" + f.name) else {
                throw Essence2KitError.resourcesUnavailable("bad URL for \(f.name)")
            }
            let (tmp, resp) = try await URLSession.shared.download(from: url)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                throw Essence2KitError.resourcesUnavailable("\(f.name): HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1) from \(url)")
            }
            let got = try sha256(of: tmp)
            guard got == f.sha256 else {
                try? FileManager.default.removeItem(at: tmp)
                throw Essence2KitError.resourcesUnavailable("\(f.name): sha256 \(got) is not the pinned \(f.sha256)")
            }
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.moveItem(at: tmp, to: dst)
        }
        return dir
    }

    /// Tell the engine where they are (its documented overrides; the pair is found beside the frontend).
    static func point(at dir: URL) {
        let w2v = dir.appendingPathComponent("w2v_ess_fp16_v1.onnx").path
        setenv("BH_A2X_W2V", w2v, 1)
        setenv("W2V_ONNX", w2v, 1)
        setenv("LE_A2X_W2V_WIN_ONNX", dir.appendingPathComponent("audio_encoder_fp16_window_trunk.onnx").path, 1)
        setenv("LE_A2X_W2V_HEAD_ONNX", dir.appendingPathComponent("audio_encoder_fp16_window_head.onnx").path, 1)
    }

    static func sha256(of url: URL) throws -> String {
        let h = FileHandle(forReadingAtPath: url.path)
        guard let h else { throw Essence2KitError.resourcesUnavailable("cannot read \(url.lastPathComponent)") }
        defer { try? h.close() }
        var hasher = SHA256()
        while true {
            let chunk = h.readData(ofLength: 4 << 20)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
}
