// Apple system voices for the on-device brain (LOCAL mode): the "system voice"
// option. The brain (libconverse) still decides WHAT is spoken and WHEN; this
// renders each text chunk with AVSpeechSynthesizer and hands the PCM back, so a
// user who has a Premium or Enhanced voice needs no voice-model download.
//
// Facts this is built on (measured 2026-09-28, M4 Mac, macOS 26.6):
//  • Siri voices are NOT offered to apps: AVSpeechSynthesisVoice.speechVoices()
//    lists 0 of them. Apps get the voices the user downloaded in Settings →
//    Accessibility → Spoken Content → Voices (Premium, Enhanced) plus the compact
//    defaults. No API downloads a voice; only the user can, in Settings.
//  • write(_:toBufferCallback:) renders ~40-80x faster than real time (first
//    buffer 20-50 ms, a whole sentence 35-90 ms) as 22.05 kHz mono Float32.
//  • Its buffers arrive ONLY on the main queue — with the main thread blocked
//    nothing arrives. The renderer therefore never waits on the main thread and
//    is cancelled BEFORE the brain is torn down (see ConverseSession.stop()).
#if os(macOS) || os(iOS)
@preconcurrency import AVFoundation
import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The installed Apple voices, and which one the "system" setting picks.
enum SystemVoiceCatalog {
    /// `voice` values that select the system voice: "system" (the best installed
    /// Premium / Enhanced voice) or "system:<AVSpeechSynthesisVoice identifier>".
    static let prefix = "system"

    static func isSystemVoice(_ voice: String) -> Bool {
        voice == prefix || voice.hasPrefix(prefix + ":")
    }

    static func qualityName(_ q: AVSpeechSynthesisVoiceQuality) -> String {
        switch q {
        case .premium: return "premium"
        case .enhanced: return "enhanced"
        default: return "default"
        }
    }

    private static func rank(_ v: AVSpeechSynthesisVoice) -> Int {
        switch v.quality {
        case .premium: return 3
        case .enhanced: return 2
        default: return 1
        }
    }

    private static func isNovelty(_ v: AVSpeechSynthesisVoice) -> Bool {
        if #available(macOS 14.0, iOS 17.0, *) { return v.voiceTraits.contains(.isNoveltyVoice) }
        return false
    }

    private static func isPersonal(_ v: AVSpeechSynthesisVoice) -> Bool {
        if #available(macOS 14.0, iOS 17.0, *) { return v.voiceTraits.contains(.isPersonalVoice) }
        return false
    }

