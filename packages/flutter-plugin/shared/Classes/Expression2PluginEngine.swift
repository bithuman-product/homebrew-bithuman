// Expression2PluginEngine.swift — the Expression 2 engine as this plugin's BithumanEngine.
//
// Since 2.6.20 the plugin LINKS the published Expression2 binary (the same Expression2,
// BithumanEngineProtocol and UnifiedModelHeader xcframeworks the Swift package's `Expression2`
// product vends; scripts/bootstrap.sh fetches them sha256-checked) instead of compiling engine
// source. The binary's Expression2Engine conforms to the Swift package's BithumanEngine protocol;
// this pod drives engines through its own copy of that protocol (Protocol/BithumanEngine.swift),
// so this thin adapter forwards one to the other. It holds no logic of its own.
#if os(macOS) || os(iOS)
import Foundation
import CoreVideo
import Expression2

final class Expression2PluginEngine: BithumanEngine {
  static var id: EngineId { EngineId(canonical: "expression2", aliases: ["embody", "expression-2"]) }
  var capabilities: EngineCapabilities { .expression2 }

  let engine = Expression2Engine()

  var width: Int { engine.width }
  var height: Int { engine.height }
  func warmUp(warmSpeech: [Float]?) { engine.warmUp(warmSpeech: warmSpeech); warmed = true }
  var isReady: Bool { engine.isReady }
  /// warmUp has returned (it cannot throw: a refusal is a warm-up that ended without readiness).
  private var warmed = false
  /// MODEL_REJECTED (2.6.29): the warm-up returned without readiness and metering did not refuse
  /// — the identity's model files would not load (ModelRefusal.swift). nil before warmUp returns.
  var modelRefusal: BithumanModelRefusal? {
    BithumanModelRefusal.expression2(warmed: warmed, isReady: engine.isReady,
                                     meteringRefusal: engine.meteringRefusal, reason: nil)
  }
  func shutdown() { engine.shutdown() }
  var idle: [UInt8]? { engine.idle }
  func feed(_ samples: [Float]) { engine.feed(samples) }
  func pull() -> (frame: [UInt8], speech: Bool)? { engine.pull() }
  var queuedFrames: Int { engine.queuedFrames }
  func resetState(clearFrames: Bool) { engine.resetState(clearFrames: clearFrames) }
  func flushTail() { engine.flushTail() }
  var hasPendingTail: Bool { engine.hasPendingTail }
  func idle(into buffer: inout [UInt8]) -> Int { engine.idle(into: &buffer) }
  func idleNextPixelBuffer() -> CVPixelBuffer? { engine.idleNextPixelBuffer() }
  func benchSync(_ secs: Int) { engine.benchSync(secs) }
  /// The session's metering refusal, if any (Expression2Engine.meteringRefusal).
  var meteringRefusal: String? { engine.meteringRefusal }
}
#endif
