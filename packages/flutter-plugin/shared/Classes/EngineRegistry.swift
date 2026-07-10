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
      // essence2 aliases = frozen `elevate` + the cloud LIGHT-tier names + the
      // COMBINED creation name `essence-2` (2026-07-02: agents.model stores it
      // verbatim; the platform folds it onto the light family, whose on-device
      // leg is this engine). Lockstep with Essence2Engine.id + the Dart
      // kEssence2. essence-2-max (formerly essence-2-quality; both accepted)
      // stays cloud-only (deliberately absent).
      id: EngineId(canonical: "essence2",
                   aliases: ["elevate", "essence-2", "essence-2-light", "essence-2-mobile"]),
      capabilities: .essence2),
  ]

  /// Resolve a (possibly aliased) slug → its descriptor, falling back to the
  /// REQUIRED default engine (expression2) for unknown/missing slugs. A
  /// cloud-only slug (e.g. `essence-2-quality`, no on-device engine) also has no
  /// descriptor; it falls back to the default like any unservable slug — callers
  /// that must NOT degrade should pre-check `isCloudOnlyEngineSlug` (the app does
  /// this before ever requesting a local load).
  static func descriptor(for slug: String) -> EngineRegistryDescriptor {
    descriptors.first { $0.id.matches(slug) } ?? descriptors[0]
  }

  /// Static behaviour for a slug — replaces every `engineKind == "essence2"`
  /// policy read (audioReleaseSeconds / maxAudioQueueSamples / cushion).
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
    // frozen `elevate`, AND the cloud-API names `essence-2-light` /
    // `essence-2-mobile` — lands here (not just an inline ["elevate"] list).
    if canonical(for: slug) == "essence2" {
      // `ref.path` is the `.elevatedir`; `ref.motionDir` the actor .bhx (nil =
      // engine default). Set BEFORE init (Essence2Engine reads the statics).
      Essence2Engine.activeAgentDir = ref.path
      Essence2Engine.motionDir = ref.motionDir
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
