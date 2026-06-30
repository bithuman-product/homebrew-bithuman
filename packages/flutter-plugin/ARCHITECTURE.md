# bitHuman avatar — top-level architecture (`engine → sdk → app`)

**Status: BUILT** (M0–M4 complete). This is the **canonical** map of how the
whole avatar stack fits together: two avatar engines, each with multiple serving
tiers, conforming to one shared interface, aggregated by this umbrella plugin,
consumed by one app. The governing design is `unified_architecture_design.md`;
this file is the operational overview that lives with the umbrella.

```
                         Layer 0 — bithuman-engine-protocol
              BithumanEngine + EngineId/EngineCapabilities/AvatarRef   (Swift)
                       EngineDescriptor + kEngineRegistry              (Dart)
                                  ▲                    ▲
                ┌─────────────────┘                    └─────────────────┐
        Layer 1 — expression-2/sdk                  Layer 1 — essence-2/sdk
        Expression2Engine.swift (SOURCE)            Essence2Engine.swift + be_essence2.h
        manifest.yaml · bootstrap.sh                manifest.yaml · bootstrap.sh
        (fetches CoreML models)                     (fetches + extracts libessence2.a)
                                  ▲                    ▲
                                  │  staged by the N-engine loop (bootstrap.sh)
                       Layer 2 — bithuman-avatar-plugin  (THIS repo, the umbrella)
        engine-agnostic glue · EngineRegistry · RealtimeAudioIO · Converse*
        the ONE module-map xcframework: libconverse  ·  Engines/<engine>/*.a (static)
                                  ▲
                                  │  pinned git-dep (single dependency)
                              bithuman-app  (macOS product app)
        kEngineRegistry tab-per-engine gallery · OpenAI Realtime / on-device brain
```

The whole point of the layering: a **3rd engine** drops in with a same-shaped
`sdk/` + a `manifest.yaml` + one line in the umbrella's engine list + one
`EngineDescriptor` — **no edits** to the other engines, the brain, or the audio
IO. (See § "Recipe: add a 3rd engine".)

---

## The two engines and all their tiers

Both engines serve the same shape — `audio → motion → frames` — across multiple
**serving tiers** (different hardware backends). The **on-device** (Apple
Silicon) tier of each is what this umbrella + the app consume; the **cloud** tiers
are served by the platform via `?model=` dispatch and are listed here so the map
is complete. Each engine's own `TIERS.md` is the master deploy map.

### Expression 2 (embody) — `expression-2` repo · 3 tiers

Gold path: `audio → wav2vec2 → student_v4 → TAEHV → 416×720 @ 20 fps`.

| tier | backend | dispatch | runs on | role in this stack |
|---|---|---|---|---|
| **GPU** | `engine/gpu/` torch CUDA fp16 (`Expression2GpuEngine`) | `?model=embody-gpu` | lafayette 4090 (primary) · Cerebrium `expression2-gpu-worker` ADA_L40 (overflow) | cloud serving (platform) |
| **CPU** | `engine/cpu/` C++ `libembody.so` (oneDNN/AMX int8) | `?model=embody-cpu` | Cerebrium Ice Lake | cloud serving (platform) |
| **ANE** | `engine/ane/` CoreML export → `sdk/` runtime | n/a (no server) | Apple Silicon, **on-device** | **← consumed here** (Layer 1 = `expression-2/sdk`) |

The **ANE** tier is `expression-2/sdk` (Layer 1): `Expression2Engine.swift` loads
the CoreML graphs and streams frames on-device. **SOURCE-ONLY** — pure Swift +
CoreML, no native static lib. Frozen on-device formats: `.model` (shared engine:
w2v + taehv + warm) + `.avatar` (per-identity: student + atok + canon + idle.mp4
+ persona), ABI-versioned (`requires_engine_abi: 1`).

### Essence 2 (Essence2 / a2x) — `essence-2` repo · 2-level taxonomy

`quality` = GPU only (premium DiT); `light` = `gpu` + `ane` + `cpu` (distilled).

