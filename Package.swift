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
// WHAT THIS PACKAGE ACTUALLY VENDS. Three products, and no others. Naming any
// other product fails at resolve time:
//     product 'Expression' ... not found in package 'homebrew-bithuman'
//
//   - bitHumanKit              binary umbrella, tag v2.4.0. `import bitHumanKit`.
//   - Expression2              expression-2 engine alone, tag v2.6.0.
//                              `import Expression2`. FOUR binaryTargets ride
//                              under it now, not three — see UnifiedModelHeader.
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
//                  `Expression2ContainerError.notAnAvatarDirectory(path:)`.
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
// ★ essence-2 IS NOT ON THIS RAIL. It is not a product below and it is not
//   bundled inside bitHumanKit — that is the `essence 0 / libessence 0` reading
//   above, not an assumption. essence-2 on iOS is CAPABILITY-PROVEN and NOT
//   ARMED: an in-process device probe (iPhone 15, 2026-09-02) rendered
//   essence-2 and composed the teeth borrow inline, grading L1 0.002295 u8
//   against the offline borrow reference (97.71 % gap closure vs the borrow-OFF
//   twin; null control exactly 0.000000). It reached that on a hand-assembled
//   side-load: a bundle trimmed to NT=64, an a2x provenance breach recorded in
//   meta.json, a 46 MB fp16 w2v standing in for the 377 MB production frontend
//   (which the phone SIGKILLs), and RTF 16.06 — not realtime. No customer could
//   do any of that. See models/essence-2/proof/evidence/
//   IOS_INPROCESS_BORROW_20260902.txt §6-§7 for the four blockers by owner.
//   To reach essence-2 from an Apple app TODAY: the REST API, a LiveKit
//   session, or — on macOS only — the Python wheel. Not this package.
//
// ─────────────────────────────────────────────────────────────────────────────
// Hardware floor for the two bitHumanKit engines (gated at runtime via
// HardwareCheck.evaluate(), which refuses politely below it — NOT by the
// `platforms:` floor below, which is deliberately lower, see the note there):
//   macOS:   M3+ Apple Silicon, macOS 26 (Tahoe)
//   iPad:    iPad Pro M4+, 16 GB unified memory, iPadOS 26
//   iPhone:  iPhone 16 Pro+ (A18 Pro), iOS 26
// ★ That floor grades bitHumanKit ONLY. It is not `Expression2`'s floor:
//   Expression2 is a separate binary with its own CoreML requirements and is
//   not gated by HardwareCheck.
//
// RELEASE NOTE:
//   `bitHumanKit` (the umbrella, tag v2.4.0) and `Expression2` + its binary
//   `BithumanEngineProtocol` + `UnifiedModelHeader` (tag v2.6.0) ship today.
//   ★ FOUR binaryTargets below now, not three, and the fourth is not optional:
//   the engine's emitted .swiftinterface carries `import UnifiedModelHeader` at
//   line 14 (it registers itself in the shared EngineLoaderRegistry), so a
//   consumer taking only the v2.5.0 pair dies at import with
//   `no such module 'UnifiedModelHeader'`. Every one of the four was re-fetched
//   and re-hashed against the checksum it pins — the three v2.6.0 checksums came
//   out of the `.sha256` sidecars the build wrote, never from a human, and
//   bitHumanKit's is UNCHANGED at 5c536e37… (bumping the shared `releaseTag`
//   would 404 the shipping product; see the block above `expression2Tag`).
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
        .library(name: "Expression2", targets: ["Expression2", "BithumanEngineProtocolBinary", "UnifiedModelHeader"]),
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
        .binaryTarget(
            name: "Expression2",
            url: "\(expression2Base)/Expression2.xcframework.zip",
            checksum: "d4ce14b6b9c463aa7310ca8200f59ded20931cc33f40b6c530eef13b5a40d326"
        ),
        .binaryTarget(
            name: "BithumanEngineProtocolBinary",
            url: "\(expression2Base)/BithumanEngineProtocol.xcframework.zip",
            checksum: "048a5d271d61fe4689dd9f1a6f209c00e358e4fd77aa249e55dc59dcd7051759"
        ),
        .binaryTarget(
            name: "UnifiedModelHeader",
            url: "\(expression2Base)/UnifiedModelHeader.xcframework.zip",
            checksum: "33b7d575ec90055a4894fb1fbbb507b9264694752c6a2a5e35c7bf8c069e180e"
        ),
    ]
)
