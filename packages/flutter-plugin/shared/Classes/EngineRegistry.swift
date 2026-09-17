// EngineRegistry.swift — the umbrella's engine registry (M3).
//
// Makes the plugin ENGINE-AGNOSTIC: instead of hard-coding loadEmbody() /
// loadEssence2() and branching on the `engineKind == "essence2"` string, the
// plugin resolves a (dual-accept) slug to an engine here and drives whatever
// `any BithumanEngine` comes back by its `capabilities.driveModel` (design §3).
//
// Two halves:
//   • A CROSS-PLATFORM descriptor table (id + capabilities). The load handler +
//     AvatarTexture read capabilities/canonical on BOTH macOS and iOS (the audio
//     policy must resolve on iOS too, where the engine itself never instantiates).
//   • A macOS-only `make(_:_:)` factory that actually CREATES the engine (the
//     engines are macOS-only today). It is the SOLE place that names a concrete
//     engine type — adding a 3rd engine is one descriptor entry + one make branch
//     (mirrors the Dart kEngineRegistry; design §4).
//
// Resolution is DUAL-ACCEPT via EngineId.matches (the FROZEN slugs:
// expression2/embody, essence2/elevate). An unknown/missing slug — and essence2
// on a non-ESSENCE2_AVAILABLE (embody-only) build — falls back to the REQUIRED
// default engine (expression2), exactly as the old loadFixtureAndRuntime did.
//
// Apache-2.0; (c) bitHuman.

import Foundation

/// One registered engine's static description (identity + behaviour). The
/// creation factory lives in `EngineRegistry.make` (macOS-only).
struct EngineRegistryDescriptor {
  let id: EngineId
  let capabilities: EngineCapabilities
}

enum EngineRegistry {
  /// The registered engines, in order; the FIRST is the REQUIRED default
  /// (expression2). The ids are the FROZEN on-device slugs PLUS each engine's
  /// CLOUD-API name, and MUST match each engine's own `static var id`
  /// (Expression2Engine.id / Essence2Engine.id). A 3rd engine appends one entry
  /// here (+ one `make` branch + its staged SDK).
  static let descriptors: [EngineRegistryDescriptor] = [
    EngineRegistryDescriptor(
      id: EngineId(canonical: "expression2", aliases: ["embody", "expression-2"]),
      capabilities: .expression2),
    EngineRegistryDescriptor(
      // `essence-2` IS the name — the other three are RETIRED spellings kept
      // accepted so links, share JWTs and stored rows minted under them still
      // resolve: `elevate` (pre-launch on-device slug), `essence-2-light` (the
      // retired tier name for this same engine; owner 2026-09-17 "retire
      // lightxxx, it should be just called essence-2") and `essence-2-mobile`
      // (old App-Store name). Accept four, teach one. The strings are frozen
      // wire values. Lockstep with Essence2Engine.id + the Dart kEssence2.
      id: EngineId(canonical: "essence2",
                   aliases: ["elevate", "essence-2", "essence-2-light", "essence-2-mobile"]),
      capabilities: .essence2),
  ]

  /// Resolve a (possibly aliased) slug → its descriptor, falling back to the
  /// REQUIRED default engine (expression2) for unknown/missing slugs. A
  /// cloud-only slug (no on-device engine) also has no
  /// descriptor; it falls back to the default like any unservable slug — callers
  /// that must NOT degrade should pre-check `isCloudOnlyEngineSlug` (the app does
  /// this before ever requesting a local load).
  static func descriptor(for slug: String) -> EngineRegistryDescriptor {
    descriptors.first { $0.id.matches(slug) } ?? descriptors[0]
  }

  /// Static behaviour for a slug — replaces every `engineKind == "essence2"`
  /// policy read (audioReleaseSeconds / cushion).
  static func capabilities(for slug: String) -> EngineCapabilities {
    descriptor(for: slug).capabilities
  }

  /// Canonical slug for a (possibly aliased) wire slug.
  static func canonical(for slug: String) -> String {
    descriptor(for: slug).id.canonical
  }

  #if os(macOS) || os(iOS)
  /// Create the engine for a slug. The ONLY place a concrete engine type is
  /// named. Returns `any BithumanEngine`; the caller drives it purely through the
  /// protocol + `capabilities.driveModel`. essence2 is gated on
  /// ESSENCE2_AVAILABLE (its static `.a` staged); absent it, an essence2 request
  /// degrades to the embody default — exactly the old loadFixtureAndRuntime
  /// fallback. Per-engine pre-create setup (the essence2 statics from the avatar
  /// ref) lives in its branch so the load handler stays engine-agnostic.
  static func make(_ slug: String, _ ref: AvatarRef) -> any BithumanEngine {
    #if ESSENCE2_AVAILABLE
    // Resolve through the registry so EVERY essence2 slug — the canonical, the
    // frozen `elevate`, AND the retired `essence-2-light` / `essence-2-mobile`
    // spellings — lands here (not just an inline ["elevate"] list).
    if canonical(for: slug) == "essence2" {
      // `ref.path` is the `.elevatedir`; `ref.motionDir` the actor .bhx (nil =
      // engine default). Set BEFORE init (Essence2Engine reads the statics).
      Essence2Engine.activeAgentDir = ref.path
      Essence2Engine.motionDir = ref.motionDir
      // The engine bills the session it is about to serve; the credential must
      // be set BEFORE be_essence2_create (which arms the meter first, before any
      // work). Without it the engine's own fallback is the process environment
      // (BITHUMAN_API_SECRET), which an installed app never has.
      if let s = ref.apiSecret, !s.isEmpty {
        _ = s.withCString { be_essence2_set_api_secret($0) }
      }
      return Essence2Engine()
    }
    #endif
    // REQUIRED default engine (expression2 / embody) — and the fallback for
    // essence2 on an embody-only (ESSENCE2_AVAILABLE-unset) build. Its per-agent
    // dir is set out of band via setExpression2AgentDir; the shared engine is
    // extracted by the buffered-display-clock setup before warmUp.
    return Expression2Engine()
  }
  #endif
}
