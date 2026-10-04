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
// expression2/embody, essence2/elevate). ★2.6.36: the load handler asks `select(_:)`
// first and REFUSES an unknown slug, or essence2 on a non-ESSENCE2_AVAILABLE build
// (EngineSelection.swift); the expression2 fallback below now only answers callers
// that have already passed that check.
//
// Apache-2.0; (c) bitHuman.

import Foundation
#if os(macOS) || os(iOS)
import Expression2   // the published binary (Expression2Credential)
#endif

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

  /// True when this build links the engine (canonical slug): Essence 2 only when bootstrap staged it.
  static func isInBuild(_ canonical: String) -> Bool {
    #if ESSENCE2_AVAILABLE
    return true
    #else
    return canonical != "essence2"
    #endif
  }

  /// What a `load(engine:)` names (2.6.36): the load handler refuses an unknown slug, or an engine
  /// this build does not carry, BEFORE anything is created — never the expression2 fallback above.
  static func select(_ slug: String) -> EngineSelection {
    EngineSelection.resolve(slug, among: descriptors.map { $0.id }, inBuild: isInBuild, unmetOS: unmetOS)
  }

  /// The OS an engine needs when this device runs an older one (2.6.36): Essence 2 renders on iOS 26 /
  /// macOS 26 and later. A no-op while the pod's floor is 26 (the staged libessence2 is built for 26);
  /// it is what refuses Essence 2 by name on iOS 16-25 once a libessence2 rebuilt at the package floor
  /// (#1826) lets the app run there.
  static func unmetOS(_ canonical: String) -> (need: String, running: String)? {
    guard canonical == "essence2" else { return nil }
    if #available(iOS 26.0, macOS 26.0, *) { return nil }
    let v = ProcessInfo.processInfo.operatingSystemVersion
    #if os(iOS)
    let os = "iOS"
    #else
    let os = "macOS"
    #endif
    return (need: "\(os) 26", running: "\(os) \(v.majorVersion).\(v.minorVersion)")
  }

  #if os(macOS) || os(iOS)
  /// Sign-out (2.6.36, security; `BithumanAvatar.clearCredentials`): both engines forget the API secret a
  /// load set for this process, so nothing after this runs (or bills) as the account that signed out.
  static func clearCredentials() {
    Expression2Credential.set(nil)
    #if ESSENCE2_AVAILABLE
    _ = be_essence2_set_api_secret(nil)
    #endif
  }

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
      // ★THIS load's credential, never an earlier one (2.6.36, security): a load without one CLEARS the
      // process-wide secret (NULL clears it), so it is refused by name instead of running, and billing,
      // as the account of an earlier load (a sign-out and sign-in, a Dart hot restart).
      if let s = ref.apiSecret, !s.isEmpty {
        _ = s.withCString { be_essence2_set_api_secret($0) }
      } else {
        _ = be_essence2_set_api_secret(nil)
      }
      return Essence2Engine()
    }
    #endif
    // REQUIRED default engine (expression2 / embody) — and the fallback for
    // essence2 on an embody-only (ESSENCE2_AVAILABLE-unset) build. Its per-agent
    // dir is set out of band via setExpression2AgentDir; the shared engine is
    // extracted by the buffered-display-clock setup before warmUp.
    // ★From Expression2 v2.6.5 the engine BILLS the session it serves, and a Release
    // build refuses (warmUp arms the meter first; `meteringRefusal` says why) without
    // a credential — an installed app has no BITHUMAN_API_SECRET in its environment,
    // so without this line every Expression2 app built on the plugin renders NOTHING.
    // Set BEFORE init, exactly as the essence2 branch above sets its secret.
    // ★THIS load's credential (2.6.36, security): `set(nil)` clears it, so a load without one never runs
    // as the account of an earlier load (the engine refuses it by name instead).
    Expression2Credential.set(ref.apiSecret)
    return Expression2PluginEngine()
  }
  #endif
}
