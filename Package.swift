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
//   - Expression2              expression-2 engine alone, tag v2.6.5.
//                              `import Expression2`. FOUR binaryTargets ride
//                              under it now, not three — see UnifiedModelHeader.
//   - Essence2                 essence-2 engine alone, archives on tag
//                              essence2-v1.11.0 — read `essence2Tag` below, never
//                              this sentence, for where the bytes are; it has
//                              been wrong before. `import Essence2` works since
//                              essence2-v1.2.0 (the archive's module map declares both
//                              `Essence2` and `CLibEssence2` over one header;
//                              `import CLibEssence2` still works). THREE
//                              binaryTargets ride under it since
//                              essence2-v1.10.0 and every one is needed — the
//                              third is UnifiedModelHeader, which the engine
//                              archive stopped carrying so that an app can take
//                              this product and `Expression2` at once.
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
//                  Published at tag v2.6.5 (see `expression2Tag` below).
//                  v2.6.4 (2026-09-23): a macOS APP can embed it. Through
//                  v2.6.3 every macOS slice was a SHALLOW framework, which
//                  `swift build` links and Xcode's app validation refuses
//                  ("the platform does not use shallow bundles") — a new
//                  macOS App-template project taking this product (or
//                  `Essence2`, which carries UnifiedModelHeader) was BUILD
//                  FAILED. The macOS slices are versioned bundles now; iOS and
//                  the simulator stay shallow. And a release build no longer
//                  writes probe files to /tmp or honours the engine's
//                  fault-injection variable. Public surface unchanged: the
//                  .swiftinterface files are identical to v2.6.3.
//                  v2.6.3 (2026-09-16): the idle clip plays whole, decoded in
//                  place — `idleLoop: [[UInt8]]` is DELETED from the public
//                  surface (a consumer naming it does not compile; take
//                  `idleNextPixelBuffer()` / `idle(into:)`), and
//                  `idleFrameCount` / `idleIndex` / `idleWraps` /
//                  `idleUnavailableReason` are added. `pullPos()` is the same
//                  4-tuple as v2.6.2. v2.6.2 was the first release since
//                  2.6.0 whose bytes moved (v2.6.1's engine was the v2.6.0
//                  archive re-hosted byte-for-byte; what was new on v2.6.1 was
//                  the pair of modules that ride under it — see the ★ …Binary
//                  note at the targets).
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
//                  essence2-v1.11.0; `essence2Tag` below is the value that
//                  decides, and this line is a copy of it that has drifted before.
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
//   attached to the release as `libessence2-resources.zip`, and they are NOT a
//   binaryTarget: SwiftPM cannot ship loose resource bundles through this
//   product. Linking succeeds without them; starting a session does not. Your
//   app must place those bundles in its own Resources, so `Essence2` alone is a
//   build-time coordinate, not a running avatar.
//
//   ★ THE ASSET IS WHOLE AGAIN ON essence2-v1.5.1, AND THERE IS NO LONGER A
//   TWO-RELEASE WORKAROUND. It was broken for six hours on essence2-v1.5.0 and
//   this is what the three archives hold, each read entry by entry:
//       essence2-v1.4.0  231,597,193 B   a2x_w2v.fp32.onnx (377,625,424 B) +
//                                        mlx.metallib, default.metallib,
//                                        idle.wav — at the archive root
//       essence2-v1.5.0    1,644,060 B   mlx.metallib, default.metallib,
//                                        idle.wav — and NO audio encoder, all
//                                        of it under a `libessence2-resources/`
//                                        folder the consumer then unzips INTO a
//                                        directory of that same name
//       essence2-v1.5.1   44,392,223 B   w2v_ess_fp16_v1.onnx (46,185,371 B,
//                                        sha256 7340a0350c34…) + the same three
//                                        files, byte-identical, at the archive
//                                        ROOT again. sha256 of the zip
//                                        5c2adf2473963be50523e691d6d5aaf5897bd6c6b860216571a7300828418a32
//   THE ENCODER IS NOT THE ONE v1.4.0 SHIPPED, AND THAT IS DELIBERATE. v1.4.0's
//   `a2x_w2v.fp32.onnx` is byte-for-byte the 377 MB fp32 8 s artifact
//   `models/MANIFEST.yaml` records as ROLLBACK ONLY under the owner ruling of
//   2026-07-06 ("large fp32 encoders forbidden on every surface"); v1.5.1
//   carries the BLESSED `essence2-shared-w2v-fp16-v1` instead — the encoder the
//   GPU workers and the Apple Neural Engine build already serve with, 8.2x
//   smaller.
//   MEASURED ON echelon (M-series, macOS 26.6.2), this manifest resolved at tag
//   v2.12.0 and the resources taken from v1.5.1, `$BH_A2X_W2V` and `$W2V_ONNX`
//   both unset so only the archive can answer:
//       no resources at all                    create rc=-2  CREATE_REFUSED
//       v1.5.0's archive, unpacked the way
//         the SDK bootstrap unpacks it         create rc=-2  CREATE_REFUSED
//       v1.5.1's archive, unpacked at the
//         binary's own resourcePath            create rc=0, the engine's
//                                              detail store live with 1024
//                                              sources, a2x ON
//                                              (w2v …/w2v_ess_fp16_v1.onnx),
//                                              151 frames at 1280x720
//   The first two arms are the control: the engine REFUSES without a frontend
//   rather than drawing a mouth the avatar never recorded.
//   YOU STILL HAVE TO PLACE THE FILES. Unzip `libessence2-resources.zip` at
//   your app's Resources root — the two `.bundle`s and the loose `.onnx` land
//   where `DirectorRuntime.resolveA2XW2VPath()` and MLX look. Nothing about
//   that changed; what changed is that the archive now contains all of it.
//   bithuman-models `apple-xcframework.yml` refuses to publish an archive
//   missing any resource the built engine names
//   (`tools/check-libessence2-resources-complete.py`).
//
//   ★ AND NO MODEL YOU CAN DOWNLOAD TODAY OPENS IN THIS ENGINE — which is the
//   limit that decides whether essence-2 on a phone is usable at all, and it
//   is NOT a repack a consumer can do. MEASURED 2026-09-09, both sides:
//     · WHAT THE DOWNLOAD ENDPOINT RETURNS. `GET
//       /v1/agent/{code}/model/download?model=essence-2` (API secret)
//       returned, for one live identity, a single packed CONTAINER FILE of
//       99,536,068 B. Read out of the container's own member index: 27
//       members, `manifest.json` declares `"format": "le-bundle-v0"`, four
//       members are `.onnx` graphs (`model_b24_fp32.onnx` among them), and
//       ZERO are CoreML `.mlpackage`s. That artifact is what the SERVER reads.
//     · WHAT THIS ENGINE ACCEPTS. `strings -a` on the ios-arm64 slice of the
//       `libessence2.xcframework.zip` of essence2-v1.5.0 (159,302,803 B,
//       re-downloaded anonymously and re-hashed to that release's
//       `binaryTarget` checksum a418a04c…; v1.5.1, pinned below, is a rebuild
//       of the same sources) carries its opener's refusal
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
//   ★ `Expression2` + `Essence2` IN ONE APP IS FIXED IN essence2-v1.10.0, AND
//   THE FIX IS TWO HALVES THAT ONLY WORK TOGETHER. Through essence2-v1.9.0 an
//   app that took both products could not link: `libessence2.a` was libtool'd
//   from the engine's whole library closure and that closure DEFINED the
//   UnifiedModelHeader symbols, while the `Expression2` product forces every
//   consumer to link `UnifiedModelHeader.xcframework` (it is in that product's
//   `targets:` below, and it must be — the engine's .swiftinterface imports the
//   module). `ld` exits 1 on the overlap:
//
//       duplicate symbol 'type metadata for UnifiedModelHeader.EngineResolver' in:
//           …/UnifiedModelHeader.xcframework/ios-arm64/UnifiedModelHeader[2](UnifiedModelHeader.o)
//           …/libessence2.xcframework/ios-arm64/libessence2.a[4](EngineResolver.o)
//
//   MEASURED 2026-09-21 on echelon (macOS 26.6.2 / Xcode 26.3), `nm -g` per
//   slice over the mangling prefix `_$s18UnifiedModelHeader`, defined only:
//
//       UnifiedModelHeader symbols   ios-arm64   ios-sim   macos-arm64
//       DEFINED by essence2-v1.9.0        247       247        247
//       DEFINED by essence2-v1.10.0         0         0          0
//       defined by the framework          118       118        118
//       ⟹ colliding                       112       112        112  ->  0
//       REFERENCED by v1.10.0              14         6         14
//       …of those NOT in the framework      0         0          0
//
//   and the same day, ELEVEN REAL APP LINKS through
//   tools/check-essence2-expression2-link.sh (which now runs both link shapes
//   on all three slices, and an Essence2-ONLY app besides):
//
//       app                    slice        load         v1.9.0        v1.10.0
//       Expression2+Essence2   ios-arm64    lazy         rc1 dup113    rc0
//       Expression2+Essence2   ios-arm64    force both   rc1 dup113    rc0
//       Expression2+Essence2   macos-arm64  lazy         rc0           rc0
//       Expression2+Essence2   macos-arm64  force both   rc1 dup113    rc0
//       Expression2+Essence2   ios-sim      lazy         rc0           rc0
//       Expression2+Essence2   ios-sim      force both   rc1 dup113    rc0
//       Essence2 alone         all three    force        rc0           rc0, 0 undefined
//
//   ★ AND THE SECOND HALF IS WHY THIS TOOK A REPUBLISH AND NOT A ONE-LINE
//   PATCH: once the archive stops DEFINING those symbols it REFERENCES them,
//   so an Essence2-ONLY app needs the framework too. That is exactly what the
//   `Essence2` product's `targets:` now carries. Ship one half without the
//   other and you trade 112 duplicate symbols for 14 undefined ones:
//       "static UnifiedModelHeader.EngineLoaderRegistry.shared.getter : …",
//         referenced from: libessence2.a[5](UnifiedEngineDispatch.o)
//   (measured, both slices, with the product change reverted).
//
//   ★ A GREEN `swift build` NEVER SAW ANY OF THIS, and neither does the package
//   matrix a CI usually runs: a library TARGET is compiled, never linked, so
//   `xcodebuild -destination 'generic/platform=iOS' build` on a package that
//   takes BOTH products exits 0. The collision only fires at an APP's final
//   link — and, as the table shows, only in some link shapes, so a single
//   passing app was never evidence either.
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
// ★★ THE iPHONE HALF IS SUPERSEDED FOR `Essence2` FROM essence2-v1.9.0 — read
//   this first. The iPhone 16 Pro refusal recorded below was measured on
//   essence2-v1.4.0 – v1.5.x. In the ios-arm64 slice of essence2-v1.10.0 (the
//   engine `essence2Tag` pins) the one remaining sentence reads, by `strings -a`
//   on 2026-09-23: "the expression-1 Expression actor (MLX DiT) requires iPhone
//   16 Pro or later (A18 Pro+). This gate is expression-1's alone: it is NOT a
//   bitHuman-SDK-wide device floor, and it does NOT apply to essence-2 or
//   expression-2, which carry no device gate." An iPhone 15 was measured
//   rendering Essence 2 at 1920x1080 (docs.bithuman.ai/sdk/performance). The
//   macOS slice still carries "requires Apple M3 or later" (1 occurrence), so
//   the Mac floor below stands. The history is kept because a project resolved
//   to an older tag still behaves the way it describes.
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
//   MEASURED 2026-09-11 with `strings -a` on the three published slices of the
//   essence2-v1.5.0 archive (re-downloaded anonymously, re-hashed
//   to a418a04c…), one row per refusal sentence, nonsense control 0 in every
//   pass — every count below is unchanged from the same reading of v1.4.0:
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
//   `BithumanEngineProtocol` + `UnifiedModelHeader` (tag v2.6.5) ship today.
//   ★ v2.6.1 EXISTS FOR ONE REASON: the archives on v2.6.0 named an
//   enterprise-only tier that no public artifact may name. Counted with
//   `strings -a` reading each file as raw bytes on stdin, V12+V13 over every
//   file of every slice: BithumanEngineProtocol 12 -> 0, UnifiedModelHeader
//   12 -> 0, Expression2 0 -> 0 (its archive was already clean, so its bytes
//   are re-hosted unchanged rather than rebuilt — no engine binary that has
//   not been run on a device ships in this release).
//   ★ FOUR binaryTargets below now, not three, and the fourth is not optional:
//   line 14 of the engine's emitted .swiftinterface is an import OF the module
//   UnifiedModelHeader (the engine registers itself in the shared
//   EngineLoaderRegistry), so a consumer taking only the v2.5.0 pair dies at
//   import with `no such module 'UnifiedModelHeader'`. ★ It is a binaryTarget,
//   NOT a product, and that is deliberate: nobody writes that import by hand —
//   it rides under the `Expression2` library product and must merely be
//   RESOLVABLE when the compiler reads the engine's interface. Every one of the four was re-fetched
//   and re-hashed against the checksum it pins — the three v2.6.1 checksums came
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
let expression2Tag = "v2.6.5"
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
// ★ ROLLED TO essence2-v1.5.1 ON 2026-09-11 — THE RESOURCES ARCHIVE IS COMPLETE
// AGAIN. v1.5.0 shipped a `libessence2-resources.zip` of 1,644,060 B against
// v1.4.0's 231,597,193 B: the shared audio frontend was GONE and the three
// survivors had moved under a `libessence2-resources/` folder. Neither is a
// story about the engine — both came from the packaging step that first emitted
// these zips from CI (bithuman-models c03149384): nothing on that runner ever
// staged a w2v where `build-xcframework.sh` looks, and `--keepParent`, which the
// xcframework archive REQUIRES, was copy-pasted onto the resources archive,
// which must not have it. v1.5.1 (44,392,223 B, sha256 5c2adf24…) carries the
// BLESSED 46 MB fp16 frontend at the archive root. Read the ★ block far above
// for the three measured arms.
// THE ENGINE IS A REBUILD OF THE SAME SOURCES, so its checksum DOES move:
// 159,302,911 B, checksum d95d0820…, built, tested and graded by
// bithuman-models `apple-xcframework.yml` at essence2-apple-v1.5.1 — the only
// `apple/` change between the two tags is `onnx_to_coreml.py`, a conversion
// tool that does not build the `.a`, and the four release gates (fails-closed,
// meters, no-internal-name, and now the resources gate) all read 0 on these
// exact bytes. Rendered on echelon before this release was pinned: create rc=0,
// the engine's detail store live with 1024 sources, 540 frames at 1280x720 from
// a 12 s clip, `$BH_A2X_W2V`/`$W2V_ONNX` unset. `onnxruntime` is carried forward
// BYTE-IDENTICAL, so its checksum below does not move.
//
// ★ THE PREVIOUS ROLL, essence2-v1.5.0 ON 2026-09-11 — THE PUBLISHED ARCHIVE NO LONGER
// NAMES AN ENTERPRISE-ONLY TIER. The engine's own bytes carried an internal
// tier name that no public artifact may carry, and every `swift package
// resolve` put it on a developer's disk; a developer-side verify is how it was
// found, not a gate here. v1.5.0 (159,302,803 B, checksum a418a04c…, built,
// tested and graded by bithuman-models `apple-xcframework.yml` at its tag
// essence2-apple-v1.5.0 — run on an M4 and an iPhone 15 before it was cut —
// and re-hosted onto this repo BYTE-FOR-BYTE by .github/workflows/publish-
// essence2-apple.yml, which refuses any file whose sha256 is not the graded
// measurement) reads 0. MEASURED with `strings -a`, each slice read as raw
// bytes on stdin, all three published slices of both archives, nonsense
// control 0 in every pass:
//
//       token                                       v1.4.0    v1.5.0
//                                                (per slice) (per slice)
//       the retired tier name, verbatim                  3         0
//       its alias family — the hyphen, underscore
//       and UPPERCASE spellings of that same tier       22         0
//
// NOTHING ELSE MOVED. The 300 s rejected-key grace described in the next
// block is still exactly what this engine does; the hardware refusals above
// re-measure identical, sentence for sentence, on these bytes; and
// `onnxruntime` is carried forward BYTE-IDENTICAL from essence2-v1.4.0, so
// its checksum below does not move. The RESOURCES asset is the one thing that
// changed on that tag and it changed WRONG; essence2-v1.5.1, above, is the fix,
// and it is what `essence2Tag` now points at.
//
// ★ THE PREVIOUS ROLL, essence2-v1.4.0 ON 2026-09-07 — A REJECTED KEY GETS 300 s,
// THEN THE ENGINE STOPS. Owner ruling 2026-09-07: a credential the metering service
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
// ★ ROLLED 2026-09-16 (evening) ONTO essence2-v1.8.0 — THE BARGE-IN THAT STOPS
// REWINDING THE DRIVER VIDEO. The owner reported it twice: "for essence-2 the
// interruption shouldn't rewind driver video to start — it should ride on the
// current frame and continue playing video continuously for continuity."
// bithuman-models #774 (main 6bed5ee7a) is the fix; essence2-v1.7.0 was cut
// about seven hours before that commit and carries the defect on every slice.
//
// `LeCoreSession.idleAdvance` used to copy `idleBGR` — driver frame 0, cached
// once at init — whenever the ring was empty, and `le_utt_interrupt` PURGES
// that ring by design, so a barge-in landed there every single time (measured:
// delivered si `55 56 57 [0] 58 59 60`, 3 frames / 150 ms per cut and up to 19
// frames / ~1 s at an utterance onset). It now returns 0 and the presenter
// rides on the frame it has; the plugin's own tick already reads
// `idle(into:) > 0` and holds otherwise.
//
// GRADED ON THE PUBLISHED SLICES, BOTH DIRECTIONS, before this line was
// written — the archive re-downloaded anonymously from the tap, re-hashed to
// 06be42fe… against its sidecar AND the checksum below, then read with `nm` +
// `objdump`; the same commands on essence2-v1.7.0 as the control:
//
//     read off the slice                             v1.7.0   v1.8.0
//     everDelivered ivar-offset symbol (Apple half)       0        2
//     idleBGR symbol  ← the reader's own control           2        2
//     le_a2x_reset sign test on si0 (tbz w1,#0x1f)         0        1
//     idleAdvance instruction count                       79       85
//
// The onnxruntime archive is carried forward BYTE-IDENTICAL (same release
// asset, digest re-measured after upload), so its checksum does not move.
// ---------------------------------------------------------------------------
// ★ ROLLED 2026-09-19 ONTO essence2-v1.9.0 — THE PUBLISHED ENGINE STOPS
// DELIVERING A PARTLY GENERATED MOUTH, AND ITS TWO MOUTH MASKS AGREE.
// bithuman-models #944 + #948 (main 92d9d9d56). Measured on the v1.8.0 bytes
// (the slice this file pinned until now) with the engine's own per-pixel
// census: 0.0978 mean / 0.9991 max generated share over 717 rendered frames on
// A23KSG5258 — ~9.8% of the mouth band generated on average, some pixels fully
// generated — and no mouth-mask line on the log at all (the silent ELLIPSE).
// The source-only head (a0f581ce5) and the native lip contour (72ac39e81) both
// post-date the v1.8.0 tag: v1.9.0 is the first published engine that carries
// them, and it reads 0.0 / 0.0.
//
// And the reader half: the bundle's native CoreML model now takes a 5th input
// `lip_delivery` from the bundle's `lip_template.v1.json` — the same contour
// the teeth path already uses, now applied to the model's OWN blend mask, the
// one that actually draws the elliptical region on the chin. A bundle whose
// CoreML model is still the 4-input package beside a template (every served
// bundle today) is REFUSED by name and rendered through onnxruntime instead:
// same picture, the reason on the log, until bundles are re-published with
// the 5-input package. Four states, each named on stderr; none silent.
//
// GRADED ON THE PUBLISHED SLICE, the same probe, the same container and
// drive, three arms (bithuman-models
// proof/evidence/apple_lipdel_reader_20260919/ and the #948 body):
//     5-input package + template   lip_delivery: BOUND   | LIP CONTOUR | 0.0 / 0.0 | 717 frames, none skipped
//     5-input package, no template lip_delivery: ONES    | ELLIPSE     | 0.0 / 0.0 | 717 / none skipped
//     as served today (4-input)    REFUSED -> onnxruntime | LIP CONTOUR | 0.0 / 0.0 | 717 / none skipped
// The archive was re-downloaded ANONYMOUSLY from this tap after upload and
// re-hashed to 8c35d482… against its sidecar AND the checksum below.
// onnxruntime is carried forward byte-identical again.
// ---------------------------------------------------------------------------
// ★ ROLLED ONTO essence2-v1.10.0 — THE ARCHIVE STOPS CARRYING THE
// UnifiedModelHeader OBJECTS, WHICH IS WHAT MADE `Expression2` + `Essence2` IN
// ONE APP A LINK FAILURE. The whole measurement, both halves and the eleven
// app links that grade them, are in the essence-2 section of the header above;
// the second half is the `UnifiedModelHeaderBinary` entry in the `Essence2`
// product below, and NEITHER HALF SHIPS ALONE.
//
// Engine change: models/essence-2/engine/light/apple/build-xcframework.sh now
// drops the 4 `UnifiedModelHeader.build/*.o` objects from the libtool filelist
// of every slice (and refuses to build if it matches none, so the filter can
// never silently become a no-op), and models/_shared/swift/UnifiedModelHeader
// is compiled `-enable-library-evolution` so a source consumer speaks the same
// ABI as the published framework — without that, 3 `…vau` addressor symbols
// stay unresolvable against a framework that exports `…vgZ` getters.
//
// ★ THE CHECKSUM BELOW IS THE ONE THE RELEASE ACTUALLY ATTACHES, AND IT WAS
// RE-PINNED ONCE THOSE BYTES EXISTED. It first carried a8c6271a…, the digest of
// a build on echelon — the same sources, a different machine, 179,379,244 B
// against the release's 170,996,285 B. These archives are not byte-reproducible
// across hosts, so a manifest pinned to a developer's copy resolves for nobody.
// The value now is what bithuman-models cut for essence2-apple-v1.10.0
// (commit 05e443da9): its own `libessence2.xcframework.zip.sha256` sidecar,
// re-measured after download, and equal to `swift package compute-checksum` on
// the downloaded file. The tap's publish-essence2-apple.yml re-hosts THAT file
// byte-for-byte and refuses on a mismatch, so the tap asset carries this digest
// too.
//
// GRADED ON THE RELEASED BYTES before this line moved — re-downloaded, re-hashed
// to eacbbfdb… against the sidecar, unzipped and read with `nm`:
//     slice                 UMH defined   colliding   referenced   unmet
//     ios-arm64                       0           0           14       0
//     ios-arm64-simulator             0           0            6       0
//     macos-arm64                     0           0           14       0
// and all eleven app links of tools/check-essence2-expression2-link.sh green on
// them (both link shapes, all three slices, plus Essence2 alone at 0 undefined).
//
// onnxruntime is carried forward byte-identical once more — the SAME release
// asset, so its checksum does not move; it must be attached to this tag too,
// because `essence2Base` is the tag both URLs are read from.
// ---------------------------------------------------------------------------
// ★ ROLLED 2026-09-23 ONTO essence2-v1.11.0 + Expression2 v2.6.5 (package tag v2.14.2) —
// SELF-HOSTED SESSIONS BILL TALKING TIME ONLY, AND EXPRESSION 2 ON APPLE IS METERED AT ALL.
// Owner rulings 2026-09-23: idle is free everywhere; a session the service authenticated
// keeps rendering through an outage for 300 s of RENDERED frames, then refuses retryably
// until the service answers, and the outage's usage is claimed then; a credential the
// service never vouched for renders nothing. bithuman-models #1132 + #1165 (both engines)
// and #1144 (BITHUMAN_API_KEY read as a deprecated alias of BITHUMAN_API_SECRET), #1125
// (the Metal teeth compositor releases a session's buffers), #1183 (Expression2's create
// names a metering refusal instead of blaming CoreML). Expression2 v2.6.4 had NO session
// meter; v2.6.5 does (`Expression2Credential.set`, `Expression2Engine.meteringRefusal`,
// `shutdown()`), and a Release build refuses without a credential.
//
// essence2-v1.11.0 is bithuman-models essence2-apple-v1.11.0 (295e3aaf2), built and
// graded by apple-xcframework.yml (run 35824196849) and re-hosted here byte-for-byte by
// publish-essence2-apple.yml: libessence2.xcframework.zip sha256 08511e16…, its checksum
// below. Expression2 v2.6.5 was built on echelon (Xcode 26.3) from bithuman-models
// ec9a3ab83 by publish-apple-release.sh --build; its three checksums above are the
// sidecars of those files.
//
// MEASURED ON THESE BYTES before the pin moved: a NEW App-template app depending on this
// package links for macOS, iOS Simulator and iOS device on Xcode 26.3 (echelon) and on
// the newest hosted Xcode 26.6 / Swift 6.3.3 (apple-candidate-consumer.yml run
// 35848154472); a real metered macOS session per engine: talk 15 s / idle 130 s /
// talk 10 s bills talking 25.5 s (essence-2) and 23.4 s (expression-2) with the idle
// beat at talking 0.0; unreachable service at first contact renders 0 frames on both;
// the 300 s grace refuses at 7,500 frames since the last ack and resumes on reconnect,
// the outage claimed as accrued. iPhone 15 floor series on these bytes: see the
// release notes. onnxruntime is carried forward byte-identical again.
let essence2Tag = "essence2-v1.11.0"
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
        //
        // ★ THE THIRD TARGET IS THE OTHER HALF OF THE essence2-v1.10.0 FIX AND
        // IS NOT OPTIONAL EITHER. From v1.10.0 `libessence2.a` no longer
        // DEFINES the UnifiedModelHeader symbols — that is what stopped an app
        // taking `Expression2` + `Essence2` from colliding on 112 of them — so
        // it REFERENCES them instead: 14 on ios-arm64 and macos-arm64, 6 on the
        // simulator. Without `UnifiedModelHeaderBinary` here, an Essence2-ONLY
        // app links against nothing that defines them:
        //     Undefined symbols for architecture arm64:
        //       "static UnifiedModelHeader.EngineLoaderRegistry.shared.getter : …",
        //         referenced from: libessence2.a[5](UnifiedEngineDispatch.o)
        // MEASURED 2026-09-21, both slices, on the v1.10.0 bytes with this
        // entry removed (tools/check-essence2-expression2-link.sh arms
        // E2ONLY_DEV_no_umh / E2ONLY_MAC_no_umh: rc=1, 14 undefined each; with
        // it, rc=0 and 0 undefined on all three slices).
        //
        // It costs an `Essence2`-only consumer nothing it did not already pay:
        // the SAME binaryTarget is what the `Expression2` product above lists,
        // so an app taking both products resolves ONE copy of it. And it is
        // already in this manifest at `expression2Tag` — no new coordinate, no
        // new download for anyone taking both.
        //
        // ★ AND A FOURTH, WHICH IS NOT A BINARY AT ALL: `Essence2LinkSettings`.
        // `libessence2.a` is a STATIC C/C++/Objective-C++ archive, and a static
        // archive records none of the Apple libraries it calls, so until 2.14.1
        // every app taking this product compiled and then FAILED ITS FINAL LINK
        // with hundreds of undefined symbols (`std::__1::…`, `_VTDecompression…`,
        // `_BNNSFilter…`, `_OBJC_CLASS_$_MLModel`) until the developer added four
        // link settings by hand — which docs.bithuman.ai had to teach as a
        // required step. MEASURED 2026-09-23 on alpharetta (Xcode 26.4.1), a new
        // App-template project taking `Essence2` from 2.14.0: ** BUILD FAILED **
        // on exactly those symbols. A binaryTarget cannot carry linkerSettings; a
        // source target can, and SwiftPM hands them to the final link of every
        // app that takes this product. So the four settings live here, once.
        .library(name: "Essence2", targets: ["libessence2", "onnxruntime", "UnifiedModelHeaderBinary", "Essence2LinkSettings"]),
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
            checksum: "f1fb6775deca2884739432cb0f0c8d85173234c7f1137c3b8a01dd96ac84c732"
        ),
        .binaryTarget(
            name: "BithumanEngineProtocolBinary",
            url: "\(expression2Base)/BithumanEngineProtocol.xcframework.zip",
            checksum: "1dcb82534267ccb59f3f46681b202d3d1029eb40ef667a953e1f9669be11fe5f"
        ),
        .binaryTarget(
            name: "UnifiedModelHeaderBinary",
            url: "\(expression2Base)/UnifiedModelHeader.xcframework.zip",
            checksum: "5e3e56a0a1895cb8f9277aee921d7ac30b7318d0fe75e78688f5223507e70c03"
        ),
        // The essence-2 engine itself. The target name matches the xcframework
        // inside the archive; the MODULES it vends are `CLibEssence2` and, since
        // essence2-v1.2.0, `Essence2`, both declared by Headers/module.modulemap
        // in every slice over the one header be_essence2.h.
        .binaryTarget(
            name: "libessence2",
            url: "\(essence2Base)/libessence2.xcframework.zip",
            checksum: "08511e1632bfa5b99f67b78c7f43baefbf292d9bf15c07ca5ef18b48f06631c1"
        ),
        // Not optional, and not a convenience: without it the engine's ONNX
        // Runtime symbols are undefined at the app's final link (measured — see
        // the essence-2 section in the header). Re-hosted here unchanged so it
        // can be fetched without credentials.
        // The Apple libraries libessence2.a calls, declared where SwiftPM can
        // pass them to the app's final link (see the `Essence2` product). Each
        // was dropped on its own from a working link to see what it is for:
        //   c++           316 undefined — the C++ standard library
        //   VideoToolbox    5 undefined — `_VTDecompressionSession…`
        //   Accelerate     27 undefined — `_BNNSFilter…`, `_cblas_sgemm…`
        //   CoreML          5 undefined — `_OBJC_CLASS_$_MLModel` and siblings
        // Safe settings, not unsafeFlags, so a version-pinned consumer takes them.
        .target(
            name: "Essence2LinkSettings",
            path: "Sources/Essence2LinkSettings",
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("Accelerate"),
                .linkedFramework("CoreML"),
            ]
        ),
        .binaryTarget(
            name: "onnxruntime",
            url: "\(essence2Base)/onnxruntime.xcframework.zip",
            checksum: "7d631c161ae0d9c6f01095bcb5556d0b4f0205dc5111e6d2ddae82cc7050a7ed"
        ),
    ]
)
