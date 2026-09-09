// IOSExpression2 — a talking bitHuman avatar on a real iPhone, on-device.
//
// Engine:  expression-2, via the `Expression2` product of the SwiftPM package
//          https://github.com/bithuman-product/homebrew-bithuman.git
// Inputs:  Sources/Model/agent.avatar        your agent's <CODE>.avatar
//          Sources/Model/shared_engine/      from `bithuman engine install mac`
//          Sources/Model/speech16k.wav       16 kHz mono PCM speech
// Output:  25 FPS lip-synced frames, drawn in SwiftUI, in sync with the audio.
//
// Nothing here is bitHuman-internal: every call is public API of the shipped
// binary. See https://docs.bithuman.ai/examples/swift-ios-expression2

import SwiftUI
import AVFoundation
import Accelerate
import Expression2

/// Everything this app prints is prefixed, so you can filter the Xcode console
/// (or `xcrun devicectl device process launch --console`) down to just this app.
func log(_ line: String) {
    NSLog("[ios-expression2] %@", line)
    // The same lines are appended to Documents/session.log, so you can read them
    // off the phone without keeping a console attached:
    //   xcrun devicectl device copy from --device <udid> \
    //     --domain-type appDataContainer \
    //     --domain-identifier ai.bithuman.example.ios-expression2 \
    //     --source Documents/session.log --destination .
    guard let docs = FileManager.default.urls(for: .documentDirectory,
                                              in: .userDomainMask).first else { return }
    let entry = Data((ISO8601DateFormatter().string(from: Date()) + "  " + line + "\n").utf8)
    let p = docs.appendingPathComponent("session.log")
    if let h = try? FileHandle(forWritingTo: p) {
        h.seekToEndOfFile(); h.write(entry); try? h.close()
    } else {
        try? entry.write(to: p)
    }
}

// MARK: - 1. Where the three inputs live in the app bundle

enum Payload {
    static var root: URL? { Bundle.main.url(forResource: "Model", withExtension: nil) }
    static var avatarContainer: URL? { root?.appendingPathComponent("agent.avatar") }
    static var sharedEngineDir: URL? { root?.appendingPathComponent("shared_engine") }
    static var speechWAV: URL? { root?.appendingPathComponent("speech16k.wav") }
}

// MARK: - 2. A 16-bit PCM WAV reader (no AVFoundation decode needed)

func readPCM16MonoWAV(_ url: URL) -> [Float] {
    guard let d = try? Data(contentsOf: url), d.count > 44 else { return [] }
    var i = 12, off = -1, len = 0
    while i + 8 <= d.count {
        let id = String(bytes: d[i..<i+4], encoding: .ascii) ?? ""
        let sz = Int(d[i+4]) | Int(d[i+5]) << 8 | Int(d[i+6]) << 16 | Int(d[i+7]) << 24
        if id == "data" { off = i + 8; len = min(sz, d.count - off); break }
        if sz <= 0 { break }
        i += 8 + sz + (sz & 1)
    }
    guard off > 0, len > 1 else { return [] }
    var out = [Float](repeating: 0, count: len / 2)
    d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        let base = raw.baseAddress!.advanced(by: off)
        out.withUnsafeMutableBufferPointer { o in
            for k in 0..<(len / 2) {
                let lo = UInt16(base.load(fromByteOffset: k * 2, as: UInt8.self))
                let hi = UInt16(base.load(fromByteOffset: k * 2 + 1, as: UInt8.self))
                o[k] = Float(Int16(bitPattern: lo | (hi << 8))) / 32768.0
            }
        }
    }
    return out
}

// MARK: - 3. The engine lives inside an actor
//
// `Expression2Engine` is a plain class and is not Sendable. Keeping it inside an
// actor is what lets this compile under Swift 6 strict concurrency AND keeps the
// ~7 s first load off the main thread. Only Sendable values ([UInt8], Int, Bool)
// ever cross the boundary.

