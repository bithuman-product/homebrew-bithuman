// swift-tools-version: 6.0
// bitHuman — public SwiftPM distribution for Apple platforms.
//
// This package consumes pre-compiled XCFrameworks attached to THIS repo's
// GitHub Releases via SwiftPM's binaryTarget. Each `.xcframework.zip` is built
// from the private engine monorepo bithuman-product/bithuman-models and
// uploaded here per release; consumers depend only on this package URL.
//
// PROVENANCE NOTE: these frameworks were originally built from
// bithuman-product/bithuman-sdk-internal, which was ARCHIVED on 2026-06-30 and
// consolidated into bithuman-models (models/expression-2, models/essence-1,
// models/essence-2). Any bithuman-sdk-internal reference below is historical
// provenance, not a live path.
//
// ─────────────────────────────────────────────────────────────────────────────
// WHAT THIS PACKAGE ACTUALLY VENDS. Four products, and no others. Naming any
// other product fails at resolve time:
//     product 'Expression' ... not found in package 'homebrew-bithuman'
//
//   - bitHumanKit              binary umbrella, tag v2.4.0. `import bitHumanKit`.
//   - Expression2              expression-2 engine alone, tag v2.6.0.
//                              `import Expression2`. FOUR binaryTargets ride
//                              under it now, not three — see UnifiedModelHeader.
//   - Essence2                 essence-2 engine alone, archives on tag
//                              essence2-v1.4.0 — read `essence2Tag` below, never
//                              this sentence, for where the bytes are; it has
//                              been wrong before. `import Essence2` works since
//                              essence2-v1.2.0 (the archive's module map declares both
//                              `Essence2` and `CLibEssence2` over one header;
//                              `import CLibEssence2` still works). Two
//                              binaryTargets ride under it and BOTH are needed.
//   - BithumanEngineProtocol   source-only Layer-0 engine interface.
//                              `import BithumanEngineProtocol`.
//
// ★ THERE IS NO `Expression` PRODUCT AND NO `Bithuman` PRODUCT. Earlier
//   revisions of this header sent you to the modules `Expression` and
//   `Bithuman` "for the lower-level engine products" and then described both at
//   length. Neither has ever appeared in `products` below. The instruction was
//   unbuildable on the day it was written and it is deleted here rather than
//   softened. `Bithuman` is a TYPE — a public actor vended BY `bitHumanKit`
//   (`import bitHumanKit`, then `Bithuman.create(modelPath:)`); it is not a
//   module you can import and not a product you can attach in Xcode.
//
// ─────────────────────────────────────────────────────────────────────────────
// Products
//   - bitHumanKit  Full on-device voice + video chat SDK (umbrella).
//                  The Expression avatar engine + an `.imx` avatar runtime +
//                  the on-device LLM/TTS stack. Most apps want this one.
//                  `import bitHumanKit`.
//                  ★ IT DOES NOT CONTAIN libessence, AND IT NEVER SAID SO
//                  TRUTHFULLY. This block used to read "re-exports … the Essence
//                  (libessence) runtime". MEASURED 2026-08-29 and RE-MEASURED
//                  2026-09-03 against the exact published asset
//                  (bitHumanKit.xcframework.zip @ v2.4.0, sha256 5c536e37…e9db,
//                  the value the binaryTarget below pins, re-downloaded and
//                  re-hashed): the framework binary is a static archive of 28
//                  objects — bitHumanKit.o, MLX*, HuggingFace, Tokenizers,
//                  Crypto, yyjson — and NOT ONE of them is libessence,
//                  libelevate or onnxruntime.
//                  `strings -a` on the ios-arm64 slice, 2026-09-03, counts:
//                      ImxContainer 141 · bitHumanKit 12715 · mlx 104937 ·
//                      Expression 3353 · Bithuman 1663 · CoreML 433
//                      essence 0 · Essence 0 · libessence 0 · tessera 0 ·
//                      elevate 0 · onnxruntime 0
//                  (`strings -a`, not `grep`: without -a, grep silently reads 0
//                  on a binary and every one of those counts would be a lie in
//                  the safe direction. Read with a control that fires.)
//                  The public .swiftinterface declares no Essence type. What is
//                  really there is a Swift-side `ImxContainer` reader reached via
//                  `Bithuman.create(modelPath:)`. The `Bithuman` ACTOR is real;
//                  "the portable libessence C++ runtime" was not.
//   - Expression2  Layer-1 expression-2 avatar engine, pure Swift + CoreML.
//                  Published at tag v2.6.0 (see `expression2Tag` below).
//                  `import Expression2`, then `Expression2Engine.create(modelPath:)`.
//                  ★ CODE ONLY — NO MODEL WEIGHTS, AND THAT PART IS UNCHANGED.
//                  What DID change at v2.6.0: the engine can now be GIVEN a model.
//                  Through v2.5.0 the only initializer was `Expression2Engine()`,
//                  which took no model path — it searched $BITHUMAN_EXPRESSION2_DIR
//                  or the app bundle and left `isReady` false when it found
//                  nothing, so a consumer that had DOWNLOADED an avatar had no way
//                  to point the engine at it. v2.6.0 adds
//                  `Expression2Engine.create(modelPath:sharedEngineDir:warmSpeech:)`,
//                  the instance `load(modelPath:…)`, and the container opener
//                  `Expression2Container.members(of:)` with
//                  `Expression2LoadError.notAnAvatarDirectory(path:)`.
//                  MEASURED on the two zips themselves, ios-arm64 slice, aggregated
//                  over all nine emitted .swiftinterface files
//                  (`grep -F -o`, with warmUp / isReady / "func pull" /
//                  "public init()" as controls that FIRE 9 each on BOTH, and a
//                  nonsense token reading 0 on both):
//                      token                   v2.5.0   v2.6.0
//                      create(modelPath             0        9
//                      Expression2Container         0       45
//                      notAnAvatarDirectory         0        9
//                  Still no avatar bundle is published, so this product does not
//                  render out of the box; it can now be handed one.
//   - Essence2     Layer-1 essence-2 engine for Apple platforms (iOS device,
//                  iOS Simulator, macOS — all arm64). Its archives ship on tag
//                  essence2-v1.4.0; `essence2Tag` below is the value that
//                  decides, and this line is a copy of it that has drifted once.
//                  ★ TWO MODULE NAMES, ONE HEADER. What this product vends is
//                  the engine's 15-function C interface, not a Swift type. Since
//                  essence2-v1.2.0 the module map in every slice declares BOTH
//                  `Essence2` (the product's own name) and `CLibEssence2` (the
//                  original), so `import Essence2` and `import CLibEssence2`
//                  reach the same declarations — see the essence-2 section
//                  above for the whole shape, including what linking does NOT
//                  give you.
//   - BithumanEngineProtocol
//                  Layer-0 common engine interface, pure Swift SOURCE. Consumed
//                  by the engine SDKs in bithuman-models for their standalone
//                  builds. ★ HAZARD, measured (arm C3, exit 1): a consumer that
//                  depends on BOTH this product AND `Expression2` gets the module
//                  twice and fails to link — `Expression2` already carries a
//                  BINARY copy. Depend on `Expression2` alone. See the note on
//                  the `Expression2` product below for why both must exist.
//
// ─────────────────────────────────────────────────────────────────────────────
// ★ essence-2 IS ON THIS RAIL AS OF 2026-09-06. What stood here said "essence-2
//   IS NOT ON THIS RAIL … To reach essence-2 from an Apple app TODAY: the REST
//   API, a LiveKit session, or — on macOS only — the Python wheel. Not this
//   package." That was true on the day it was written and it is false now, so it
//   is deleted rather than softened. Release `essence2-v1.1.0` publishes the
//   Apple engine archives world-readably — fetched with no credentials on
//   2026-09-06, HTTP 200 for both, against a nonexistent asset on the same
//   release that returns 404 — and the `Essence2` product below points at them.
//
//   ★ THE PRODUCT IS `Essence2`, AND SINCE essence2-v1.2.0 SO IS A MODULE.
//   Through v1.1.0 the archive vended ONE Clang module, `CLibEssence2`, and a
//   reader who assumed the module matched the product got
//   `no such module 'Essence2'`. v1.2.0's module map (carried INSIDE every
//   slice of the xcframework, measured by scripts/check-manifest-truth.py R3
//   out of the downloaded bytes) declares a second module, `Essence2`, over the
//   same header, so the two lines you write now agree — and the old spelling
//   is unchanged:
//
//       .product(name: "Essence2", package: "homebrew-bithuman")   // Package.swift
//       `import Essence2`                                          // your Swift
//       `import CLibEssence2`                                      // still works
//
//   Either import gives you the engine's C interface: 15 `be_essence2_*`
//   functions declared in Headers/be_essence2.h. Nothing else.
//
//   ★ THERE IS NO SWIFT `Essence2Engine` TYPE ON THIS RAIL, and that is an
//   omission on purpose. A Swift adapter of that name exists in the private
//   engine monorepo, where it is `internal` and is NOT inside these archives.
//   Publishing it here would be inventing an API rather than shipping one.
//   Write your own wrapper over `CLibEssence2`.
//
//   ★ TWO binaryTargets, AND THE SECOND IS NOT OPTIONAL — the same shape as
//   UnifiedModelHeader riding under `Expression2`. The engine archive leaves
//   every ONNX Runtime symbol undefined; they resolve at YOUR app's final link.
//   MEASURED 2026-09-06 on macOS 26.6.2 / Xcode 26.4.1, two arms of one scratch
//   consumer that differ by a single target dependency:
//       libessence2 + onnxruntime   `swift build` exit 0, `Linking` succeeds,
//                                   and `xcodebuild -destination
//                                   'generic/platform=iOS'` BUILD SUCCEEDED
//       libessence2 alone           `swift build` exit 1
//                                     Undefined symbols for architecture arm64:
//                                       "_OrtGetApiBase", referenced from: …
//                                       in libessence2.a
//   A product carrying only the engine therefore RESOLVES cleanly and then dies
//   at link, which is the failure mode worth naming: a green `swift package
//   resolve` is not a build.
//
//   ★ WHAT LINKING DOES NOT BUY YOU. The runtime resources this engine loads at
//   startup — its Metal library, the idle audio, and the audio encoder — are
//   attached to the release as `libessence2-resources.zip` (231,597,193 B,
//   sha256 94ce2120…, and MEASURED 2026-09-09 byte-identical on the tag this
//   manifest points at, essence2-v1.4.0, as on essence2-v1.2.0 — both streamed
//   anonymously and hashed, same 231,597,193 B and same digest)
//   but they are NOT a binaryTarget: SwiftPM cannot ship loose resource bundles
//   through this product. Linking succeeds without them; starting a session
//   does not. Your app must place those bundles in its own Resources, so
//   `Essence2` alone is a build-time coordinate, not a running avatar.
//
//   ★ AND NO MODEL YOU CAN DOWNLOAD TODAY OPENS IN THIS ENGINE — which is the
//   limit that decides whether essence-2 on a phone is usable at all, and it
//   is NOT a repack a consumer can do. MEASURED 2026-09-09, both sides:
//     · WHAT THE DOWNLOAD ENDPOINT RETURNS. `GET
//       /v1/agent/{code}/model/download?model=essence-2` (account api-secret)
//       returned, for one live identity, a single `IMX\0` v2 CONTAINER FILE of
//       99,536,068 B. Read out of the container's own member index: 27
//       members, `manifest.json` declares `"format": "le-bundle-v0"`, four
//       members are `.onnx` graphs (`model_b24_fp32.onnx` among them), and
//       ZERO are CoreML `.mlpackage`s. That artifact is what the SERVER reads.
//     · WHAT THIS ENGINE ACCEPTS. `strings -a` on the ios-arm64 slice of the
//       `libessence2.xcframework.zip` pinned below (essence2-v1.4.0,
//       158,661,991 B, re-downloaded anonymously and re-hashed to the exact
//       `binaryTarget` checksum 75b1919b…) carries its opener's refusal
//       verbatim —
//           Essence2Bundle: … is not a .elevatedir/.essence2dir bundle (need a
//           directory with meta.json {"format":"elevatedir-v*" |
//           "essence2-light-dir-v*"})
//       — beside the CoreML members it wants: `MotionExtractor.mlpackage`,
//       `WarpDecode_student.mlpackage`, `DenseMotionConvs_student.mlpackage`.
//       It opens a DIRECTORY of CoreML packages; the endpoint hands you one
//       container file of ONNX graphs. Two runtimes, not two spellings of one.
//   ⟹ `Essence2` resolves, links and starts, and the only package it opens
//   today is one you produce yourself. Publishing a per-identity on-device
//   package is an owner decision plus a re-publish, not a client workaround.
//   The single source for what is and is not true on this rail is
//   https://docs.bithuman.ai/sdk/swift — this block points at it rather than
//   growing a second copy that drifts.
//
//   ★ NO *MODULE* CLASH, BUT A REAL *SYMBOL* CLASH — AND THIS BLOCK USED TO
//   SAY "Depend on it alongside either of the others", WHICH IS FALSE ON THE
//   iOS DEVICE AND ON macOS. The module half is still true: `Essence2` carries
//   no Swift module (both of its modules are Clang modules over one C header),
//   so it cannot be taken twice. The LINK half was never checked, and it fails.
//
//   MEASURED 2026-09-08 on the published bytes of `essence2-v1.4.0` +
//   `v2.6.0`, four arms of ONE executable link that differ by one flag or one
//   slice (tools/check-essence2-expression2-link.sh reproduces all four):
//
//       slice                 UnifiedModelHeader.framework   rc   duplicate symbols
//       ios-arm64             linked                          1   116
//       ios-arm64             NOT linked                      0     0   <- control
//       macos-arm64           linked                          1   116
//       ios-arm64-simulator   linked                          0     0   <- control
//
//       duplicate symbol 'type metadata for UnifiedModelHeader.EngineResolver' in:
//           …/UnifiedModelHeader.xcframework/ios-arm64/UnifiedModelHeader[2](UnifiedModelHeader.o)
//           …/libessence2.xcframework/ios-arm64/libessence2.a[4](EngineResolver.o)
//
//   WHY. `libessence2.a` is libtool'd from the engine's whole library closure,
//   and that closure INCLUDES the UnifiedModelHeader objects. `nm -g` on the
//   published archives counts UnifiedModelHeader symbols DEFINED in every
//   slice — ios-arm64 317, ios-arm64-simulator 317, macos-arm64 321 — against
//   122 defined by `UnifiedModelHeader.xcframework` itself and 0 for a
//   nonsense control token. The `Expression2` product forces every consumer to
//   link that framework (it is in the product's `targets:` below, and it must
//   be: the engine's .swiftinterface imports the module). So
//   `Expression2` + `Essence2` in one app is a link failure on the device.
//
//   ★ A GREEN `swift build` DOES NOT SEE THIS, and neither does the package
//   matrix a CI usually runs: a library TARGET is compiled, never linked, so
//   `xcodebuild -destination 'generic/platform=iOS' build` on a package that
//   takes BOTH products exits 0. The collision only fires at an APP's final
//   link. Nor does a Simulator-only CI see it — the simulator arm above is
//   green on bytes that carry the same 317 definitions.
//
//   ★ THE WORKAROUND UNTIL THE ENGINE IS REBUILT: link `Expression2` and
//   `Essence2` and do NOT let `UnifiedModelHeader.framework` reach the final
//   link (an Xcode target can drop it; a pure-SwiftPM app cannot, because the
//   product list below carries it). The ROOT fix is in the engine build —
//   `models/essence-2/engine/light/apple/build-xcframework.sh` must stop
//   libtool'ing the UnifiedModelHeader objects into the archive, and the
//   `Essence2` product must then take the `UnifiedModelHeader` binaryTarget so
//   an Essence2-only consumer still resolves — and it needs a republish.
//
//   The one NAME `Essence2` can still collide with is a Swift module also
//   called `Essence2` in your own graph — the private engine repository has
//   one — so do not link both.
//
//   ★ AND THE SIMULATOR SLICES ARE arm64-ONLY. `Expression2`,
//   `UnifiedModelHeader` and `BithumanEngineProtocol` publish
//   `ios-arm64-simulator`; `onnxruntime` publishes a fat
//   `ios-arm64_x86_64-simulator`. A default `xcodebuild -destination
//   'generic/platform=iOS Simulator'` also builds x86_64 and therefore fails —
//   as `error: unable to resolve module dependency: 'Expression2'`, which
//   reads like a broken package rather than "Apple Silicon only". MEASURED
//   2026-09-08: the same command with `ARCHS=arm64` is BUILD SUCCEEDED.
//
//   ★ AND THE `platforms:` FLOOR BELOW IS NOT THE FLOOR THESE OBJECTS WERE
//   BUILT FOR. Linking the published essence-2 archive at the declared floor
//   makes `ld` warn on every object:
//       object file (libessence2.xcframework/ios-arm64/libessence2.a[6](ANEDecoder.o))
//         was built for newer 'iOS' version (26.0) than being linked (17.0)
//       object file (libessence2.xcframework/macos-arm64/libessence2.a[2](le_bundle.cpp.o))
//         was built for newer 'macOS' version (26.0) than being linked (14.0)
//   The manifest declares `.macOS(.v13), .iOS(.v16)`; the essence-2 objects are
//   iOS 26.0 / macOS 26.0. Build essence-2 consumers at 26.0.
//
// ─────────────────────────────────────────────────────────────────────────────
// Hardware floor for the two bitHumanKit engines (gated at runtime via
// HardwareCheck.evaluate(), which refuses politely below it — NOT by the
// `platforms:` floor below, which is deliberately lower, see the note there):
//   macOS:   M3+ Apple Silicon, macOS 26 (Tahoe)
//   iPad:    iPad Pro M4+, 16 GB unified memory, iPadOS 26
//   iPhone:  iPhone 16 Pro+ (A18 Pro), iOS 26
// ★ That floor grades bitHumanKit AND `Essence2` ON iOS — NOT `Expression2`.
//   Expression2 is a separate binary with its own CoreML requirements and is
//   not gated by HardwareCheck; this block used to say the floor graded
//   bitHumanKit ONLY, and that is false for essence-2 on a phone. MEASURED
//   2026-09-08 on an iPhone 15 (iPhone15,4, iOS 26.6.1) running an app built
//   from these exact published slices: `be_essence2_create` returns 0, and
//   then the warm-up refuses —
//       [Essence2SyncEngine] runtime warm-up FAILED: DirectorRuntime:
//       ExpressionAvatar.create: Bithuman.create: unsupported hardware —
//       iPhone15,4 detected — bitHuman iOS SDK requires iPhone 16 Pro or later
//       (A18 Pro+). — engine stays idle-only
//   because the essence-2 engine creates the Expression actor, which runs the
//   same `hw.machine` gate. There is no environment override. On iPhone,
//   essence-2 therefore needs an iPhone 16 Pro+ (A18 Pro), same as bitHumanKit.
//   Expression2 has no such gate and was measured rendering 245 frames on that
//   same iPhone 15 the same night.
//
//   ★ AND IT IS NOT ONLY A PHONE GATE — macOS IS GATED TOO, WHICH THIS BLOCK
//   DID NOT SAY. "Grades … ON iOS" reads as if a Mac were ungated; it is not.
//   MEASURED 2026-09-09 with `strings -a` on the three published slices of the
//   essence2-v1.4.0 archive pinned below (re-downloaded anonymously, re-hashed
//   to 75b1919b…), one row per refusal sentence, nonsense control 0 in every
//   pass:
//
//       refusal, verbatim                                  ios  macos  sim
//       "bitHuman requires Apple M3 or later on macOS."       0      2    0
//       "bitHuman requires Apple Silicon (M3 or later)."      0      2    0
//       "…an iPad with M-series Apple Silicon (iPad Pro
//        2021 or later, iPad Air 2022 or later)."            2      0    0
//       "…requires iPhone 16 Pro or later (A18 Pro+)."       2      0    0
//       "…requires an A18 Pro chip (iPhone 16 Pro/Pro Max)"  2      0    0
//       nonsense control                                     0      0    0
//
//   Each slice carries only the refusals that can fire on it, the generic
//   `Bithuman.create: unsupported hardware ` prefix is in ALL THREE, and the
//   SIMULATOR carries none of the specific sentences — so a Simulator run
//   never tells you the device is under-spec. Read as a floor for `Essence2`:
//   macOS needs Apple Silicon M3+; iPad needs M-series (iPad Pro 2021+ /
//   iPad Air 2022+, which is LOWER than bitHumanKit's iPad Pro M4+); iPhone
//   needs a 16 Pro / Pro Max, and a standard A18 is refused by name.
//
//   ★ AND `Expression2` REALLY HAS NO GATE — measured on its OWN archive
//   rather than inherited from this paragraph: `unsupported hardware`,
//   `HardwareCheck`, `A18` and `iPhone 16` all read 0 in all three slices of
//   Expression2.xcframework.zip (d4ce14b6…), against controls that fire in the
//   same read (`Expression2` 1106-1108, `CoreML` 24-26) and a nonsense token
//   at 0.
//
// ★ AND THE iOS SIMULATOR CANNOT STAND IN FOR THE PHONE FOR essence-2. The
//   documented behaviour there is a graceful typed refusal ("the elevate engine
//   runs idle-only here"). MEASURED 2026-09-08 on the iOS 26.4 simulator with
//   these slices: `be_essence2_create` returns 0 and the process then ABORTS —
//   `NSInvalidArgumentException … object cannot be nil` inside
//   `+[MPSGraphDevice deviceWithMTLDevice:]`, reached from
//   `Essence2Director.Conv3DFast.init` <- `StudentDirector.init(bundle:)`
//   <- `DirectorRuntime.init` <- `Essence2SyncEngine.warmUp`. That call chain
//   reaches MPSGraph before the actor's simulator guard. Expression2 renders
//   on the simulator normally.
//
// RELEASE NOTE:
//   `bitHumanKit` (the umbrella, tag v2.4.0) and `Expression2` + its binary
//   `BithumanEngineProtocol` + `UnifiedModelHeader` (tag v2.6.0) ship today.
//   ★ FOUR binaryTargets below now, not three, and the fourth is not optional:
//   line 14 of the engine's emitted .swiftinterface is an import OF the module
//   UnifiedModelHeader (the engine registers itself in the shared
//   EngineLoaderRegistry), so a consumer taking only the v2.5.0 pair dies at
//   import with `no such module 'UnifiedModelHeader'`. ★ It is a binaryTarget,
//   NOT a product, and that is deliberate: nobody writes that import by hand —
//   it rides under the `Expression2` library product and must merely be
//   RESOLVABLE when the compiler reads the engine's interface. Every one of the four was re-fetched
//   and re-hashed against the checksum it pins — the three v2.6.0 checksums came
//   out of the `.sha256` sidecars the build wrote, never from a human, and
//   bitHumanKit's is UNCHANGED at 5c536e37… (bumping the shared `releaseTag`
//   would 404 the shipping product; see the block above `expression2Tag`).
//   essence-2's two linkable archives ship on `essence2Tag`, and their
//   checksums came out of the `.sha256` sidecars the same way — see the note
//   above that constant for what those sidecars do and do not contain.
//   Nothing else ships. There is no pending `Expression` or `Bithuman`
//   per-product zip: the release flow can emit one
//   (scripts/build-binary-xcframework.sh; `swift package compute-checksum
//   <zip>` yields the value), but until a release actually uploads it, do not
//   describe it here as if a consumer could reach it. See
//   scripts/validate-release.sh and docs/RELEASE_MATRIX.md.
//
// ★ VERIFY THIS MANIFEST RATHER THAN TRUSTING IT: scripts/check-manifest-truth.py
//   fetches every binaryTarget URL, checks its sha256 against the pinned
//   checksum, and cross-checks the token claims in these comments against
//   `strings -a` on the downloaded binaries. `--prove-by-mutation` runs six
//   mutation arms and requires every one of them to turn the guard RED.
import PackageDescription

