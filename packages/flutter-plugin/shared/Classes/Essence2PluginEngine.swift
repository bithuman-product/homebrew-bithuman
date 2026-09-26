// Essence2PluginEngine.swift — the Essence 2 engine as this plugin's BithumanEngine.
//
// A thin adapter over the engine's public C interface (be_essence2.h, the header the Swift
// package's `Essence2` product ships). scripts/bootstrap.sh stages the published libessence2.a
// per slice with that header; the podspec folds the header into this pod's umbrella module and
// sets ESSENCE2_AVAILABLE, so the be_essence2_* functions resolve in-module with no import.
// Frames are tightly packed height*width*3 bytes in B, G, R order: the texture's own format.
#if (os(macOS) || os(iOS)) && ESSENCE2_AVAILABLE
import Foundation

final class Essence2Engine: BithumanEngine {
  static var id: EngineId {
    EngineId(canonical: "essence2",
             aliases: ["elevate", "essence-2", "essence-2-light", "essence-2-mobile"])
  }
  var capabilities: EngineCapabilities { .essence2 }

  /// The avatar file (.imx) to open; set by the plugin before init. nil = idle only.
  static var activeAgentDir: String? = nil
  /// Accepted for the old call shape; the engine ignores it.
  static var motionDir: String? = nil

  private var handle: UnsafeMutableRawPointer?
  let width: Int
  let height: Int
  private let fallbackIdle: [UInt8]
  private var scratch: [UInt8]

  init() {
    var h: UnsafeMutableRawPointer? = nil
    if let path = Self.activeAgentDir {
      let rc = path.withCString { be_essence2_create($0, nil, 0, &h) }
      if rc != 0 { NSLog("[essence2] be_essence2_create failed rc=%d — idle only", rc); h = nil }
    }
    handle = h
    var w: Int32 = 0, ht: Int32 = 0
    if let hh = h { be_essence2_get_info(hh, &w, &ht) }
    let ww = w > 0 ? Int(w) : 1248, hh = ht > 0 ? Int(ht) : 704
    width = ww; height = hh
    fallbackIdle = [UInt8](repeating: 24, count: ww * hh * 3)
    scratch = [UInt8](repeating: 0, count: ww * hh * 3)
  }

  func warmUp(warmSpeech: [Float]?) {}   // the engine warms itself inside be_essence2_create

  var isReady: Bool { handle.map { be_essence2_is_ready($0) != 0 } ?? false }

  var idle: [UInt8]? {
    guard let h = handle else { return fallbackIdle }
    let n = scratch.withUnsafeMutableBufferPointer { be_essence2_idle_frame(h, $0.baseAddress, Int32($0.count)) }
    return n > 0 ? Array(scratch.prefix(Int(n))) : fallbackIdle
  }

  func feed(_ samples: [Float]) { pushAudio(samples) }

  func pushAudio(_ samples: [Float]) {
    guard let h = handle, !samples.isEmpty else { return }
    var i16 = [Int16](repeating: 0, count: samples.count)
    for k in 0..<samples.count { i16[k] = Int16(max(-32768, min(32767, samples[k] * 32768))) }
    _ = i16.withUnsafeBufferPointer { be_essence2_push_audio(h, $0.baseAddress, Int32($0.count)) }
  }

  var framesAvailable: Int { handle.map { Int(be_essence2_frames_available($0)) } ?? 0 }

  /// `speech` is true for a frame driven by pushed audio (the engine's speech counter advanced).
  func pull(into buf: inout [UInt8]) -> (bytes: Int, speech: Bool) {
    guard let h = handle else { return (0, false) }
    let before = be_essence2_pulled_speech_frames(h)
    let n = buf.withUnsafeMutableBufferPointer { be_essence2_pull_frame(h, $0.baseAddress, Int32($0.count)) }
    guard n > 0 else { return (0, false) }
    return (Int(n), be_essence2_pulled_speech_frames(h) > before)
  }

  /// 0 means keep showing the frame you have.
  func idle(into buf: inout [UInt8]) -> Int {
    guard let h = handle else { return 0 }
    return Int(buf.withUnsafeMutableBufferPointer { be_essence2_idle_frame(h, $0.baseAddress, Int32($0.count)) })
  }

  func pull() -> (frame: [UInt8], speech: Bool)? {
    guard let h = handle, be_essence2_frames_available(h) > 0 else { return nil }
    let r = pull(into: &scratch)
    return r.bytes > 0 ? (Array(scratch.prefix(r.bytes)), r.speech) : nil
  }

  var queuedFrames: Int { framesAvailable }
  /// The engine keeps only a few frames ready; enter speech as soon as one exists.
  var speechCushion: Int { 1 }
  func resetState(clearFrames: Bool) { if let h = handle { be_essence2_reset(h) } }
  /// The reply's audio is complete: the engine ends the reply now (essence2-v1.14.0+).
  func flushTail() { if let h = handle { _ = be_essence2_end_utterance(h) } }
  var hasPendingTail: Bool { false }

  /// Release the engine; the last usage report is flushed, then its GPU work drains.
  func shutdown() {
    guard let h = handle else { return }
    handle = nil
    be_essence2_destroy(h)
    _ = be_essence2_quiesce_all(10_000)
  }
}
#endif