actor Renderer {
    private var engine: Expression2Engine?
    private(set) var width = 0
    private(set) var height = 0

    /// Stage the container's members to disk, then start the engine.
    ///
    /// Why by hand and not `create(avatarContainer:…:stagingDir:)`: through
    /// Expression2 2.11.2 the shipped unpacker refuses a published `.avatar` on
    /// iOS by member name. `Expression2Container.read` does not. See the doc page.
    func load(avatar: URL, sharedEngine: URL, staging: URL) throws -> String {
        let fm = FileManager.default
        let dir = staging.appendingPathComponent("avatar", isDirectory: true)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let members = try Expression2Container.members(of: avatar)
        for m in members {
            let dst = dir.appendingPathComponent(m.name)
            try fm.createDirectory(at: dst.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try Expression2Container.read(m.name, from: avatar).write(to: dst)
        }

        // Ask before you start, rather than catching a throw.
        let missing = Expression2Engine.missingMembers(avatarDir: dir,
                                                       sharedEngineDir: sharedEngine)
        guard missing.isEmpty else {
            throw NSError(domain: "IOSExpression2", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    "missing member(s): \(missing.joined(separator: ", "))"])
        }

        let e = try Expression2Engine.create(modelPath: dir, sharedEngineDir: sharedEngine)
        engine = e
        width = e.width
        height = e.height
        return "\(members.count) members staged · \(e.width)x\(e.height) · isReady=\(e.isReady)"
    }

    func idleFrame() -> [UInt8]? { engine?.idle }
    func feed(_ samples: [Float]) { engine?.feed(samples) }
    func flushTail() { engine?.flushTail() }
    func reset() { engine?.resetState(clearFrames: true) }

    /// Generation is ASYNCHRONOUS: `pull()` returns nil until a chunk of frames
    /// lands, so a bare `while let` right after `feed()` drains nothing. The
    /// engine buffers what it has produced, so you do not need a queue of your
    /// own — ask it for one frame per display tick and read `queuedFrames` to
    /// see how far ahead it is.
    func pullOne() -> [UInt8]? { engine?.pull()?.frame }
    func queued() -> Int { engine?.queuedFrames ?? 0 }
}

// MARK: - 4. BGR888 → CGImage. Two vImage passes and no intermediate copy, so
// this keeps up with 25 FPS even in a Debug build.

func makeCGImage(_ bgr: [UInt8], _ w: Int, _ h: Int) -> CGImage? {
    let n = w * h
    guard w > 0, h > 0, bgr.count >= n * 3 else { return nil }
    let bytes = n * 4
    guard let out = malloc(bytes) else { return nil }
    bgr.withUnsafeBufferPointer { sBuf in
        guard let s = sBuf.baseAddress else { return }
        var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: s),
                                height: vImagePixelCount(h), width: vImagePixelCount(w),
                                rowBytes: w * 3)
        var dst = vImage_Buffer(data: out, height: vImagePixelCount(h),
                                width: vImagePixelCount(w), rowBytes: w * 4)
        // BGR888 -> (255,B,G,R), then permute to (R,G,B,255).
        vImageConvert_RGB888toARGB8888(&src, nil, 255, &dst, false, vImage_Flags(kvImageNoFlags))
        var map: [UInt8] = [3, 2, 1, 0]
        vImagePermuteChannels_ARGB8888(&dst, &dst, &map, vImage_Flags(kvImageNoFlags))
    }
    guard let provider = CGDataProvider(dataInfo: out, data: out, size: bytes,
                                        releaseData: { info, _, _ in free(info) }) else {
        free(out); return nil
    }
    return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false,
                   intent: .defaultIntent)
}

// MARK: - 4b. The view we draw into
//
// ★ Do NOT push 25 FPS through an `@Published` property. Every assignment
// re-evaluates the SwiftUI body around it, and measured on an iPhone 15 that
// alone dropped playback from 25 FPS to 19.3. Hand the frame to a CALayer
// instead; SwiftUI never sees it change.

@MainActor
final class FrameSink {
    fileprivate weak var layer: CALayer?
    func show(_ cg: CGImage) { layer?.contents = cg }
}

struct FrameView: UIViewRepresentable {
    let sink: FrameSink
    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = UIColor(white: 0.12, alpha: 1)
        v.layer.contentsGravity = .resizeAspect
        v.layer.masksToBounds = true
        v.layer.cornerRadius = 16
        sink.layer = v.layer
        return v
    }
    func updateUIView(_ v: UIView, context: Context) { sink.layer = v.layer }
}

// MARK: - 5. The session: load, then speak (file) or listen (mic)

@MainActor
final class AvatarSession: ObservableObject {
    @Published var status = "loading the engine…"
    @Published var detail = ""
    let sink = FrameSink()
    @Published var hasFrame = false
    @Published var ready = false
    @Published var busy = false
    @Published var listening = false