| tier | backend | dispatch | runs on | role in this stack |
|---|---|---|---|---|
| **quality (GPU)** | `engine/quality/gpu/` FP8 DiT + LivePortrait TRT (sm_89) | `?model=elevate` | orinda 4070 Ti (primary) · Cerebrium `essence2-quality-gpu-worker` ADA_L40 (overflow) | cloud serving (platform) |
| **light · GPU** | `engine/light/gpu/` le_a2x + m4b director, ORT-CUDA | `?model=elevate-gpu-light` | Cerebrium `essence2-light-gpu-worker` (lafayette pool decommissioned 06-25) | cloud serving (platform) |
| **light · CPU** | `engine/light/cpu/` C++ `lible_core.so` | `?model=elevate-cpu` | Cerebrium `essence2-light-cpu-worker` | cloud serving (deprioritized) |
| **light · ANE (cloud)** | `engine/light/ane/ane/moraga_serve` native Mac-ANE | `?model=elevate-ane` | moraga `:8091` | cloud serving (owned HW overflow) |
| **light · ANE (on-device)** | `engine/light/ane/` Essence2 Swift pkg → CoreML/ANE a2x | n/a (no server) | Apple Silicon, **on-device** | **← consumed here** (Layer 1 = `essence-2/sdk`) |

The on-device **light/ANE** tier is `essence-2/sdk` (Layer 1):
`Essence2Engine.swift` over the `be_essence2_*` C ABI, published as
`libessence2.xcframework` (release `libessence2-v1.0-a2x`). Frozen on-device format:
`.elevatedir` per-identity bundle (`requires_engine_abi: 2`), BGR-no-swap output,
the byte-frozen a2x render path. **OPTIONAL** — absent its static lib the build is
embody-only.

> Two meanings of "ANE": `engine/light/ane/` is the on-device Apple-Silicon a2x
> runtime (no server); `…/ane/moraga_serve` + `?model=elevate-ane` is a separate
> **cloud** Mac-ANE tier. The umbrella consumes the first.

---

## Layer 0 — the shared contract (`bithuman-engine-protocol`)

The zero-dependency interface both engines and this umbrella depend on:

- **Swift** — `BithumanEngine` (the canonicalization of the old `AvatarRuntime`)
  + `EngineId` (canonical slug + frozen/cloud aliases, multi-accept `matches`) +
  `EngineCapabilities` (the static policy that replaces every
  `engineKind == "essence2"` branch) + `AvatarRef` + `cloudOnlyEngineSlugs`.
- **Dart** — `EngineDescriptor` + `kEngineRegistry` (`kExpression2`, `kEssence2`)
  + `kCloudOnlyEngineSlugs`.

**Cloud-API names route too.** Each engine's `EngineId.aliases` carries, beside
the frozen on-device slug, its public/cloud REST name so a slug from the cloud
taxonomy resolves to the same on-device engine: `expression2`/`embody` also
matches `expression-2`; `essence2`/`elevate` also matches `essence-2-light` and
`essence-2-mobile` (the on-device essence2 = on-device leg of the cloud **light**
tier). The GPU-only cloud tier `essence-2-quality` has **no on-device engine**, so
it is NOT an alias — it lives in `cloudOnlyEngineSlugs` / `kCloudOnlyEngineSlugs`
(recognised as a known cloud-only tier, never loaded locally).

This umbrella keeps an **in-tree copy** of the Swift file at
`shared/Classes/Protocol/BithumanEngine.swift` (so the load-bearing protocol
always builds offline); `scripts/bootstrap.sh` best-effort refreshes it from a
dev checkout via `BITHUMAN_PROTOCOL_DIR`. The Dart half is a git-dep, re-exported
by `lib/engine_registry.dart`, so the frozen slugs have a single source of truth.

See the protocol repo's README for the full member set and the
default-wraps-allocating-surface conformance rule.

---

## Layer 1 — each engine's `sdk/` (the identical shape)