    /// Installed voices whose language starts with `language` ("en", "en-GB"),
    /// best first: Premium, Enhanced, then the rest; the device's own locale
    /// (en-US vs en-GB …) first within a tier. Novelty voices (Bells, Bubbles …)
    /// are left out. Personal Voices appear once the user has allowed access.
    static func voices(language: String = "en") -> [AVSpeechSynthesisVoice] {
        let here = AVSpeechSynthesisVoice.currentLanguageCode()
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(language) && !isNovelty($0) }
            .sorted { a, b in
                if rank(a) != rank(b) { return rank(a) > rank(b) }
                let ah = a.language == here, bh = b.language == here
                if ah != bh { return ah }
                return a.name < b.name
            }
    }

    /// One voice as the Dart side sees it.
    static func describe(_ v: AVSpeechSynthesisVoice) -> [String: Any] {
        let gender: String
        switch v.gender {
        case .male: gender = "male"
        case .female: gender = "female"
        default: gender = "unspecified"
        }
        return ["id": v.identifier, "name": v.name, "language": v.language,
                "quality": qualityName(v.quality), "gender": gender, "personal": isPersonal(v)]
    }

    /// What "system" picks: the best Premium, else Enhanced, voice for the
    /// language. nil when only the compact default voices are installed — the
    /// caller then uses the built-in (downloaded) voice instead. A Personal Voice
    /// is never picked automatically; select it by id.
    static func best(language: String = "en") -> AVSpeechSynthesisVoice? {
        voices(language: language).first { rank($0) >= 2 && !isPersonal($0) }
    }

    /// The voice a `voice` value asks for. "system:<id>" = that voice when it is
    /// still installed (any quality: an explicit choice is honoured), else the
    /// best one, like "system".
    static func resolve(_ voice: String, language: String = "en") -> AVSpeechSynthesisVoice? {
        if voice.hasPrefix(prefix + ":") {
            let id = String(voice.dropFirst(prefix.count + 1))
            if let v = AVSpeechSynthesisVoice(identifier: id) { return v }
            NSLog("[SystemVoice] %@ is not installed; using the best installed voice", id)
        }
        return best(language: language)
    }

    // ── Personal Voice ───────────────────────────────────────────────────────
    /// "authorized" | "denied" | "notDetermined" | "unsupported".
    static func personalVoiceStatus() -> String {
        if #available(macOS 14.0, iOS 17.0, *) {
            return statusName(AVSpeechSynthesizer.personalVoiceAuthorizationStatus)
        }
        return "unsupported"
    }

    /// Ask the user (a system prompt, once) to let this app use their Personal
    /// Voice. Personal Voices then show up in `voices()` with personal = true.
    static func requestPersonalVoice(_ done: @escaping (String) -> Void) {
        if #available(macOS 14.0, iOS 17.0, *) {
            AVSpeechSynthesizer.requestPersonalVoiceAuthorization { st in
                DispatchQueue.main.async { done(statusName(st)) }
            }
        } else {
            done("unsupported")
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private static func statusName(_ s: AVSpeechSynthesizer.PersonalVoiceAuthorizationStatus) -> String {
        switch s {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .unsupported: return "unsupported"
        case .notDetermined: return "notDetermined"
        @unknown default: return "notDetermined"
        }
    }

    // ── Getting a better voice ───────────────────────────────────────────────
    /// Where the user downloads a Premium / Enhanced voice. There is no API that
    /// downloads one for them.
    static var downloadSteps: String {
        #if os(iOS)
        return "Open Settings → Accessibility → Spoken Content (Read & Speak on newer iOS) → Voices → "
             + "English, pick a voice and download its Premium or Enhanced version. "
             + "Then come back here and choose it."
        #else
        return "Open System Settings → Accessibility → Spoken Content, click the info button next to "
             + "System voice (or choose Manage Voices…), and download a Premium or Enhanced English voice. "
             + "Then come back here and choose it."
        #endif
    }

    /// Opens the closest settings page the platform allows. macOS: Accessibility
    /// → Spoken Content. iOS has no public link into Accessibility settings (the
    /// `App-prefs:` URLs are private and get apps rejected), so this opens the
    /// Settings app at this app's page and the caller shows `downloadSteps`.
    /// Returns whether a page was opened.
    static func openVoiceSettings(_ done: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            #if os(iOS)
            guard let url = URL(string: UIApplication.openSettingsURLString) else { done(false); return }
            UIApplication.shared.open(url, options: [:]) { done($0) }
            #else
            let urls = ["x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent",
                        "x-apple.systempreferences:com.apple.Accessibility-Settings.extension"]
            for s in urls {
                if let url = URL(string: s), NSWorkspace.shared.open(url) { done(true); return }
            }
            done(false)
            #endif
        }
    }
}

/// Renders the brain's text chunks with AVSpeechSynthesizer.write — PCM only,
/// never the speaker — as 24 kHz mono Float32 (BC_OUTPUT_SAMPLE_RATE). The PCM
/// goes back into the brain's output ring, so the speaker and the avatar's
/// lip-sync take the SAME bytes, exactly as with the built-in voice.
final class SystemVoiceRenderer: @unchecked Sendable {
    let voice: AVSpeechSynthesisVoice
    private let synth = AVSpeechSynthesizer()
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000,
                                       channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var cancelled = false
    /// A chunk that has not finished after this long is given up (a stuck
    /// synthesizer must not hang the brain's TTS thread).
    private static let chunkTimeout: TimeInterval = 8

    init(voice: AVSpeechSynthesisVoice) {
        self.voice = voice
        #if os(iOS)
        // write() renders to a callback; it must never reconfigure or activate the
        // app's audio session, which the VP-IO mic + speaker own.
        synth.usesApplicationAudioSession = false
        #endif
    }

