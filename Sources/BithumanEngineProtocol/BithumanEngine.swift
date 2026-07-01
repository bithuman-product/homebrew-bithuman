// BithumanEngine.swift — the COMMON ENGINE INTERFACE (Layer 0).
//
// Canonical home: github.com/bithuman-product/homebrew-bithuman
// (Sources/BithumanEngineProtocol — the `BithumanEngineProtocol` SwiftPM
// product, zero native deps; builds macOS + iOS; inlined from the archived
// bithuman-engine-protocol repo). Depended on by BOTH engine SDKs
// (bithuman-models models/expression-2/sdk + models/essence-2/sdk) AND the
// umbrella Flutter plugin pod.
//
// This is the canonicalization of the de-facto common interface that used to
// live in expression-2/sdk as `AvatarRuntime`: it is renamed `BithumanEngine`
// and the per-`engineKind` policy + routing identity are promoted onto the
// value types `EngineId` / `EngineCapabilities` / `AvatarRef` (design §1.1).
//
// M0 was ADDITIVE: the protocol kept the exact member set the `AvatarTexture`
// drive loop invoked, so every conformer compiled unchanged. M3 WIDENS it with
// the zero-alloc surface (`pushAudio` / `framesAvailable` / `pull(into:)` /
// `idle(into:)`) the now engine-agnostic plugin drives every engine through
// (replacing the `avatar as? Essence2Runtime` downcast onto concrete
// passthroughs), plus a defaulted `benchSync(_:)` for the dev throughput hook.
// Each widened member has a default (extension below) wrapping the allocating
// surface — so a source-only engine (expression2) conforms with no extra code —
// while the essence2 adapter overrides them with its be_elevate_* forms
// (byte-identical to the proven passthroughs). The deprecated `AvatarRuntime`
// alias is RETIRED in M3 (no remaining users).
//
// NOTE ON THE POD BUILD: the umbrella pod compiles this file as STAGED SOURCE
// folded into its own module (no `import`), exactly as it compiles the engine
// adapter sources — so inside the pod `BithumanEngine` resolves in-module. The
// engine SDKs' standalone SwiftPM builds instead `import BithumanEngineProtocol`
// (guarded by `#if canImport(BithumanEngineProtocol)`), so the SAME adapter
// source compiles both ways.
//
// Apache-2.0; (c) bitHuman.

import Foundation

/// Identity + frozen aliases of an engine, used for routing/registration.
/// The aliases are the FROZEN dual-accept slugs (`embody` for expression2,
/// `elevate` for essence2) — see the design's frozen-contracts section. Each
/// engine's conformer ALSO carries its CLOUD-API name (`expression-2` for
/// expression2; `essence-2-light` + `essence-2-mobile` for essence2) as an
/// additional alias, so a slug arriving in the public/cloud taxonomy routes to
/// the same on-device engine. (The GPU-only cloud tier `essence-2-quality` has
/// no on-device engine — see `cloudOnlyEngineSlugs` — so it is NOT an alias.)
public struct EngineId: Hashable {
    public let canonical: String          // "expression2" | "essence2" | …
    public let aliases: [String]          // ["embody", "expression-2"] | …
    public init(canonical: String, aliases: [String] = []) {
        self.canonical = canonical
        self.aliases = aliases
    }
    /// Multi-accept match: the canonical slug OR any frozen/cloud alias.
    public func matches(_ s: String) -> Bool { s == canonical || aliases.contains(s) }
}

/// Cloud-API tier names the app RECOGNISES but cannot serve on-device (no engine
/// conforms to them). Today: the GPU-only `essence-2-quality` tier. The registry
/// returns no descriptor for these, so a caller can tell "known cloud-only tier"
/// apart from "unknown slug" without pretending the on-device essence2 (light /
/// a2x) engine can serve them. Mirrors the Dart `kCloudOnlyEngineSlugs`.
public let cloudOnlyEngineSlugs: Set<String> = ["essence-2-quality"]

/// True for a slug the cloud API serves but the device cannot (no on-device
/// engine). Such a slug must NOT be loaded locally — surface it as cloud-only.
public func isCloudOnlyEngineSlug(_ s: String) -> Bool { cloudOnlyEngineSlugs.contains(s) }