Both engine repos expose an **identically-shaped** `sdk/` conforming to Layer 0:

```
<engine-repo>/sdk/
  Package.swift          # SwiftPM target → product the umbrella & CI consume; deps bithuman-engine-protocol
  Classes/<Engine>Engine.swift   # the adapter SOURCE conforming to BithumanEngine
  include/<c_abi>.h      # C ABI header — BINARY engines only (e.g. be_essence2.h)
  Vendor/                # bootstrap-fetched static lib + resources (GITIGNORED)
  scripts/bootstrap.sh   # fetch + sha256-verify the engine's release; extract the .a
  manifest.yaml          # engineId + aliases, capabilities, requiresEngineAbi, native{}, resources, platforms
  README.md
```

- **`expression-2/sdk`** — `Expression2Engine.swift` (source-only). `manifest.yaml`
  declares `native: { hasNativeLib: false }`; its bootstrap fetches the embody
  CoreML model bundle (no static lib), landing under the FROZEN `embody`
  subdirectory.
- **`essence-2/sdk`** — `Essence2Engine.swift` + `include/be_essence2.h`. Its
  bootstrap fetches the sha-pinned `libessence2-v1.0-a2x` release and extracts the
  per-platform `libessence2.a` + resources. `manifest.yaml` declares
  `native: { gate: ESSENCE2_AVAILABLE, vendoredLib: libessence2.a, umbrellaHeader:
  include/be_essence2.h, release{tag, sha256, resourcesSha256}, resources[…] }`.

`manifest.yaml` is the single machine-readable description the umbrella reads to
"drop in" an engine.

---

## Layer 2 — this umbrella (the N-engine aggregator)

### The bootstrap N-engine loop (`scripts/bootstrap.sh`)

1. Fetch + sha256-verify **`libconverse.xcframework`** (the brain) from the
   `vendor-v1` embody Release → `<plat>/Frameworks/`. The ONE module-map
   xcframework. (DEV mode: symlink it from a sibling `BITHUMAN_SDK_DIR`.)
2. For each engine in the loop (`stage_expression2`, `stage_essence2`):
   - **locate** its `sdk/` — `BITHUMAN_<ENGINE>_DIR` dev override → sibling
     checkout → shallow `gh` clone into `~/.cache/bithuman`.
   - **run** that SDK's own `scripts/bootstrap.sh` (fetches/extracts its native
     deps). A sha256 **mismatch** is a hard, loud failure; a missing optional
     release degrades that engine to absent.
   - **stage** its surfaces under `<plat>/Engines/<engine>/`:
     `Classes/*.swift` (compiled in-module), `include/*.h` (folded into the pod
     umbrella), `Vendor/*.a` (vendored static lib), `Vendor/*-resources` (shipped
     as resources).

expression2 is **REQUIRED** (the default; a missing SDK is fatal); essence2 is
**OPTIONAL** (a missing SDK / download → embody-only). Adding a 3rd engine is one
more `stage_<engine>` call.

### INVARIANT #1 — exactly one module-map xcframework per pod

A CocoaPods `static_framework` pod cannot host two vendored **module-map**
(C-module) xcframeworks — their module maps collide and break each other's Clang
module resolution (the clash commit `3b53fc0` fixed). Therefore:

- **`libconverse.xcframework`** keeps the single module-map slot (its
  `Headers/module.modulemap` declares `module CConverse`).
- **Every avatar engine's native core is a PLAIN static `.a`**
  (`s.vendored_libraries`), and its C ABI header is folded into THIS pod's own
  auto-generated **umbrella module** via `DEFINES_MODULE => YES` +
  `public_header_files`. So the pod's Swift calls `be_essence2_*` with **no
  `import`** — exactly as it calls `bh_tryRun` from the `BHObjCException.h` shim.
- A per-engine **Swift active-compilation-condition** (`ESSENCE2_AVAILABLE`) is set
  only when that engine's `.a` was staged, so an engine-absent build is
  byte-identical and shippable.

