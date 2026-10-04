// DEV / harness only (`localAudioStart(injectAudio: true)` + `localInjectAudio`): stands in for the
// microphone of a LOCAL / hybrid session, so the on-device speech-to-text, the VAD barge and every
// latency after them are measured on PRERECORDED speech — muted, no speaker-to-mic cross-talk, the
// same words every run. It hands the speech-to-text 16 kHz mono buffers of 20 ms in real time (a
// file of 4 s takes 4 s), under a noise floor (a microphone never delivers digital silence, and
// Apple's recogniser behaves differently on it), and reports the moment the stream passes the
// words' start and end (`inject_speech_start` / `inject_speech_end`): the reference every latency
// of the harness is measured from.
#if CONVERSE_AVAILABLE
@preconcurrency import AVFoundation
import Foundation

final class AudioInjector: @unchecked Sendable {
    /// {"ev": "inject_start" | "inject_speech_start" | "inject_speech_end" | "inject_done", "tag": ...}
    var onMark: (([String: Any]) -> Void)?

    private static let rate = 16000
    private static let chunk = 320   // 20 ms
    private let q = DispatchQueue(label: "ai.bithuman.inject", qos: .userInteractive)
    private let timer: DispatchSourceTimer
    private let emit: (AVAudioPCMBuffer) -> Void
    private let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(AudioInjector.rate),
                                    channels: 1, interleaved: false)!
    private struct Item { let s: [Float]; let tag: String; let start: Int; let end: Int }
    // All on `q`:
    private var items: [Item] = []
    private var pos = 0
    private var startedAt: CFTimeInterval = 0
    private var fed = 0
    private var seed: UInt32 = 0x9E3779B9
    private let noiseAmp: Float

    /// [noiseDb]: RMS of the (uniform) noise floor in dBFS; nil = digital silence.
    init(noiseDb: Double?, emit: @escaping (AVAudioPCMBuffer) -> Void) {
        self.emit = emit
        // Uniform noise on [-a, a] has an RMS of a / sqrt(3).
        noiseAmp = noiseDb.map { Float(pow(10, $0 / 20) * 3.0.squareRoot()) } ?? 0
        timer = DispatchSource.makeTimerSource(queue: q)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
    }

    /// Queue a file's samples (16 kHz mono). [speechStart] / [speechEnd] in seconds.
    func enqueue(_ samples: [Float], tag: String, speechStart: Double, speechEnd: Double) {
        let a = max(0, Int(speechStart * Double(Self.rate)))
        let b = max(a, min(samples.count, Int(speechEnd * Double(Self.rate))))
        q.async { self.items.append(Item(s: samples, tag: tag, start: a, end: b)) }
    }

    func stop() { timer.cancel() }

    private func tick() {
        let now = CACurrentMediaTime()
        if startedAt == 0 { startedAt = now }
        let due = Int((now - startedAt) * Double(Self.rate))
        while fed + Self.chunk <= due {
            feedChunk()
            fed += Self.chunk
        }
    }

    private func noise() -> Float {
        guard noiseAmp > 0 else { return 0 }
        seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
        return (Float(seed) / Float(UInt32.max) * 2 - 1) * noiseAmp
    }

    private func feedChunk() {
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(Self.chunk)),
              let p = buf.floatChannelData?[0] else { return }
        buf.frameLength = AVAudioFrameCount(Self.chunk)
        var marks: [[String: Any]] = []
        for i in 0..<Self.chunk {
            var x = noise()
            if let it = items.first {
                if pos == 0 { marks.append(["ev": "inject_start", "tag": it.tag]) }
                if pos == it.start { marks.append(["ev": "inject_speech_start", "tag": it.tag]) }
                if pos == it.end { marks.append(["ev": "inject_speech_end", "tag": it.tag]) }
                x += it.s[pos]
                pos += 1
                if pos >= it.s.count {
                    if it.end >= it.s.count { marks.append(["ev": "inject_speech_end", "tag": it.tag]) }
                    marks.append(["ev": "inject_done", "tag": it.tag])
                    items.removeFirst()
                    pos = 0
                }
            }
            p[i] = x
        }
        emit(buf)
        if !marks.isEmpty, let cb = onMark {
            let ms = Int64(Date().timeIntervalSince1970 * 1000)
            for var m in marks { m["hostMs"] = ms; cb(m) }
        }
    }

    /// A 16 kHz mono WAV (or any file AVAudioFile reads at 16 kHz) as float samples.
    static func load16k(_ path: String) throws -> [Float] {
        let f = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let pf = f.processingFormat
        guard pf.sampleRate == Double(rate) else {
            throw NSError(domain: "ai.bithuman.inject", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "\(path): \(pf.sampleRate) Hz, need 16000"])
        }
        guard let b = AVAudioPCMBuffer(pcmFormat: pf, frameCapacity: AVAudioFrameCount(f.length)) else { return [] }
        try f.read(into: b)
        guard let ch = b.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(b.frameLength)))
    }
}
#endif  // CONVERSE_AVAILABLE
