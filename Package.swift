// swift-tools-version: 6.0
// bitHumanKit — public binary distribution.
//
// The source for these frameworks lives in the private monorepo
// bithuman-product/bithuman-sdk-internal (the swift/ tree for bitHumanKit; the
// engine/expression/ and sdks/swift/ trees for the two Layer-1 engine
// products extracted on the refactor/engine-tiers branch). This package
// consumes the pre-compiled XCFrameworks attached to THIS repo's GitHub
// Releases via SwiftPM's binaryTarget — each `.xcframework.zip` is built
// from bithuman-sdk-internal and uploaded here per release; consumers depend only
// on this package URL.
//
// NOTE: bithuman-sdk-internal was ARCHIVED on 2026-06-30; its trees are now
// consolidated into the private engine monorepo bithuman-product/bithuman-models
// (models/expression-2, models/essence-1, models/essence-2). The
// bithuman-sdk-internal references below are historical provenance only.
//
// All third-party deps (MLX, HuggingFace, Tokenizers, …) are
// statically linked into the framework binaries, so consumers
// don't need any transitive Swift Package dependencies. Just
// add this package and `import bitHumanKit` (or `import Expression`
// / `import Bithuman` for the lower-level engine products).
//
// Products
//   - bitHumanKit  Full on-device voice + video chat SDK (umbrella).
//                  The Expression avatar engine + an `.imx` avatar runtime +
//                  the on-device LLM/TTS stack. Most apps want this one.
//                  `import bitHumanKit`.
//                  ★ IT DOES NOT CONTAIN libessence, AND IT NEVER SAID SO
//                  TRUTHFULLY. This block used to read "re-exports … the Essence
//                  (libessence) runtime". MEASURED 2026-08-29 against the exact
//                  published asset (bitHumanKit.xcframework.zip @ v2.4.0, sha256
//                  5c536e37…e9db, the value the binaryTarget below pins): the
//                  framework binary is a static archive of 28 objects —
//                  bitHumanKit.o, MLX*, HuggingFace, Tokenizers, Crypto, yyjson —
//                  and NOT ONE of them is libessence, libelevate or onnxruntime.
//                  `strings` finds zero occurrences of "essence"/"elevate"; the
//                  public .swiftinterface declares no Essence type. What is
//                  really there is a Swift-side `ImxContainer` reader reached via
//                  `Bithuman.create(modelPath:)`. The `Bithuman` ACTOR is real;
//                  "the portable libessence C++ runtime" was not.
//   - Expression2  Layer-1 Expression 2 avatar engine, pure Swift + CoreML.
//                  Published at tag v2.5.0 (see `expression2Tag` below).
//                  `import Expression2`, then `Expression2Engine()`.
//                  ★ CODE ONLY — NO MODEL WEIGHTS. `Expression2Engine.init()`
//                  takes no model path; it looks for a per-identity CoreML bundle
//                  in $BITHUMAN_EXPRESSION2_DIR or in the app bundle, and
//                  `isReady` stays false until it finds one. No such bundle is
//                  published yet, so this product does not render out of the box.
//   - Expression   Layer-1 avatar engine on its own: speech encoder →
//                  animator → face decoder → face renderer expressive
//                  talking head. Built from the
//                  bithuman-sdk-internal engine/expression/ package. Pull this in
//                  directly when you only need the avatar renderer (no
//                  STT/LLM/TTS). Home of the `Bithuman` actor,
//                  `Bithuman.Quality`, `AvatarConfig`, `ImxContainer`.
//                  `import Expression`.
//   - Bithuman     Layer-1 Essence engine on its own: the portable
//                  libessence C++ avatar runtime (audio → composited BGR
//                  frames from a pre-built `.imx`). Built from the
//                  bithuman-sdk-internal sdks/swift/ package. CPU-only, works on
//                  any Apple Silicon. `import Bithuman`.
//
// Hardware floor (gated at runtime via HardwareCheck.evaluate()):
//   macOS:   M3+ Apple Silicon, macOS 26 (Tahoe)
//   iPad:    iPad Pro M4+, 16 GB unified memory, iPadOS 26
//   iPhone:  iPhone 16 Pro+ (A18 Pro), iOS 26
//
// RELEASE NOTE (Layer-1 engine products):
//   `bitHumanKit` (the umbrella, tag v2.4.0) and `Expression2` (tag v2.5.0)
//   ship today. The standalone `Expression` and `Bithuman` (Essence) products
//   are NOT yet published:
//   their per-product XCFramework zips + checksums are produced by the
//   release flow (scripts/build-binary-xcframework.sh emits the per-product
//   zips; `swift package compute-checksum <zip>` yields the value). They are
//   omitted from `products`/`targets` below until a release uploads those
//   two zips, so this manifest always resolves cleanly. To re-add them, fill
//   in real checksums and restore the two products/binaryTargets. See
//   scripts/validate-release.sh and docs/RELEASE_MATRIX.md.
import PackageDescription

// Pin the binary slice to a release tag. When the Layer-1 engine products are
// published they should share this tag so a `from:` bump moves them in lockstep.
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
let expression2Tag = "v2.5.0"
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
        // NOTE: the standalone `Expression` and `Bithuman` (Essence) Layer-1
        // engine products are not yet published — their per-product XCFramework
        // zips + checksums are produced by the release flow. They are
        // intentionally omitted here until a release uploads them, so the
        // package resolves cleanly. Until then, use `bitHumanKit` (the umbrella
        // product re-exports both engines). See the RELEASE NOTE above.
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
        .library(name: "Expression2", targets: ["Expression2", "BithumanEngineProtocolBinary"]),
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
            checksum: "18c8e71037600a570acaf05c2c8e3e917069705191860ce4dc84a69a56dccab7"
        ),
        .binaryTarget(
            name: "BithumanEngineProtocolBinary",
            url: "\(expression2Base)/BithumanEngineProtocol.xcframework.zip",
            checksum: "ce4ae409afbf378039c9a28e0871d2e37740cabf57daff3461777bf11be436a2"
        ),
    ]
)