The podspec **enforces** this mechanically (`macos/bithuman.podspec`):

```ruby
# auto-pick every staged engine's plain static lib
engine_libs = Dir.glob(File.join(__dir__, 'Engines/*/Vendor/*.a'))

# CI ASSERT: no engine may vendor a module-map xcframework
engine_xcframeworks = Dir.glob(File.join(__dir__, 'Engines/*/Vendor/*.xcframework'))
raise "INVARIANT #1 violated …" unless engine_xcframeworks.empty?

# CI ASSERT: exactly one module-map xcframework (libconverse)
module_map_xcframeworks = ['Frameworks/libconverse.xcframework']
raise "INVARIANT #1 violated …" unless module_map_xcframeworks.length == 1
s.vendored_frameworks = module_map_xcframeworks
s.vendored_libraries  = engine_libs.map { |p| p.sub(__dir__ + '/', '') } if !engine_libs.empty?

s.source_files        = 'Classes/**/*.{swift,h,m}', 'Engines/**/Classes/**/*.swift', 'Engines/**/include/**/*.h'
s.public_header_files  = 'Classes/**/*.h', 'Engines/**/include/**/*.h'
# ESSENCE2_AVAILABLE set only when a libessence2.a is staged → embody-only stays byte-identical
```

### EngineRegistry dispatch + `capabilities.driveModel`

`shared/Classes/EngineRegistry.swift` makes the plugin engine-agnostic. It has two
halves:

- a **cross-platform descriptor table** (`id` + `capabilities`) read by the load
  handler + `AvatarTexture` on BOTH macOS and iOS (the audio policy must resolve
  on iOS too, where the engine never instantiates). `descriptor(for:)` /
  `capabilities(for:)` / `canonical(for:)` resolve a slug **multi-accept** (the
  canonical, the frozen on-device alias, AND the cloud-API name) and fall back to
  the REQUIRED default (expression2) for unknown/missing slugs.
- a **macOS-only factory** `make(slug, ref) -> any BithumanEngine` — the **sole**
  place a concrete engine type is named. It routes essence2 via
  `canonical(for: slug) == "essence2"` so the cloud names (`essence-2-light` /
  `-mobile`) reach it too; essence2 is gated on `ESSENCE2_AVAILABLE`, absent which
  an essence2 request degrades to the embody default.

The plugin then drives whatever `any BithumanEngine` comes back **purely by
`capabilities.driveModel`** — `.bufferedDisplayClock` runs the embody feed-ahead +
20 fps display tick; `.atomicSlotClock` runs the essence2 single atomic feed+pull
tick (the byte-frozen a2x path). Both loops are kept **verbatim** and selected by
capability — no `engineKind` string branches, no `as? Essence2Runtime` downcast.
The per-engine policy (`audioReleaseSeconds` / `maxAudioQueueSamples` /
`speechCushion`) is read from `capabilities`.

### What else the umbrella owns

- **`BithumanAvatarPlugin.swift`** — the `FlutterTexture` glue + the
  `ai.bithuman.avatar` method channel (frozen, incl. dual-accept methods
  `setExpression2AgentDir`/`setEmbodyAgentDir`).
- **`RealtimeAudioIO.swift`** — the single VP-IO `AVAudioEngine` graph (mic AEC +
  sample-accurate speaker/lip-sync from the same chunk + ~50 ms client VAD barge).
- **`Converse*` / `LocalConverseController` / `SpeechPipeline`** — the on-device
  brain wiring over `libconverse` (llama.cpp + Supertonic).
- the **Dart API** — `lib/bithuman.dart`, `lib/bithuman_realtime.dart`,
  `lib/engine_registry.dart` (re-export of Layer 0).

---

## The app (`bithuman-app`)

A macOS Flutter app whose **single Flutter dependency** is this umbrella, pinned
to a **fixed commit** (so a push to the umbrella or either engine cannot change
the app's build). Its `bootstrap.sh` chains: `flutter pub get` (clones the umbrella
into the pub cache) → run the umbrella's bootstrap (libconverse + N-engine loop) →
stage the embody models into `macos/Assets/embody`.