/// Static behaviour of an engine — the data that replaces every hard-coded
/// `engineKind == "essence2"` branch in the plugin (adopted by the drive loop
/// in M3). The two presets below capture today's exact per-engineKind policy.
public struct EngineCapabilities {
    public enum DriveModel {
        /// expression2: producer buffers; a separate even display clock; deep
        /// feed-ahead (composeTickEmbody + the 20 fps embodyDisplayTick).
        case bufferedDisplayClock
        /// essence2: continuous slot clock; a single atomic feed+pull per tick
        /// (composeTickEssence2).
        case atomicSlotClock
    }
    public var driveModel: DriveModel
    public var audioReleaseSeconds: Double   // 0.05 expression2 / 0.04 essence2
    public var speechCushion: Int            // 32 expression2 / 1 essence2
    public var maxAudioQueueSamples: Int     // 96_000 expression2 / 32_000 essence2
    public var hasNativeIdleLoop: Bool       // expression2 pre-renders; essence2 = native passthrough
    public var supportsHeadMode: Bool        // essence2 FULL/HEAD; expression2 false
    public var requiresEngineAbi: Int        // matched against the avatar manifest

    public init(driveModel: DriveModel,
                audioReleaseSeconds: Double,
                speechCushion: Int,
                maxAudioQueueSamples: Int,
                hasNativeIdleLoop: Bool,
                supportsHeadMode: Bool,
                requiresEngineAbi: Int) {
        self.driveModel = driveModel
        self.audioReleaseSeconds = audioReleaseSeconds
        self.speechCushion = speechCushion
        self.maxAudioQueueSamples = maxAudioQueueSamples
        self.hasNativeIdleLoop = hasNativeIdleLoop
        self.supportsHeadMode = supportsHeadMode
        self.requiresEngineAbi = requiresEngineAbi
    }

    /// expression2 (embody) — the buffered display-clock policy, byte-for-byte
    /// the values currently hard-coded in `AvatarTexture` for the non-essence2 path.
    public static let expression2 = EngineCapabilities(
        driveModel: .bufferedDisplayClock,
        audioReleaseSeconds: 0.05,
        speechCushion: 32,
        maxAudioQueueSamples: 96_000,
        hasNativeIdleLoop: true,
        supportsHeadMode: false,
        requiresEngineAbi: 1)

    /// essence2 (elevate) — the atomic slot-clock policy, byte-for-byte the
    /// values currently keyed off the `"essence2"` string in `AvatarTexture`.
    public static let essence2 = EngineCapabilities(
        driveModel: .atomicSlotClock,
        audioReleaseSeconds: 0.04,
        speechCushion: 1,
        maxAudioQueueSamples: 32_000,
        hasNativeIdleLoop: false,
        supportsHeadMode: true,
        requiresEngineAbi: 2)
}

/// What an avatar identity resolves to before load (path + side data). Mirrors
/// the current `load` channel args (`path` / `motionDir`) plus the manifest's
/// `requires_engine_abi` for the install-time gate.
public struct AvatarRef {
    public var path: String          // ".elevatedir" / "embody://CODE" marker / model dir
    public var motionDir: String?    // essence2 actor .bhx; nil = default cache path
    public var manifestEngineAbi: Int?
    public init(path: String, motionDir: String? = nil, manifestEngineAbi: Int? = nil) {
        self.path = path
        self.motionDir = motionDir
        self.manifestEngineAbi = manifestEngineAbi
    }
}

/// The COMMON INTERFACE every avatar engine conforms to. The member set below
/// is the EXACT surface `AvatarTexture`'s drive loop invokes today, so each
/// engine adapter conforms with no behaviour change. `id` + `capabilities` are
/// new (defaulted) so existing conformers compile unchanged while the registry
/// and the M3 capability-driven drive loop can read them.
public protocol BithumanEngine: AnyObject {
    /// Registration identity (canonical slug + frozen aliases).
    static var id: EngineId { get }
    /// Static behaviour — replaces the per-`engineKind` policy in the plugin.
    var capabilities: EngineCapabilities { get }

    // ---- geometry (read once to size the texture) ----
    var width: Int { get }
    var height: Int { get }

    // ---- lifecycle ----
    func warmUp(warmSpeech: [Float]?)                   // heavy load+compile; flips isReady
    var isReady: Bool { get }                           // speech path live (gates mic/connect)
    func shutdown()                                     // drain native worker before host exit

    // ---- idle ----
    var idle: [UInt8]? { get }                          // one BGR w*h*3 idle frame
    var idleLoop: [[UInt8]] { get }                     // pre-rendered BGR idle loop, may be []

    // ---- audio in (16 kHz mono Float[-1,1], non-blocking) ----
    func feed(_ samples: [Float])

    // ---- video out (BGR, w*h*3) ----
    func pull() -> (frame: [UInt8], speech: Bool)?      // speech gates audio release
    var queuedFrames: Int { get }
    var speechCushion: Int { get }                      // frames to build before entering speech

    // ---- turn control ----
    func resetState(clearFrames: Bool)                  // barge / new-utterance reset
    func flushTail()
    var hasPendingTail: Bool { get }