// Pin the binary slice to a release tag.
let releaseTag = "v2.4.0"
let releaseBase = "https://github.com/bithuman-product/homebrew-bithuman/releases/download/\(releaseTag)"


// ---------------------------------------------------------------------------
// Expression 2 ships on its OWN tag, and that is a defect fix, not a style
// choice. `releaseBase` above is shared by EVERY binaryTarget in this manifest,
// so bumping `releaseTag` to the Expression 2 release re-points
// bitHumanKit.xcframework.zip at a tag that does not carry it.
//
// MEASURED 2026-08-26, against the real repo: taking the live Package.swift,
// bumping releaseTag 2.4.0 -> 2.5.0 and adding the Expression2 target, then
// fetching every URL the result declares:
//     bitHumanKit  .../download/v2.5.0/bitHumanKit.xcframework.zip   HTTP 404
//     Expression2  .../download/v2.5.0/Expression2.xcframework.zip   HTTP 404
// The FIRST line is the one that matters: that is the SHIPPING product, and the
// documented release plan (RELEASE.md §5, "bump `releaseTag`, add the two
// binaryTargets") would have taken it down for every existing consumer.
//
// A separate constant cannot do that. SwiftPM resolves the PACKAGE at whatever
// tag the consumer's `from:` picks and then reads absolute URLs out of the
// manifest it finds there — the asset does not have to live on the resolved tag.
// ---------------------------------------------------------------------------
let expression2Tag = "v2.6.0"
let expression2Base = "https://github.com/bithuman-product/homebrew-bithuman/releases/download/\(expression2Tag)"


