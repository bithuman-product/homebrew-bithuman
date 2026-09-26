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
//   for await f in engine.frames() {          // 25 per second, paced by the engine
//       show(f.bgr, f.width, f.height)        // B, G, R bytes
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
// Billing: a session is billed for its TALKING time only; idle is free. Without an API secret
// `create` throws `.meteringRefused` (the engine's own sentence). bithuman-models #1224.

import Foundation
import CryptoKit
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

    public var description: String {
        switch self {
        case .meteringRefused(let r): return r
        case .identityUnreadable(let p): return "\(p): the Essence 2 engine could not open this identity file"
        case .resourcesUnavailable(let m): return "Essence 2 resources: \(m)"
        case .notReady(let s): return "the Essence 2 engine was not ready after \(Int(s)) s"
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
    public var width: Int { dims().w }
    public var height: Int { dims().h }

    /// True once the engine can turn audio into speech frames.
    public var isReady: Bool { be_essence2_is_ready(handle) == 1 }

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
        let d = dims()
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
    public static func create(identity: URL,
                              resourcesDirectory: URL? = nil,
                              readyTimeout: Double = 300) async throws -> Essence2Engine {
        let res: URL
        if let given = resourcesDirectory { res = given } else { res = try await Essence2Resources.ensure() }
        Essence2Resources.point(at: res)
        var h: be_essence2_handle? = nil
        let rc = identity.path.withCString { be_essence2_create($0, nil, 0, &h) }
        switch rc {
        case 0: break
        case -3: throw Essence2KitError.meteringRefused(reason: lastRefusal()
                    ?? "refusing to serve: metering refused this session (see the engine's log line)")
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
    public func pullFrame() -> Essence2Frame? {
        let t = Essence2FrameClock.now()
        lock.lock()
        guard let got = takeLocked(now: t, into: nil) else { lock.unlock(); return nil }
        let frame = Essence2Frame(bgr: Array(buffer.prefix(got.bytes)), width: got.width,
                                  height: got.height, isSpeech: got.kind == .speech,
                                  endsReply: got.endsReply, index: got.index)
        lock.unlock()
        emit(got.events)
        return frame
    }

    /// Wait for the next frame on the frame clock and return it; nil once the engine is shut
    /// down or the calling task is cancelled.
    public func nextFrame() async -> Essence2Frame? {
        while !Task.isCancelled {
            lock.lock()
            if closed { lock.unlock(); return nil }
            let paced = pacingValue == .realtime
            let wait = paced ? clock.wait(until: Essence2FrameClock.now()) : 0
            lock.unlock()
            if wait > 0 {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))
                continue
            }
            if let f = pullFrame() { return f }
            // Due but none rendered yet (the engine is computing a reply's first window).
            try? await Task.sleep(nanoseconds: paced ? 4_000_000 : 1_000_000)
        }
        return nil
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
    public func frames() -> AsyncStream<Essence2Frame> {
        AsyncStream(unfolding: { [weak self] in await self?.nextFrame() })
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
        let got = out.withUnsafeMutableBufferPointer { takeLocked(now: t, into: $0) }
        lock.unlock()
        guard let got else { return 0 }
        emit(got.events)
        return got.bytes
    }

    /// One frame from the engine, if one is due (paced) and ready. Caller holds `lock`.
    /// `into` nil: pull into `buffer`; otherwise the idle entry point into the caller's buffer.
    private func takeLocked(now: Double, into out: UnsafeMutableBufferPointer<UInt8>?)
        -> (bytes: Int, width: Int, height: Int, kind: Essence2FrameKind, endsReply: Bool,
            index: Int, events: [Essence2Event])? {
        guard !closed else { return nil }
        drainPending()
        let paced = pacingValue == .realtime
        if paced && !clock.isDue(now) { return nil }
        let n: Int32
        if let out {
            n = be_essence2_idle_frame(handle, out.baseAddress, Int32(out.count))
        } else {
            guard be_essence2_frames_available(handle) > 0 else { return nil }
            fitBuffer()
            n = buffer.withUnsafeMutableBufferPointer { be_essence2_pull_frame(handle, $0.baseAddress, Int32($0.count)) }
        }
        if n == -3 { refusedNow = true; return nil }
        guard n > 0 else { return nil }
        refusedNow = false
        let sc = be_essence2_pulled_speech_frames(handle)
        let speech = sc > lastSpeech
        lastSpeech = sc
        let kind = Essence2FrameKind(engine: be_essence2_last_frame_kind(handle), speech: speech)
        if paced { clock.delivered(at: now) }
        let r = replies.note(kind)
        let d = dims()
        let index = handedOut
        handedOut += 1
        return (Int(n), d.w, d.h, kind, r.endsReply, index, r.events)
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
    }

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
        var buf = [CChar](repeating: 0, count: 512)
        var failures: Int64 = 0
        guard be_essence2_render_status(handle, &buf, Int32(buf.count), &failures) != 0 else { return nil }
        let r = Essence2Engine.text(buf)
        return r.isEmpty ? "the Essence 2 runtime stopped (\(failures) failure(s))" : r
    }

    /// Before the process exits: let every engine's last beat leave the machine.
    public static func quiesceAll(timeoutMs: Int32 = 5_000) { _ = be_essence2_quiesce_all(timeoutMs) }

    private func dims() -> (w: Int, h: Int) {
        var w: Int32 = 0, h: Int32 = 0
        be_essence2_get_info(handle, &w, &h)
        return (Int(w), Int(h))
    }

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

/// The frame clock: frame k is due at t0 + k/fps. A caller that asks early gets nothing; one
/// that fell behind gets at most `maxLag` frames back to back, then the clock re-anchors on it
/// (a stall is not paid back with a burst). A caller up to `tolerance` early is on time, so a
/// 40 ms timer that wakes a hair early still gets every frame.
struct Essence2FrameClock {
    let period: Double
    let tolerance: Double
    let maxLag: Double
    private(set) var next: Double?

    init(fps: Double, tolerance: Double = 0.002, maxLag: Int = 2) {
        period = 1 / fps; self.tolerance = tolerance; self.maxLag = Double(maxLag); next = nil
    }

    func isDue(_ now: Double) -> Bool { next.map { now + tolerance >= $0 } ?? true }

    /// Seconds until the next frame is due (0 = now).
    func wait(until now: Double) -> Double { next.map { max(0, $0 - tolerance - now) } ?? 0 }

    mutating func delivered(at now: Double) {
        guard let due = next else { next = now + period; return }
        next = (now - due > maxLag * period) ? now + period : due + period
    }

    mutating func reset() { next = nil }

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
public enum Essence2Download {
    static let door = "https://api.bithuman.ai"
    /// Highest container ABI this engine reads.
    static let abiMax = 1

    /// Downloads avatar `agentCode` (for example `A52DHS2219`) and returns the file to pass to
    /// `Essence2Engine.create(identity:)`. Uses the secret from `Essence2Credential.set`.
    public static func identity(agentCode: String, directory: URL? = nil) async throws -> URL {
        guard agentCode.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil,
              var c = URLComponents(string: door + "/v1/agent/" + agentCode + "/model/download") else {
            throw Essence2KitError.resourcesUnavailable("not an agent code: \(agentCode)")
        }
        c.queryItems = [URLQueryItem(name: "model", value: "essence-2"),
                        URLQueryItem(name: "slice", value: "apple"),
                        URLQueryItem(name: "abi_max", value: String(abiMax)),
                        URLQueryItem(name: "redirect", value: "false")]
        var req = URLRequest(url: c.url!)
        if let s = Essence2Credential.current { req.setValue(s, forHTTPHeaderField: "api-secret") }
        let (body, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200,
              let root = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let d = root["data"] as? [String: Any],
              let urlString = d["url"] as? String, let url = URL(string: urlString) else {
            let msg = String(decoding: body.prefix(300), as: UTF8.self)
            throw Essence2KitError.resourcesUnavailable("\(agentCode): the download door answered HTTP \(status): \(msg)")
        }
        let isSlice = (d["slice"] as? String).map { $0 != "universal" } ?? false
        let want = (d["raw_sha256"] as? String) ?? (d["sha256"] as? String)
        let dir = directory ?? Essence2Download.defaultDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let want, let hit = try? cached(want, in: dir) { return hit }
        let (tmp, fileResp) = try await URLSession.shared.download(from: url)
        guard (fileResp as? HTTPURLResponse)?.statusCode == 200 else {
            throw Essence2KitError.resourcesUnavailable("\(agentCode): the avatar file download failed (HTTP \((fileResp as? HTTPURLResponse)?.statusCode ?? -1))")
        }
        let got = try Essence2Resources.sha256(of: tmp)
        if let want, got != want {
            try? FileManager.default.removeItem(at: tmp)
            throw Essence2KitError.resourcesUnavailable("\(agentCode): the \(isSlice ? "apple slice" : "avatar file") is sha256 \(got), not the door's \(want); refused")
        }
        let dst = dir.appendingPathComponent(got + ".imx")
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.moveItem(at: tmp, to: dst)
        return dst
    }

    /// Where downloads are kept when no directory is given: Caches/bitHuman/essence2/avatars.
    public static var defaultDirectory: URL {
        let root = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent("bitHuman/essence2/avatars", isDirectory: true)
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
    public static let releaseTag = "essence2-v1.13.0"
    static let base = "https://github.com/bithuman-product/homebrew-bithuman/releases/download/"
    static let files: [(name: String, sha256: String)] = [
        ("w2v_ess_fp16_v1.onnx", "7340a0350c340e059f0931d7381fad1ed8aa579cc4440fcc3223f136d9aaa8e5"),
        ("audio_encoder_fp16_window_trunk.onnx", "8cfc2a558236dcb787b46322c906e562e0cb1abe65a8f15f95f50d7cb8c86e88"),
        ("audio_encoder_fp16_window_head.onnx", "30b67891439db75b48a7a0469152e62b339298664c3aa72d5ab7426971940241"),
    ]

    /// Where fetched resources live.
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
}