    fileprivate let renderer = Renderer()
    private var player: AVAudioPlayer?
    private var micEngine: AVAudioEngine?
    private var w = 0, h = 0
    private var shown = 0
    private var firstFrameAt: Date?
    private var lastFrameAt: Date?
    private var feedDone = false
    private var displayTask: Task<Void, Never>?

    // 5a. Boot: stage the members and start the engine.
    func boot() async {
        guard let avatar = Payload.avatarContainer,
              let shared = Payload.sharedEngineDir,
              FileManager.default.fileExists(atPath: avatar.path) else {
            status = "No model in the bundle."
            detail = "Run ./setup.sh — see README.md."
            log("no Model/agent.avatar in the bundle — run ./setup.sh")
            return
        }
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("expression2-stage", isDirectory: true)
        let t0 = Date()
        do {
            let line = try await renderer.load(avatar: avatar, sharedEngine: shared, staging: staging)
            w = await renderer.width
            h = await renderer.height
            if let idle = await renderer.idleFrame(), let cg = makeCGImage(idle, w, h) {
                sink.show(cg); hasFrame = true
            }
            status = "Ready."
            detail = line + String(format: " · loaded in %.1f s", Date().timeIntervalSince(t0))
            log("engine ready: \(line) in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
            ready = true
            speak()          // say the bundled line once, so launching proves it
        } catch {
            status = "Engine did not start."
            detail = "\(error)"
            log("FAILED to start: \(error)")
        }
    }

    // 5b. Speak: generate the whole utterance, then play it in sync.
    //
    // ★ Why generate first rather than stream. Measured on an iPhone 15, this
    // engine delivers about 20 FPS of a 25 FPS stream — a little slower than
    // real time. Stream it and the mouth falls steadily further behind the
    // sound; generate it and the two are locked together. On faster silicon you
    // can stream (the microphone button below does), and the shape is the same:
    // feed, poll, draw.
    func speak() {
        guard ready, !busy, let wav = Payload.speechWAV else { return }
        let pcm = readPCM16MonoWAV(wav)
        guard !pcm.isEmpty else { status = "speech16k.wav is not 16-bit PCM."; return }
        let seconds = Double(pcm.count) / 16000.0
        log(String(format: "audio 16 kHz mono: %d samples, %.2f s", pcm.count, seconds))
        busy = true
        shown = 0
        status = "Generating…"

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        player = try? AVAudioPlayer(contentsOf: wav)

        Task {
            let t0 = Date()
            let chunk = 1600                       // 100 ms of 16 kHz mono
            var i = 0
            while i < pcm.count {
                let j = min(i + chunk, pcm.count)
                await renderer.feed(Array(pcm[i..<j]))
                i = j
            }
            await renderer.flushTail()

            // ★ Generation is ASYNCHRONOUS. `pull()` returns nil until a chunk of
            // frames lands, so a bare `while let` right after `feed()` collects
            // NOTHING: the app builds, starts, throws nothing and shows an empty
            // view. Poll until the engine has been quiet for a moment.
            var frames: [CGImage] = []
            var quiet = 0
            while quiet < 30 {                     // 30 x 50 ms of silence = done
                if let f = await renderer.pullOne() {
                    quiet = 0
                    if let cg = makeCGImage(f, w, h) { frames.append(cg) }
                } else {
                    quiet += 1
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
            let gen = Date().timeIntervalSince(t0)
            log(String(format: "generated %d frames at %dx%d in %.2f s (%.1f FPS, %.2fx real time)",
                       frames.count, w, h, gen,
                       Double(frames.count) / max(gen, 0.001), seconds / max(gen, 0.001)))
            guard !frames.isEmpty else {
                status = "The engine returned no frames."; busy = false; return
            }

            // Play the sound and step the frames on the same clock.
            status = "Speaking…"
            let start = Date()
            player?.play()
            for (n, cg) in frames.enumerated() {
                sink.show(cg)
                hasFrame = true
                shown += 1
                if shown == 1 { recordFirstFrame(cg) }
                let wait = start.addingTimeInterval(Double(n + 1) * 0.04).timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
            }
            let played = Date().timeIntervalSince(start)
            log(String(format: "played %d frames in %.2f s (%.1f FPS) beside %.2f s of audio",
                       shown, played, Double(shown) / max(played, 0.001), seconds))
            // The engine trims trailing silence, so the video can be a little
            // shorter than the sound. Hold the last frame until the audio ends
            // rather than cutting the speaker off mid-word.
            let remaining = seconds - played
            if remaining > 0 { try? await Task.sleep(nanoseconds: UInt64(remaining * 1e9)) }
            player?.stop()
            status = "Done — \(shown) frames at \(w)x\(h)."
            busy = false
            if let idle = await renderer.idleFrame(), let cg = makeCGImage(idle, w, h) { sink.show(cg) }
        }
    }

    // 5c. Listen: drive the avatar from the microphone, live.
    func toggleMic() {
        if listening { stopMic(); return }
        guard ready, !busy else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default,
                                 options: [.defaultToSpeaker, .allowBluetooth])
        try? session.setActive(true)
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                guard granted else { self.status = "Microphone permission denied."; return }
                self.startMic()
            }
        }
    }