// ---------------------------------------------------------------------------
// essence-2's archives ship on a tag of their own for exactly the reason
// Expression 2's do: `releaseBase` is shared by every binaryTarget above it, so
// bumping it re-points a SHIPPING product at a tag that does not carry its
// asset. The tag here is not semver — `essence2-v1.1.0` — and that is fine,
// because SwiftPM resolves the PACKAGE at whatever tag the consumer's version
// pin picks and then reads ABSOLUTE URLs out of the manifest it finds there.
// The asset does not have to live on a resolvable tag; it only has to exist.
//
// ★ THE CHECKSUM CONVENTION, BECAUSE IT HAS FOOLED A GATE BEFORE. The value a
// `.binaryTarget` verifies is what `swift package compute-checksum <zip>`
// prints: the bare sha256 of the archive bytes, 64 hex characters and nothing
// else. `shasum -a 256 <zip>` prints the SAME digest but in a two-field form,
// `<digest>  <filename>`, and a sidecar written that way cannot be pasted into
// the field below. MEASURED 2026-09-06 on macOS 26.6.2 / Xcode 26.4.1: the two
// `.sha256` sidecars attached to essence2-v1.1.0 are 65 bytes each — 64 hex
// plus one newline, the BARE form — and `swift package compute-checksum` on the
// anonymously downloaded zips reproduces both digests exactly. So these
// sidecars are directly usable and `shasum -c` on them is not: the file names
// they would need are not in them.
//
// ★ ROLLED TO essence2-v1.4.0 ON 2026-09-07 — A REJECTED KEY GETS 300 s, THEN THE
// ENGINE STOPS. Owner ruling 2026-09-07: a credential the metering service
// REJECTS (HTTP 401 / 402 / 403) renders for a grace of 300 s from the first
// rejection behind a countdown line, is re-checked every minute, and at 300 s
// of continuous rejection the engine stops — `be_essence2_pull_frame` and
// `be_essence2_idle_frame` return -3 from then on. A meter that cannot be
// REACHED still never stops a render. Through essence2-v1.3.0 a rejected key
// logged `refused 401 … This render CONTINUES` once a minute for as long as
// the session ran. v1.4.0 (158,661,991 B, checksum 75b1919b…, built from
// bithuman-models b71d71679 on alpharetta) carries the grace in
// Sources/Essence2/SelfHostMeter.swift; the 26-test meter suite was shown to
// go RED under twelve mutations (tools/prove-meter-tests-can-fail.py, arms
// G1-G4 for the grace) before the archive was cut, and the two gates
// (check-libessence2-fails-closed.sh, check-libessence2-meters.sh) read 0 on
// these exact bytes. Billing is unchanged from v1.3.0. `onnxruntime` and
// `libessence2-resources` are carried forward BYTE-IDENTICAL from
// essence2-v1.3.0 (each sidecar re-computed before upload), so their
// checksums below do not move.
//
// ★ THE PREVIOUS ROLL, essence2-v1.3.0 ON 2026-09-07 — THE FIRST APPLE ENGINE THAT BILLS
// THE SESSION IT SERVES. docs.bithuman.ai/guides/pricing tells the customer a
// self-hosted essence-2 session is metered at the published rate (2 credits per
// MINUTE of session wall-clock, idle animation included). Through
// essence2-v1.2.0 this engine sent NOTHING: measured on that published archive
// (sha256 4371321f…, re-downloaded anonymously and re-hashed),
// `v1/auth/validate` 0 · `selfhost-meter` 0 · `self-hosted-essence-2-model` 0 ·
// `BITHUMAN_UNMETERED` 0 in the macos-arm64 slice, against `apiSecret` 10 /
// `Essence2Avatar` 18 as controls that fire and a nonsense token at 0.
// `Essence2Avatar.create(labPath:chunk:apiSecret:)` took the credential and its
// first line threw it away.
//
// v1.3.0 (158,639,628 B, sha256 2f3c3672…, built from bithuman-models
// 7c5e4d5a6 on alpharetta) carries `Sources/Essence2/SelfHostMeter.swift`: the
// same contract as the CLI's meter.rs and the Linux selfhost_meter.py — 60 s
// cadence plus a stop-flush, wall-clock `served_s` from READY, one ledger row
// per session, a failed beat re-claimed and never doubled, FAIL-OPEN with a
// loud `★ UNMETERED RENDER` line, `BITHUMAN_METER_ENFORCE` to make it a
// refusal and `BITHUMAN_UNMETERED` as the lab escape. Re-measured on the
// PUBLISHED archive, all three slices identical: `v1/auth/validate` 2 ·
// `selfhost-meter` 2 · `self-hosted-essence-2-model` 4 ·
// `BITHUMAN_METER_ENFORCE` 4 · `BITHUMAN_UNMETERED` 2 · `billing_type` 2, with
// `apiSecret` now 42 (was 10), `Essence2Avatar` 20 and the nonsense token 0.
//
// ★ AND `strings` CANNOT SEE THE WHOLE BEAT, WHICH IS WHY THE GATE DOES NOT ASK
// IT TO. `served_s`, `install_id`, `Bearer ` and even `v1/meter/beats` all score
// 0 in these archives — every one of them is ≤ 15 UTF-8 bytes, so Swift stores
// it INLINE in the String struct and there is no literal in the binary to find.
// A gate that required them would be red on a perfectly metered engine, and a
// probe that reported them as absent would be reporting its own blindness.
// `tools/check-libessence2-meters.sh` requires only the tokens that are really
// there and proves its controls fire in the same command.
//
// `onnxruntime` and `libessence2-resources` are carried forward BYTE-IDENTICAL
// from essence2-v1.2.0 (verified by re-computing each sidecar before upload),
// so the `onnxruntime` checksum below does not move.
//
// ★ THE PREVIOUS ROLL, essence2-v1.2.0 ON 2026-09-06 (same convention). The
// engine archive is REBUILT (158,440,195 B, sha256 4371321f…, from
// bithuman-models 10a30f097): it applies one rule for when a model renders on
// every platform — all four of the model's recorded-mouth files present, or a
// refusal that names the missing one — where v1.1.0 read a descriptive manifest
// block instead and refused complete packages that lacked it. It also declares
// the `Essence2` module (see the essence-2 section). `onnxruntime` is
// byte-identical to v1.1.0 and its checksum below does not move. Re-fetched
// anonymously after upload and re-hashed; the sidecars are again 65 bytes.
// ---------------------------------------------------------------------------
let essence2Tag = "essence2-v1.4.0"
let essence2Base = "https://github.com/bithuman-product/homebrew-bithuman/releases/download/\(essence2Tag)"

