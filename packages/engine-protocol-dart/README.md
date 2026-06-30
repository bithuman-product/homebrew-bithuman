# bithuman-engine-protocol

**Layer 0** of the bitHuman unified multi-engine architecture — the small,
zero-dependency shared contract that **every avatar engine and the umbrella
plugin depend on**. One interface, two language halves (Swift + Dart), so an
avatar engine and the app agree on the same vocabulary and a 3rd engine slots
in by adding data, not code.

> Canonical design: `unified_architecture_design.md` §1, §2 (status: **BUILT**,
> M0–M4 complete). This package is **Layer 0** in the `engine → sdk → app` map:
>
> ```
> bithuman-engine-protocol  (THIS repo, Layer 0)  ── BithumanEngine + EngineDescriptor
>        ▲                         ▲
> expression-2/sdk          essence-2/sdk          (Layer 1 — one per engine)
>        ▲                         ▲
> bithuman-avatar-plugin    (Layer 2 — the N-engine umbrella; the app's sole dep)
>        ▲
> bithuman-app              (the macOS product app)
> ```

---

## What's here

| Half | File / product | Contents |
|---|---|---|
| **Swift** | `Sources/BithumanEngineProtocol` (SwiftPM product `BithumanEngineProtocol`) | the common engine interface **`BithumanEngine`** + the value vocabulary **`EngineId`**, **`EngineCapabilities`**, **`AvatarRef`**. Zero native deps; builds macOS 13 + iOS 16. |
| **Dart** | `lib/bithuman_engine_protocol.dart` (pub package `bithuman_engine_protocol`) | **`EngineDescriptor`** + **`kEngineRegistry`** (`kExpression2`, `kEssence2`) + `engineDescriptorFor(slug)` — the typed routing contract for the app's gallery tabs and `BithumanAvatar.load(engine:)`. Pure Dart, zero runtime deps. |
| **Tests** | `Tests/BithumanEngineProtocolTests` | dual-accept matching, the two capability presets (byte-for-byte the live policy), and that the M3 widened-surface defaults are reachable + correct via a minimal `_MockEngine`. |

---

## The Swift interface contract

### `BithumanEngine` — what every engine conforms to

`BithumanEngine` is the **canonicalization** of the de-facto common interface
that used to live inside `expression-2/sdk` as `AvatarRuntime`. The plugin drives
**every** engine through it as `any BithumanEngine`, with **zero concrete
downcasts** (the old `avatar as? Essence2Runtime` branch is gone).

The member set is the **union** of the two live engine APIs, in four groups:

- **identity + policy** — `static var id: EngineId`, `var capabilities: EngineCapabilities`.
- **geometry / lifecycle** — `width`/`height`, `warmUp(warmSpeech:)`, `isReady`, `shutdown()`.
- **drive surface** — `feed(_:)`, `pull() -> (frame, speech)?`, `queuedFrames`,
  `speechCushion`, `idle`, `idleLoop`, plus turn control `resetState(clearFrames:)`,
  `flushTail()`, `hasPendingTail`.
- **M3 widened zero-alloc surface** — `pushAudio(_:)`, `framesAvailable`,
  `pull(into:)`, `idle(into:)`, `benchSync(_:)`. These let the plugin's
  `atomicSlotClock` loop push audio + pull frames straight into its own BGR
  buffer with no per-frame `Array` copy, through the existential.

Every widened (and most policy) member has a **default extension** that wraps the
allocating surface — so a **source-only engine** (`Expression2Engine`) conforms
with **no extra code**, while a **binary engine** (`Essence2Engine`) **overrides**
them with its `be_essence2_*` zero-alloc forms (byte-identical to the proven
passthroughs). They are protocol *requirements* (not extension-only), so an
existential call dynamically dispatches to the override.

### `EngineId` — routing identity (dual-accept)

```swift
public struct EngineId: Hashable {
  public let canonical: String   // "expression2" | "essence2" | …
  public let aliases: [String]   // ["embody", "expression-2"] | ["elevate", …] (FROZEN + cloud)
  public func matches(_ s: String) -> Bool   // canonical OR any alias
}
```

`matches` is the single multi-accept rule used everywhere the wire carries a slug.
The on-device aliases (`embody`, `elevate`) are **frozen** — the channel accepts
both names forever — and each engine ALSO carries its **cloud-API name** so a slug
from the public/REST taxonomy resolves to the same on-device engine:

| on-device engine | canonical | frozen on-device alias | cloud-API name(s) |
|---|---|---|---|
| Expression 2 | `expression2` | `embody` | `expression-2` |
| Essence 2 (on-device = cloud **light** tier) | `essence2` | `elevate` | `essence-2-light`, `essence-2-mobile` |

The GPU-only cloud tier **`essence-2-quality`** has **no on-device engine**, so it
is deliberately NOT an alias of `essence2`. It is instead listed in
`cloudOnlyEngineSlugs` (Swift) / `kCloudOnlyEngineSlugs` (Dart) so the app can tell
a known cloud-only tier from a typo, while `engineDescriptorFor`/the registry
return nothing for it (nothing to load locally):

```swift
public let cloudOnlyEngineSlugs: Set<String> = ["essence-2-quality"]
public func isCloudOnlyEngineSlug(_ s: String) -> Bool
```

### `EngineCapabilities` — static behaviour (replaces `engineKind == "…"`)