The gallery is **registry-driven**: `kEngineRegistry` renders **one tab per
`EngineDescriptor`** — a 3rd engine ⇒ a 3rd tab with no new UI code. A card carries
its engine slug + avatar ref; pick → `BithumanAvatar.load(path, engine:…)` (frozen
wire contract) → `EngineRegistry.make` builds the engine; the install path gates on
the avatar manifest's `requires_engine_abi` vs `capabilities.requiresEngineAbi`.
Phase-1 runtime switching (teardown texture → rebuild with the new engineKind) is
preserved.

---

## Recipe: add a 3rd engine

A new engine (say `vivid`) slots in with **no change** to the umbrella's or app's
engine-specific code — only registration data:

1. **New repo `vivid`** with the identical structure
   (`engine/… inference/ training/ sdk/ tools/ docs/`). Its Apple engine package
   exposes a C ABI `be_vivid_*` (binary engine) or pure Swift (source engine) and
   publishes `libvivid.xcframework` to a sha-pinned release.
2. **`vivid/sdk/` (Layer 1, identical shape):**
   - `Classes/VividEngine.swift` conforming to `BithumanEngine` (override the
     widened zero-alloc surface if binary; nothing if source).
   - `include/be_vivid.h` (binary engines only).
   - `scripts/bootstrap.sh` — fetch + sha256-verify + extract `libvivid.a`.
   - `manifest.yaml` — `engineId{canonical: vivid, aliases:[…]}`, `capabilities`
     (pick a `driveModel` + the policy fields + `requiresEngineAbi`),
     `native{gate: VIVID_AVAILABLE, vendoredLib: libvivid.a, umbrellaHeader,
     release{…sha…}, resources[…]}`.
   - `Package.swift` depending on `bithuman-engine-protocol`.
3. **Register with the umbrella (this repo):** add a `stage_vivid` call to
   `scripts/bootstrap.sh`'s engine loop + one `EngineRegistryDescriptor` (and a
   `make` branch) to `shared/Classes/EngineRegistry.swift`. The podspec
   auto-picks `libvivid.a` (the `Dir.glob`), folds `be_vivid.h` into the umbrella,
   and sets `VIVID_AVAILABLE` — **INVARIANT #1 holds** (still only `libconverse`
   is a module-map xcframework; the assert proves it).
4. **Register with the app:** add `kVivid` to `kEngineRegistry` (Layer-0 Dart). The
   gallery grows a "Vivid" tab; load/route by slug; `AvatarTexture` drives it by
   `capabilities.driveModel`. If its drive model is one of the two existing ones,
   **zero** new plugin code; a genuinely new drive model adds one `case`.

**Done checklist:** protocol conformance compiles · `manifest.yaml` valid · binary
release sha-pinned · gate name unique · `driveModel` chosen · registry entry
(Swift + Dart) · one umbrella engine-list line. No edits to the other engines, the
brain, or the audio IO.

---

## Frozen contracts (never change across migrations)

- **Engine slugs** (dual-accept): `expression2`/`embody`, `essence2`/`elevate`.
- **Channel** `ai.bithuman.avatar` + method names (incl. dual-accept
  `setExpression2AgentDir`/`setEmbodyAgentDir`).
- **Formats** `.model` + `.avatar` (+ `requires_engine_abi`), `.elevatedir`, legacy
  `.imx`/`.lab`. **C ABI** `be_essence2_*` + `be_essence2.h` (BGR-no-swap), binary
  name `libessence2.*`.
- **The a2x render path** + the release pin `libessence2-v1.0-a2x` (both sha256s).
- **INVARIANT #1** — exactly one module-map xcframework per pod (`libconverse`);
  every engine core is a plain static `.a` with its header in the umbrella.
- **The app pin** — `bithuman-app` git-deps this umbrella at a fixed commit; the
  bootstrap chain stages `libconverse` + CoreML models + `libessence2.a`.