    var info: [String: Any] { SystemVoiceCatalog.describe(voice) }

    /// Load the voice now (a Premium voice's first use costs ~0.5 s on an M4) so
    /// the greeting does not pay for it. Fire-and-forget; call off the main thread
    /// or from it — it never waits.
    func warm() {
        let u = AVSpeechUtterance(string: "Hi.")
        u.voice = voice
        DispatchQueue.main.async { self.synth.write(u) { _ in } }
    }

    /// Stop now and refuse further chunks: the brain's TTS thread returns at once
    /// instead of waiting for main-queue buffers. Call BEFORE tearing down the
    /// brain (bc_session_destroy waits for a chunk in flight).
    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        DispatchQueue.main.async { self.synth.stopSpeaking(at: .immediate) }
    }

    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// Render one chunk. Blocks the CALLING thread (the brain's TTS thread; never
    /// the main thread, where the synthesizer delivers). `emit` receives 24 kHz
    /// mono Float32 in order. Returns 0 when rendered or cancelled (a cancelled
    /// chunk is simply silent), 1 when the chunk failed (timeout / no audio).
    func render(_ text: String, emit: ([Float]) -> Void) -> Int32 {
        if Thread.isMainThread {   // would wait forever: the buffers need this thread
            NSLog("[SystemVoice] render called on the main thread; skipped")
            return 1
        }
        if isCancelled { return 0 }
        let u = AVSpeechUtterance(string: text)
        u.voice = voice
        let done = DispatchSemaphore(value: 0)
        let out = Collector(target: target)
        synth.write(u) { buf in
            guard let pcm = buf as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 { out.finish(); done.signal(); return }   // end of utterance
            out.add(pcm)
        }
        // Wait in short slices so a cancel (teardown / barge) is seen within 20 ms.
        let deadline = Date().addingTimeInterval(Self.chunkTimeout)
        while done.wait(timeout: .now() + 0.02) == .timedOut {
            if isCancelled { return 0 }
            if Date() > deadline {
                NSLog("[SystemVoice] chunk timed out after %.0f s; skipped", Self.chunkTimeout)
                DispatchQueue.main.async { self.synth.stopSpeaking(at: .immediate) }
                return 1
            }
        }
        let pcm = out.take()
        if pcm.isEmpty { return 1 }
        emit(pcm)
        return 0
    }

    /// Resamples one utterance's buffers (22.05 kHz from every voice measured) to
    /// 24 kHz. Buffers arrive on the main queue; `take()` runs after the last one.
    private final class Collector: @unchecked Sendable {
        let target: AVAudioFormat
        var conv: AVAudioConverter?
        var pcm: [Float] = []
        let lock = NSLock()
        init(target: AVAudioFormat) { self.target = target }

        func add(_ b: AVAudioPCMBuffer) {
            lock.lock(); defer { lock.unlock() }
            if conv == nil || conv!.inputFormat != b.format { conv = AVAudioConverter(from: b.format, to: target) }
            convert(b, end: false)
        }
        func finish() {
            lock.lock(); defer { lock.unlock() }
            convert(nil, end: true)   // drain the resampler's tail
        }
        func take() -> [Float] { lock.lock(); defer { lock.unlock() }; return pcm }

        private func convert(_ b: AVAudioPCMBuffer?, end: Bool) {
            guard let conv else { return }
            let frames = b.map { Double($0.frameLength) * target.sampleRate / $0.format.sampleRate } ?? 0
            let cap = AVAudioFrameCount(frames + 1024)
            var fed = false
            while true {
                guard let o = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
                var err: NSError?
                let st = conv.convert(to: o, error: &err) { _, status in
                    if let b, !fed { fed = true; status.pointee = .haveData; return b }
                    status.pointee = end ? .endOfStream : .noDataNow
                    return nil
                }
                if let p = o.floatChannelData, o.frameLength > 0 {
                    pcm.append(contentsOf: UnsafeBufferPointer(start: p[0], count: Int(o.frameLength)))
                }
                // A full output buffer may leave more behind; otherwise done.
                if st == .haveData && o.frameLength == o.frameCapacity { continue }
                return
            }
        }
    }
}
#endif