The data that replaces every hard-coded per-engine branch in the plugin
(`audioReleaseSeconds`, `maxAudioQueueSamples`, `speechCushion`, …). Two presets
capture today's exact policy, **byte-for-byte**:

| field | `.expression2` | `.essence2` |
|---|---|---|
| `driveModel` | `.bufferedDisplayClock` | `.atomicSlotClock` |
| `audioReleaseSeconds` | 0.05 | 0.04 |
| `speechCushion` | 32 | 1 |
| `maxAudioQueueSamples` | 96 000 | 32 000 |
| `hasNativeIdleLoop` | true | false |
| `supportsHeadMode` | false | true |
| `requiresEngineAbi` | 1 | 2 |

`driveModel` selects which of the two **proven** drive loops the plugin runs — the
embody feed-ahead + 20 fps display tick, or the essence2 single atomic feed+pull
tick — by capability, never by type.

### `AvatarRef` — what an identity resolves to before load

```swift
public struct AvatarRef {
  public var path: String          // ".elevatedir" / "embody://CODE" marker / model dir
  public var motionDir: String?    // essence2 actor .bhx; nil = engine default
  public var manifestEngineAbi: Int?   // matched against capabilities.requiresEngineAbi at install
}
```

Mirrors the `load` channel args (`path` / `motionDir`) plus the avatar manifest's
`requires_engine_abi` for the install-time gate.

---

## The Dart contract

The Dart side routes the gallery and `load()` by **descriptor**, not string
literal. The `BithumanAvatar.load(path, {engine, motionDir, chunk})` **wire**
contract is unchanged — the registry only types the call sites and the tabs.

```dart
class EngineDescriptor {
  final String canonical;        // 'expression2' | 'essence2'
  final List<String> aliases;    // ['embody','expression-2'] | ['elevate','essence-2-light','essence-2-mobile']
  final String label;            // 'Expression 2' | 'Essence 2'  (gallery tab)
  final bool loadsFromLocalDir;  // essence2 = true (.elevatedir); expression2 = code → download
  final int engineAbi;           // matched at install
  bool matches(String s) => s == canonical || aliases.contains(s);
}

const kEngineRegistry = <EngineDescriptor>[ kExpression2, kEssence2 /*, k3rd */ ];
EngineDescriptor? engineDescriptorFor(String slug);   // multi-accept resolve

// Cloud tiers with no on-device engine (GPU-only) — recognised, not loadable:
const Set<String> kCloudOnlyEngineSlugs = {'essence-2-quality'};
bool isCloudOnlyEngineSlug(String slug);
```

This mirrors the Swift `EngineId` + `EngineCapabilities`. The app renders **one
gallery tab per entry** in `kEngineRegistry`, so a 3rd engine is one `const`
descriptor and a 3rd tab with no new UI code.

---

## How an engine conforms

1. Add `bithuman-engine-protocol` to your engine SDK's `Package.swift` and
   `import BithumanEngineProtocol` — guarded by
   `#if canImport(BithumanEngineProtocol)` so the **same** adapter source also
   compiles when the umbrella stages it **in-module** (CocoaPods `static_framework`
   pods compile staged source, not SwiftPM packages, so inside the pod
   `BithumanEngine` resolves with **no** `import`).
2. Make your `…Engine` class conform to `BithumanEngine`. Override `static var id`
   with your frozen slugs and `var capabilities` with your policy.
3. **Source-only engine?** You're done — the defaults wrap your allocating
   surface. **Binary engine?** Override the widened zero-alloc members
   (`pushAudio`, `framesAvailable`, `pull(into:)`, `idle(into:)`) with your C-ABI
   forms for the hot path.
4. Add the Dart `EngineDescriptor` to your SDK's manifest and the app's
   `kEngineRegistry`.

The two live conformers are `expression-2/sdk/Classes/Expression2Engine.swift`
(source-only; overrides nothing) and `essence-2/sdk/Classes/Essence2Engine.swift`
(overrides the zero-alloc surface + `shutdown` + `speechCushion`).

---

## Who depends on it

- **`expression-2/sdk`** and **`essence-2/sdk`** (Layer 1 engine SDKs) — for their
  standalone SwiftPM builds, via the `#if canImport`-guarded import.
- **`bithuman-avatar-plugin`** (Layer 2 umbrella) — git-deps the Dart package
  (re-exported by its `lib/engine_registry.dart`) and keeps an in-tree copy of the
  Swift file at `shared/Classes/Protocol/BithumanEngine.swift` (the umbrella's
  bootstrap best-effort refreshes it from a dev checkout via
  `BITHUMAN_PROTOCOL_DIR`), staged into the pod module.

---

## Migration status

| Phase | This package |
|---|---|
| **M0** | introduced (additive) — lifted `AvatarRuntime` → `BithumanEngine` + `EngineId`/`EngineCapabilities`/`AvatarRef`, kept the exact member set the drive loop used, so every conformer compiled unchanged. Added the Dart `EngineDescriptor`/registry. |
| **M3** | **widened** with the zero-alloc surface (`pushAudio` / `framesAvailable` / `pull(into:)` / `idle(into:)` / `benchSync`) the now engine-agnostic plugin drives every engine through; the deprecated `AvatarRuntime` typealias is **retired** (no remaining users). |

## Build & test

```sh
swift build            # SwiftPM, macOS/iOS; zero native deps
swift test             # dual-accept + presets + widened-surface defaults
dart pub get           # the Dart half
```

Apache-2.0; (c) bitHuman.