    // ---- M3 widened zero-alloc surface (driven via `any BithumanEngine`) ----
    // The plugin's atomicSlotClock drive loop (composeTickEssence2) pushes audio
    // + pulls frames straight into its OWN bgrBuffer with no per-frame Array
    // copy, through THESE methods on the existential — replacing the former
    // `avatar as? Essence2Runtime` downcast onto concrete passthroughs. Each has
    // a default (below) that wraps the allocating surface (feed/pull()/idle/
    // queuedFrames), so a source-only engine like expression2 conforms with no
    // extra code; the essence2 adapter OVERRIDES them with its be_elevate_*
    // zero-alloc forms (byte-identical to the proven passthroughs).
    /// Canonical 16 kHz mono Float[-1,1] push (was feed/pushI16). For essence2
    /// this MUST preserve its exact int16 conversion (the a2x render path is
    /// byte-frozen), so the adapter overrides it.
    func pushAudio(_ samples: [Float])
    /// Frames ready to pull (was queuedFrames / the essence2 framesAvailable()).
    var framesAvailable: Int { get }
    /// Zero-alloc pull into a caller buffer. Returns bytes written + whether the
    /// frame is GENERATED speech (gates audio release) or an idle/warmup
    /// passthrough. Subsumes pull() AND the essence2 pulledSpeechFrames() delta.
    func pull(into buffer: inout [UInt8]) -> (bytes: Int, speech: Bool)
    /// Next idle frame into a caller buffer; bytes written (0 = none).
    func idle(into buffer: inout [UInt8]) -> Int
    /// DEV-only peak-generation throughput bench (default no-op). expression2
    /// implements it so the EMBODY_BENCH hook runs via the existential with no
    /// concrete downcast.
    func benchSync(_ secs: Int)
}

public extension BithumanEngine {
    /// Routing identity default — engines override with their frozen slugs.
    static var id: EngineId { EngineId(canonical: "unknown") }
    /// Default policy = the expression2 (buffered display-clock) profile; the
    /// essence2 adapter overrides it. (M0: read by no one yet; wired in M3.)
    var capabilities: EngineCapabilities { .expression2 }

    /// Matches the `rt.resetState()` call sites (the concrete default arg the
    /// existential can't see); dispatches to resetState(clearFrames:) so each
    /// engine's witness — including essence2's — is reached.
    func resetState() { resetState(clearFrames: true) }
    /// Frames the display loop builds before flipping into the speech branch.
    /// expression2's ci=0/ci=1 pipeline needs ~32; the essence2 adapter
    /// OVERRIDES this to 1 (its continuous slot clock keeps frames_available
    /// ~0-3, never reaching 32). A protocol requirement (not extension-only) so
    /// an existential call dynamically dispatches to that override.
    var speechCushion: Int { 32 }
    /// Default teardown is a no-op (expression2 relies on ARC/deinit); the
    /// essence2 adapter OVERRIDES this to drain the MLX/ANE worker before host
    /// exit. A protocol requirement so an existential call reaches that override.
    func shutdown() {}

    // ---- M3 widened-surface defaults ----
    // Wrap the allocating surface so a source-only engine (expression2) conforms
    // with no extra code (its drive loop uses feed/pull()/idle directly; these
    // defaults exist only for conformance). The essence2 adapter overrides all
    // four with its be_elevate_* zero-alloc forms. They are protocol REQUIREMENTS
    // (above), so an existential call dynamically dispatches to that override.
    /// Default push routes to feed(_:). essence2 overrides to keep its exact
    /// int16 conversion (byte-frozen a2x path).
    func pushAudio(_ samples: [Float]) { feed(samples) }
    var framesAvailable: Int { queuedFrames }
    func pull(into buffer: inout [UInt8]) -> (bytes: Int, speech: Bool) {
        guard let p = pull() else { return (0, false) }
        let n = min(p.frame.count, buffer.count)
        if n > 0 {
            p.frame.withUnsafeBufferPointer { s in buffer.withUnsafeMutableBufferPointer { d in
                if let db = d.baseAddress, let sb = s.baseAddress { db.update(from: sb, count: n) }
            } }
        }
        return (n, p.speech)
    }
    func idle(into buffer: inout [UInt8]) -> Int {
        guard let i = idle else { return 0 }
        let n = min(i.count, buffer.count)
        if n > 0 {
            i.withUnsafeBufferPointer { s in buffer.withUnsafeMutableBufferPointer { d in
                if let db = d.baseAddress, let sb = s.baseAddress { db.update(from: sb, count: n) }
            } }
        }
        return n
    }
    func benchSync(_ secs: Int) {}
}

// The pre-canonicalization `AvatarRuntime` typealias is RETIRED in M3: the plugin
// and both engine adapters now reference `BithumanEngine` directly (no remaining
// `AvatarRuntime` users), so the deprecated alias is removed (design §5 / M3).
