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
//   while let f = engine.pull() { show(f.frame, engine.width, engine.height) }   // B, G, R bytes
//   engine.interrupt()                        // barge-in: rides on the current frame
//   engine.shutdown()
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
        if let s, !s.isEmpty {
            _ = s.withCString { be_essence2_set_api_secret($0) }
        } else {
            _ = be_essence2_set_api_secret(nil)
        }
    }
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

    private let handle: be_essence2_handle
    private let lock = NSLock()
    private var buffer: [UInt8]
    private var lastSpeech: Int32
    private var closed = false

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
    /// nil when none is ready.
    /// Returns nil while metering refuses — `meteringRefusal` then carries the engine's sentence.
    public func pull() -> (frame: [UInt8], speech: Bool)? {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return nil }
        drainPending()
        guard be_essence2_frames_available(handle) > 0 else { return nil }
        fitBuffer()
        let n = buffer.withUnsafeMutableBufferPointer { be_essence2_pull_frame(handle, $0.baseAddress, Int32($0.count)) }
        if n == -3 { refusedNow = true; return nil }
        guard n > 0 else { return nil }
        refusedNow = false
        let sc = be_essence2_pulled_speech_frames(handle)
        let speech = sc > lastSpeech
        lastSpeech = sc
        return (Array(buffer.prefix(Int(n))), speech)
    }

    /// The next idle frame into `out` (B, G, R). Returns bytes written; 0 means keep showing the
    /// frame you have (it never means "show something else").
    public func idle(into out: inout [UInt8]) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return 0 }
        let n = out.withUnsafeMutableBufferPointer { be_essence2_idle_frame(handle, $0.baseAddress, Int32($0.count)) }
        if n == -3 { refusedNow = true } else if n > 0 { refusedNow = false }
        return max(0, Int(n))
    }

    /// Barge-in: drop queued audio and frames; the video rides on from the current frame.
    public func interrupt() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        pending.removeAll(); pendingOffset = 0
        be_essence2_reset(handle)
        lastSpeech = be_essence2_pulled_speech_frames(handle)
    }

    /// End the session: the final billing beat is flushed, then the engine is released.
    public func shutdown() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        lock.unlock()
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

// MARK: - Runtime resources

/// The engine's runtime resources — the audio frontend and its short-window pair — fetched once
/// from the GitHub release this package pins, and checked against sha256 values pinned HERE,
/// never against a checksum served beside the file.
public enum Essence2Resources {
    /// Must equal `essence2Tag` in Package.swift (the tap's check-apple-engine-pin.sh grades it).
    public static let releaseTag = "essence2-v1.12.0"
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
