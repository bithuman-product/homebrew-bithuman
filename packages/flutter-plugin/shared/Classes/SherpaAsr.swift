// On-device speech-to-text for the hybrid brain on Apple when the app ships a sherpa-onnx model
// (`localAudioStart(sttDir:)`): a Silero VAD decides where the user's turn ends and an offline
// recognizer transcribes the whole turn (NeMo Parakeet TDT transducer, or Moonshine).
//
// Why not only Apple SpeechAnalyzer (SpeechPipeline.swift, the default)? Measured on the iPhone 18 Pro
// (2026-10-04, 12 prerecorded utterances, 10 accented adults + 2 children): SpeechAnalyzer's own
// end-of-turn commits a median 1.33 s after the user stops (0.42-1.81 s; >2.2 s for some turns once a
// mic-like noise floor is added), and forcing it to finalize on a VAD edge drops words. Silero (0.5 s
// of silence) + Parakeet TDT 110M commits in a median ~0.6 s at the same word error rate (20 % vs
// 20.8 %). It costs a 136 MB download; SpeechAnalyzer costs nothing.
//
// Compiles only when the podspec staged the sherpa-onnx static library (SHERPA_ASR_AVAILABLE),
// built against the SAME onnxruntime the pod vendors (scripts/build-sherpa-ios.sh).
#if SHERPA_ASR_AVAILABLE
@preconcurrency import AVFoundation
import Foundation

