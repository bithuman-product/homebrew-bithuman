import XCTest
@testable import BithumanEngineProtocol

final class BithumanEngineProtocolTests: XCTestCase {
    func testEngineIdDualAccept() {
        let id = EngineId(canonical: "essence2", aliases: ["elevate"])
        XCTAssertTrue(id.matches("essence2"))
        XCTAssertTrue(id.matches("elevate"))
        XCTAssertFalse(id.matches("embody"))
    }

    // The cloud-API names must route to the SAME on-device engine as the frozen
    // on-device slugs (multi-accept), so a slug arriving in the cloud taxonomy
    // resolves locally without disturbing the frozen `embody` / `elevate` slugs.
    func testEngineIdCloudApiNames() {
        let expr = EngineId(canonical: "expression2", aliases: ["embody", "expression-2"])
        XCTAssertTrue(expr.matches("expression2"))   // canonical
        XCTAssertTrue(expr.matches("embody"))        // frozen on-device alias
        XCTAssertTrue(expr.matches("expression-2"))  // cloud-API name
        XCTAssertFalse(expr.matches("elevate"))

        let ess = EngineId(canonical: "essence2",
                           aliases: ["elevate", "essence-2", "essence-2-light", "essence-2-mobile"])
        XCTAssertTrue(ess.matches("essence2"))        // canonical
        XCTAssertTrue(ess.matches("elevate"))         // frozen on-device alias
        XCTAssertTrue(ess.matches("essence-2"))       // COMBINED creation name (2026-07-02)
        XCTAssertTrue(ess.matches("essence-2-light")) // cloud light tier (on-device leg)
        XCTAssertTrue(ess.matches("essence-2-mobile"))// cloud App-Store name
        // The GPU-only premium tier is NOT served on-device by essence2 —
        // under its legacy `essence-2-quality` name OR its canonical
        // `essence-2-max` name (2026-07-10 rename; both accepted).
        XCTAssertFalse(ess.matches("essence-2-quality"))
        XCTAssertFalse(ess.matches("essence-2-max"))
    }

    // The GPU-only premium tier is a recognised cloud tier with NO on-device
    // engine — under BOTH its canonical `essence-2-max` name and its accepted
    // legacy `essence-2-quality` alias.
    func testCloudOnlyEngineSlugs() {
        XCTAssertTrue(isCloudOnlyEngineSlug("essence-2-quality"))
        XCTAssertTrue(isCloudOnlyEngineSlug("essence-2-max"))
        XCTAssertFalse(isCloudOnlyEngineSlug("essence-2-light"))
        XCTAssertFalse(isCloudOnlyEngineSlug("essence-2"))
        XCTAssertFalse(isCloudOnlyEngineSlug("expression-2"))
        XCTAssertFalse(isCloudOnlyEngineSlug("essence2"))
        XCTAssertTrue(cloudOnlyEngineSlugs.contains("essence-2-quality"))
        XCTAssertTrue(cloudOnlyEngineSlugs.contains("essence-2-max"))
    }

    func testCapabilityPresets() {
        // Byte-for-byte the policy hard-coded in AvatarTexture today.
        XCTAssertEqual(EngineCapabilities.expression2.speechCushion, 32)
        XCTAssertEqual(EngineCapabilities.expression2.audioReleaseSeconds, 0.05)
        XCTAssertEqual(EngineCapabilities.expression2.maxAudioQueueSamples, 96_000)
        XCTAssertEqual(EngineCapabilities.essence2.speechCushion, 1)
        XCTAssertEqual(EngineCapabilities.essence2.audioReleaseSeconds, 0.04)
        XCTAssertEqual(EngineCapabilities.essence2.maxAudioQueueSamples, 32_000)
        XCTAssertTrue(EngineCapabilities.essence2.supportsHeadMode)
        XCTAssertFalse(EngineCapabilities.expression2.supportsHeadMode)
    }

    func testAvatarRef() {
        let ref = AvatarRef(path: "/x/a.elevatedir", motionDir: "/y")
        XCTAssertEqual(ref.path, "/x/a.elevatedir")
        XCTAssertEqual(ref.motionDir, "/y")
        XCTAssertNil(ref.manifestEngineAbi)
    }

    // M3: the widened zero-alloc surface (pushAudio / framesAvailable /
    // pull(into:) / idle(into:) / benchSync) must (a) be reachable via the
    // existential and (b) have working defaults that wrap the allocating surface,
    // so a source-only engine conforms with no extra code.
    func testWidenedSurfaceDefaults() {
        let m = _MockEngine()
        let e: any BithumanEngine = m

        // pushAudio default → feed(_:)
        e.pushAudio([0.25, -0.5])
        XCTAssertEqual(m.fed, [0.25, -0.5])

        // framesAvailable default → queuedFrames
        XCTAssertEqual(e.framesAvailable, 1)

        // idle(into:) default copies the idle frame; returns bytes written.
        var buf = [UInt8](repeating: 0, count: 6)
        XCTAssertEqual(e.idle(into: &buf), 6)
        XCTAssertEqual(buf, [1, 2, 3, 4, 5, 6])

        // pull(into:) default wraps pull(): bytes + speech, drains the queue.
        var pb = [UInt8](repeating: 0, count: 6)
        let r = e.pull(into: &pb)
        XCTAssertEqual(r.bytes, 6)
        XCTAssertTrue(r.speech)
        XCTAssertEqual(pb, [10, 11, 12, 13, 14, 15])
        XCTAssertEqual(e.framesAvailable, 0)
        XCTAssertEqual(e.pull(into: &pb).bytes, 0)   // empty → 0

        // benchSync default is a no-op (just must be callable via the existential).
        e.benchSync(1)

        // Defaulted id/capabilities/speechCushion still resolve.
        XCTAssertEqual(_MockEngine.id.canonical, "mock")
        XCTAssertEqual(e.speechCushion, 32)
    }
}

/// Minimal conformer exercising ONLY the protocol's defaulted members — proves a
/// source-only engine conforms via the M3 widened-surface defaults with no extra
/// code (mirrors expression2, which overrides none of them).
private final class _MockEngine: BithumanEngine {
    static var id: EngineId { EngineId(canonical: "mock", aliases: ["m"]) }
    var capabilities: EngineCapabilities { .expression2 }
    let width = 2, height = 1                 // 2×1 px → 6 BGR bytes
    func warmUp(warmSpeech: [Float]?) {}
    var isReady = true
    var idle: [UInt8]? = [1, 2, 3, 4, 5, 6]
    var idleLoop: [[UInt8]] = []
    var fed: [Float] = []
    func feed(_ samples: [Float]) { fed.append(contentsOf: samples) }
    private var q: [[UInt8]] = [[10, 11, 12, 13, 14, 15]]
    func pull() -> (frame: [UInt8], speech: Bool)? { q.isEmpty ? nil : (q.removeFirst(), true) }
    var queuedFrames: Int { q.count }
    func resetState(clearFrames: Bool) { if clearFrames { q.removeAll() } }
    func flushTail() {}
    var hasPendingTail: Bool { false }
}