    private func startMic() {
        let ae = AVAudioEngine()
        let input = ae.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: target) else {
            status = "Cannot open the microphone."; return
        }
        let renderer = self.renderer
        input.installTap(onBus: 0, bufferSize: 1600, format: inFormat) { buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength)
                                             * 16_000.0 / inFormat.sampleRate + 64)
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)
            else { return }
            var err: NSError?
            var fed = false
            converter.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return buffer
            }
            guard err == nil, out.frameLength > 0, let ch = out.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
            Task { await renderer.feed(samples) }
        }
        do { try ae.start() } catch { status = "Microphone failed: \(error)"; return }
        micEngine = ae
        listening = true
        shown = 0
        status = "Listening — talk to it."
        startDisplayLoop()
    }

    private func stopMic() {
        micEngine?.inputNode.removeTap(onBus: 0)
        micEngine?.stop()
        micEngine = nil
        listening = false
        stopDisplayLoop()
        Task { await renderer.reset() }
        status = "Stopped — \(shown) frames at \(w)x\(h)."
    }

    // 5d. Display: pop one frame every 40 ms — 25 FPS, the engine's own rate.
    /// The streaming draw loop, used by the microphone button. It shows whatever
    /// the engine has produced, 25 times a second.
    private func startDisplayLoop() {
        displayTask?.cancel()
        displayTask = Task { [weak self] in
            // ★ An ABSOLUTE grid, not `sleep(0.04 - work)`. Task.sleep overshoots
            // a little every time, and subtracting the work from a fixed delay
            // lets that error accumulate — which is the video sliding behind the
            // audio in front of you.
            let start = Date()
            var n = 0
            while !Task.isCancelled {
                if let self, let f = await self.renderer.pullOne(),
                   let cg = makeCGImage(f, self.w, self.h) {
                    self.sink.show(cg)
                    self.hasFrame = true
                    self.shown += 1
                    self.lastFrameAt = Date()
                    if self.shown == 1 { self.recordFirstFrame(cg) }
                }
                n += 1
                let wait = start.addingTimeInterval(Double(n) * 0.04).timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
            }
        }
    }

    private func stopDisplayLoop() { displayTask?.cancel(); displayTask = nil }

    /// Save frame 1 so you can look at it off the phone:
    ///   xcrun devicectl device copy from --device <udid> \
    ///     --domain-type appDataContainer \
    ///     --domain-identifier ai.bithuman.example.ios-expression2 \
    ///     --source Documents/first-frame.png --destination .
    private func recordFirstFrame(_ cg: CGImage) {
        firstFrameAt = Date()
        guard let png = UIImage(cgImage: cg).pngData(),
              let docs = FileManager.default.urls(for: .documentDirectory,
                                                  in: .userDomainMask).first else { return }
        let p = docs.appendingPathComponent("first-frame.png")
        try? png.write(to: p)
        log("first frame \(w)x\(h) written to Documents/first-frame.png (\(png.count) B)")
    }
}

// MARK: - 6. UI

@main
struct IOSExpression2App: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

struct ContentView: View {
    @StateObject private var session = AvatarSession()

    var body: some View {
        VStack(spacing: 14) {
            Text("bitHuman · expression-2 on-device").font(.headline)

            ZStack {
                FrameView(sink: session.sink)
                if !session.hasFrame { ProgressView().tint(.white) }
            }
            .frame(maxHeight: 520)

            HStack(spacing: 12) {
                Button(session.busy ? "Speaking…" : "Speak") { session.speak() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!session.ready || session.busy || session.listening)
                Button(session.listening ? "Stop mic" : "Talk to it") { session.toggleMic() }
                    .buttonStyle(.bordered)
                    .disabled(!session.ready || session.busy)
            }

            Text(session.status).font(.subheadline)
            Text(session.detail).font(.caption2).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .task { await session.boot() }
    }
}