final class SherpaAsr: AsrPipeline, @unchecked Sendable {
  let events: AsyncStream<SpeechEvent>
  /// "parakeet" | "moonshine": what `dir` held.
  let kind: String
  /// Harness timing probes: {"ev": "vad_start" | "vad_final", ...}. The ASR queue.
  var onMetric: (([String: Any]) -> Void)?
  private let cont: AsyncStream<SpeechEvent>.Continuation
  private var rec: OpaquePointer?
  private var vad: OpaquePointer?
  private var cstrs: [UnsafeMutablePointer<CChar>] = []
  private let q = DispatchQueue(label: "ai.bithuman.sherpa-asr", qos: .userInitiated)
  private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1,
                                     interleaved: false)!
  private var converter: AVAudioConverter?
  private var converterSrc: AVAudioFormat?
  // All on `q`:
  private var window: [Float] = []        // < 512 samples waiting for the VAD
  private var ring: [Float] = []          // the recent input, for the turn's pre-roll
  private var ringStart = 0               // absolute sample index of ring[0]
  private var fed = 0                     // absolute samples handed to the VAD
  private var speaking = false
  private var stopped = false
  private static let preRoll = 4800       // 0.3 s before the VAD's speech start
  private static let ringCap = 16000 * 30

  /// `dir` holds the recognizer files + `silero_vad.onnx`. `minSilence`: the pause that ends a turn.
  init(dir: String, minSilence: Float = 0.5, threads: Int32 = 2) throws {
    (events, cont) = AsyncStream<SpeechEvent>.makeStream()
    let fm = FileManager.default
    func has(_ n: String) -> Bool { fm.fileExists(atPath: dir + "/" + n) }
    let parakeet = has("encoder.int8.onnx") && has("joiner.int8.onnx")
    let moonshine = has("encoder_model.ort") && has("decoder_model_merged.ort")
    guard parakeet || moonshine else {
      throw NSError(domain: "ai.bithuman.asr", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "no speech-to-text model in \(dir)"])
    }
    kind = parakeet ? "parakeet" : "moonshine"
    func p(_ n: String) -> UnsafePointer<CChar> {
      let s = strdup(dir + "/" + n)!
      cstrs.append(s)
      return UnsafePointer(s)
    }
    func lit(_ v: String) -> UnsafePointer<CChar> { let s = strdup(v)!; cstrs.append(s); return UnsafePointer(s) }
    var c = SherpaOnnxOfflineRecognizerConfig()
    c.feat_config.sample_rate = 16000
    c.feat_config.feature_dim = 80
    c.model_config.num_threads = threads
    c.model_config.provider = lit("cpu")
    c.decoding_method = lit("greedy_search")
    c.model_config.tokens = p("tokens.txt")
    if parakeet {
      c.model_config.transducer.encoder = p("encoder.int8.onnx")
      c.model_config.transducer.decoder = p("decoder.int8.onnx")
      c.model_config.transducer.joiner = p("joiner.int8.onnx")
      c.model_config.model_type = lit("nemo_transducer")
    } else {
      c.model_config.moonshine.encoder = p("encoder_model.ort")
      c.model_config.moonshine.merged_decoder = p("decoder_model_merged.ort")
    }
    guard has("silero_vad.onnx") else {
      throw NSError(domain: "ai.bithuman.asr", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "no silero_vad.onnx in \(dir)"])
    }
    let t0 = Date()
    rec = SherpaOnnxCreateOfflineRecognizer(&c)
    var v = SherpaOnnxVadModelConfig()
    v.silero_vad.model = p("silero_vad.onnx")
    v.silero_vad.threshold = 0.5
    v.silero_vad.min_silence_duration = minSilence
    v.silero_vad.min_speech_duration = 0.25
    v.silero_vad.window_size = 512
    v.silero_vad.max_speech_duration = 20
    v.sample_rate = 16000
    v.num_threads = 1
    v.provider = lit("cpu")
    vad = SherpaOnnxCreateVoiceActivityDetector(&v, 30)
    guard rec != nil, vad != nil else {
      throw NSError(domain: "ai.bithuman.asr", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "the \(kind) recognizer did not load from \(dir)"])
    }
    NSLog("[bhasr] ready model=%@ minSilence=%.2f loadMs=%d", kind, minSilence, Int(Date().timeIntervalSince(t0) * 1000))
  }

  deinit {
    if let vad { SherpaOnnxDestroyVoiceActivityDetector(vad) }
    if let rec { SherpaOnnxDestroyOfflineRecognizer(rec) }
    cstrs.forEach { free($0) }
  }

  func push(_ buffer: AVAudioPCMBuffer) async {
    guard let mono = convert(buffer), let ch = mono.floatChannelData else { return }
    let x = Array(UnsafeBufferPointer(start: ch[0], count: Int(mono.frameLength)))
    q.async { [weak self] in self?.consume(x) }
  }

  func stop() async {
    q.sync { stopped = true }
    cont.finish()
  }

  // MARK: - on `q`

  private func consume(_ x: [Float]) {
    if stopped { return }
    ring += x
    if ring.count > Self.ringCap + 80000 { let drop = ring.count - Self.ringCap; ring.removeFirst(drop); ringStart += drop }
    window += x
    while window.count >= 512 {
      let w = Array(window.prefix(512))
      window.removeFirst(512)
      w.withUnsafeBufferPointer { SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, $0.baseAddress, 512) }
      fed += 512
      let now = SherpaOnnxVoiceActivityDetectorDetected(vad) != 0
      if now && !speaking {
        NSLog("[bhasr] speech_start hostMs=%lld", Self.ms())
        onMetric?(["ev": "vad_start", "atSample": fed])
        cont.yield(.partial("…"))   // the turn has started (no words before the VAD closes it)
      }
      speaking = now
      while SherpaOnnxVoiceActivityDetectorEmpty(vad) == 0 {
        guard let seg = SherpaOnnxVoiceActivityDetectorFront(vad) else { break }
        let start = Int(seg.pointee.start), n = Int(seg.pointee.n)
        SherpaOnnxDestroySpeechSegment(seg)
        SherpaOnnxVoiceActivityDetectorPop(vad)
        decode(from: start - Self.preRoll, to: start + n + 1600)
      }
    }
  }

  /// Decode [from, to) (absolute sample indices, clamped to what the ring still holds).
  private func decode(from: Int, to: Int) {
    let a = max(from, ringStart) - ringStart, b = min(to, ringStart + ring.count) - ringStart
    guard b > a else { return }
    let t0 = Date()
    let s = SherpaOnnxCreateOfflineStream(rec)
    ring[a..<b].withContiguousStorageIfAvailable { SherpaOnnxAcceptWaveformOffline(s, 16000, $0.baseAddress, Int32(b - a)) }
    SherpaOnnxDecodeOfflineStream(rec, s)
    var text = ""
    if let r = SherpaOnnxGetOfflineStreamResult(s) {
      if let t = r.pointee.text { text = String(cString: t).trimmingCharacters(in: .whitespacesAndNewlines) }
      SherpaOnnxDestroyOfflineRecognizerResult(r)
    }
    SherpaOnnxDestroyOfflineStream(s)
    let decodeMs = Int(Date().timeIntervalSince(t0) * 1000)
    NSLog("[bhasr] final segMs=%d decodeMs=%d hostMs=%lld '%@'", (b - a) / 16, decodeMs, Self.ms(), text)
    onMetric?(["ev": "vad_final", "segMs": (b - a) / 16, "decodeMs": decodeMs, "closedAtSample": fed])
    // Always yield, even empty: the final closes the segment the partial opened.
    cont.yield(.final(text))
  }

  private static func ms() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

  /// Any mic / injected buffer → 16 kHz mono float (channel 0: the AEC'd mic on VP-IO).
  private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    let src = buffer.format
    if src.sampleRate == 16000, src.channelCount == 1, src.commonFormat == .pcmFormatFloat32 { return buffer }
    if converter == nil || converterSrc != src {
      let c = AVAudioConverter(from: src, to: target)
      if src.channelCount > 1 { c?.channelMap = [0] }
      converter = c; converterSrc = src
    }
    guard let converter else { return nil }
    let cap = AVAudioFrameCount(Double(buffer.frameLength) * 16000 / src.sampleRate + 64)
    guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return nil }
    var given = false
    let st = converter.convert(to: out, error: nil) { _, s in
      if given { s.pointee = .noDataNow; return nil }
      given = true; s.pointee = .haveData; return buffer
    }
    return st == .error ? nil : out
  }
}
#endif  // SHERPA_ASR_AVAILABLE