let package = Package(
    name: "bithuman",
    platforms: [
        // Floor lowered to host the source-only BithumanEngineProtocol product,
        // which the engine SDKs (bithuman-models models/expression-2/sdk,
        // models/essence-2/sdk) consume at
        // macOS 13 / iOS 16. bitHumanKit's real macOS-26 floor is enforced at
        // runtime via HardwareCheck.evaluate() (a polite refusal below it), not
        // by the package manifest. (Consolidated from bithuman-engine-protocol +
        // bithuman-sdk-public, 2026-06-30.)
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(name: "bitHumanKit", targets: ["bitHumanKit"]),
        // Layer-0 common engine interface (pure Swift source). Consumed by the
        // engine SDKs for their standalone builds + staged into the Flutter pod.
        .library(name: "BithumanEngineProtocol", targets: ["BithumanEngineProtocol"]),
        // Layer-1 Expression 2 avatar engine on its own: pure Swift + CoreML
        // on-device talking head. Apple Silicon only (the engine's
        // MLShapedArray<Float16> decode path does not compile for x86_64).
        // `import Expression2`, then `Expression2Engine()`.
        //
        // The MODULE is `Expression2`; the TYPE stays `Expression2Engine`. They
        // may not be equal or the distribution .swiftinterface cannot be verified.
        //
        // ★ WHY THIS PRODUCT CARRIES A **BINARY** BithumanEngineProtocol WHILE THE
        // SOURCE TARGET ABOVE STAYS EXACTLY WHERE IT IS. Both are load-bearing and
        // they are load-bearing for DIFFERENT consumers:
        //   • the SOURCE target is what `models/expression-2/sdk` compiles in order
        //     to BUILD the next Expression2.xcframework. Delete it and the release
        //     cannot produce its own successor.
        //   • an OUTSIDE consumer cannot use that source target, because
        //     Expression2.xcframework is built BUILD_LIBRARY_FOR_DISTRIBUTION=YES
        //     and therefore references all 25 of the protocol's requirements
        //     RESILIENTLY, through method descriptors. A plain source build of the
        //     same file emits only 4 of them, so the other 21 are undefined at link:
        //       ld: symbol(s) not found for architecture arm64
        //       "method descriptor for BithumanEngineProtocol.BithumanEngine.pull(…)"
        //     MEASURED on macos-26, 2026-08-26, six arms: the source shape exits 1;
        //     the SAME source one flag apart (-enable-library-evolution) exits 0 and
        //     RUNS; nm counts 4 / 25 / 25 across plain, evolution, and the shipped
        //     framework. -enable-library-evolution cannot be the fix here — it needs
        //     .unsafeFlags, which SwiftPM forbids in a package consumed by version.
        // ★ HAZARD, and it is measured too: a consumer that depends on BOTH this
        //   product AND the `BithumanEngineProtocol` product gets the module twice
        //   and fails to link (arm C3, exit 1). Depend on `Expression2` alone.
        .library(name: "Expression2", targets: ["Expression2Binary", "BithumanEngineProtocolBinary", "UnifiedModelHeaderBinary"]),
        // Layer-1 essence-2 engine for Apple platforms: a static C library with
        // ios-arm64, ios-arm64-simulator and macos-arm64 slices, plus the ONNX
        // Runtime build its audio head needs at link. `import Essence2` — and
        // `import CLibEssence2` still works, because since essence2-v1.2.0 the
        // module map declares both names over the one header. (This comment
        // said the module name is NOT the product name. That was true through
        // v1.1.0 and is false now, so it is corrected rather than softened.)
        // See the essence-2 section in the header for the whole shape, for why
        // the second target is not optional, for the model format this engine
        // opens, and for the runtime resources this does not give you.
        .library(name: "Essence2", targets: ["libessence2", "onnxruntime"]),
    ],
    targets: [
        .binaryTarget(
            name: "bitHumanKit",
            url: "\(releaseBase)/bitHumanKit.xcframework.zip",
            checksum: "5c536e37919b693591dff234db8627c01952ae24ae58651aeacbd875bd78e9db"
        ),
        // Protocol was authored for swift-tools 5.9; pin it to Swift 5 language
        // mode so the package-wide 6.0 toolchain doesn't impose Swift 6 strict
        // concurrency on it (its EngineCapabilities statics aren't Sendable-clean
        // — unchanged from the standalone engine-protocol repo).
        .target(
            name: "BithumanEngineProtocol",
            path: "Sources/BithumanEngineProtocol",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "BithumanEngineProtocolTests",
            dependencies: ["BithumanEngineProtocol"],
            path: "Tests/BithumanEngineProtocolTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // ★ THE THREE BINARY TARGETS BELOW ARE NAMED `…Binary`, AND THE SUFFIX IS
        // LOAD-BEARING — IT IS NOT A STYLE. A target name must be unique across
        // the WHOLE package graph, not just this manifest, and the two packages
        // that BUILD these modules from source take this package as a dependency
        // (bithuman-models models/expression-2/sdk declares target `Expression2`,
        // models/_shared/swift/UnifiedModelHeader declares `UnifiedModelHeader`).
        // While the binary targets carried the bare module names, resolving that
        // graph died before a single file compiled:
        //     multiple packages ('homebrew-bithuman', 'sdk') declare targets with
        //     a conflicting name: 'Expression2'
        //     multiple packages ('homebrew-bithuman', 'unifiedmodelheader') …
        //     'UnifiedModelHeader'
        // — measured on echelon 2026-09-11, which is how the shipped
        // BithumanEngineProtocol.xcframework came to be built against a tap
        // revision four months stale: the only revisions that RESOLVED were the
        // ones predating these targets. `BithumanEngineProtocolBinary` already
        // carried the suffix for the same reason (its source twin is in THIS
        // manifest); the other two now do too.
        //
        // A consumer sees none of this: a target name is not a module name and
        // not a product name. The MODULE a developer imports comes from the
        // xcframework itself (`import Expression2`, `import UnifiedModelHeader`),
        // the PRODUCT is still `Expression2`, and the zip file names are
        // unchanged. Only the graph-local label moves.
        .binaryTarget(
            name: "Expression2Binary",
            url: "\(expression2Base)/Expression2.xcframework.zip",
            checksum: "d4ce14b6b9c463aa7310ca8200f59ded20931cc33f40b6c530eef13b5a40d326"
        ),
        .binaryTarget(
            name: "BithumanEngineProtocolBinary",
            url: "\(expression2Base)/BithumanEngineProtocol.xcframework.zip",
            checksum: "048a5d271d61fe4689dd9f1a6f209c00e358e4fd77aa249e55dc59dcd7051759"
        ),
        .binaryTarget(
            name: "UnifiedModelHeaderBinary",
            url: "\(expression2Base)/UnifiedModelHeader.xcframework.zip",
            checksum: "33b7d575ec90055a4894fb1fbbb507b9264694752c6a2a5e35c7bf8c069e180e"
        ),
        // The essence-2 engine itself. The target name matches the xcframework
        // inside the archive; the MODULES it vends are `CLibEssence2` and, since
        // essence2-v1.2.0, `Essence2`, both declared by Headers/module.modulemap
        // in every slice over the one header be_essence2.h.
        .binaryTarget(
            name: "libessence2",
            url: "\(essence2Base)/libessence2.xcframework.zip",
            checksum: "75b1919b848a0a8e13bdfe51999739813b610a42dad25d9fc5a3a4e408e29808"
        ),
        // Not optional, and not a convenience: without it the engine's ONNX
        // Runtime symbols are undefined at the app's final link (measured — see
        // the essence-2 section in the header). Re-hosted here unchanged so it
        // can be fetched without credentials.
        .binaryTarget(
            name: "onnxruntime",
            url: "\(essence2Base)/onnxruntime.xcframework.zip",
            checksum: "7d631c161ae0d9c6f01095bcb5556d0b4f0205dc5111e6d2ddae82cc7050a7ed"
        ),
    ]
)
