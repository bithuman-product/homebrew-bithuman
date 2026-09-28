// swift-tools-version: 6.0
// bitHuman Apple SDK: real-time, lip-synced avatars rendered on iPhone, iPad and Mac.
// Essence 2 renders a photoreal person and Expression 2 any character. Pass in 16 kHz
// mono speech from any voice stack and draw the frames the engine returns.
//
// Install and the current version: https://docs.bithuman.ai/platforms/ios#install
// Mac apps:  https://docs.bithuman.ai/platforms/macos
// Examples:  https://github.com/bithuman-product/bithuman-examples/tree/main/swift
// Changes:   https://docs.bithuman.ai/changelog
// Sessions need an API secret (Creator plan or higher from 12 October 2026) and bill
// active session time: https://docs.bithuman.ai/pricing
//
// ─────────────────────────────────────────────────────────────────────────────
// WHAT THIS PACKAGE ACTUALLY VENDS. Five products:
//
//   - Expression2              Expression 2 with a Swift API. `import Expression2`.
//                              Apple silicon iPhone or iPad on iOS 16+, Mac on macOS 13+.
//   - Essence2Kit              Essence 2 with a Swift API; it includes Essence2.
//                              `import Essence2Kit`. Apple silicon iPhone, M-series iPad
//                              (iOS 26+), Mac with M3 or newer (macOS 26+).
//   - Essence2                 Essence 2 as a C library, for C, C++ and plugins.
//                              `import Essence2` (or `import CLibEssence2`, the same header).
//   - BithumanEngineProtocol   the shared engine interface, as source. `import BithumanEngineProtocol`.
//                              Leave it out beside Expression2, which carries its own copy.
//   - bitHumanKit              legacy (v2.4.0), frozen, for existing apps only. `import bitHumanKit`.
//
// Every binary ships ios-arm64, ios-arm64-simulator (arm64 only) and macos-arm64.
// Essence 2 runs on a device, not in the Simulator; Expression 2 runs in both.
// ─────────────────────────────────────────────────────────────────────────────
//
// The legacy bitHumanKit archive is held to its published bytes by
// scripts/check-manifest-truth.py; `strings -a` on its ios-arm64 slice counts:
//     ImxContainer 141 · bitHumanKit 12715 · mlx 104937 ·
//     Expression 3353 · Bithuman 1663 · CoreML 433
//     essence 0 · Essence 0 · libessence 0 · onnxruntime 0
//
// Check this manifest: python3 scripts/check-manifest-truth.py
import PackageDescription

// The legacy bitHumanKit archive.
let releaseTag = "v2.4.0"
let releaseBase = "https://github.com/bithuman-product/homebrew-bithuman/releases/download/\(releaseTag)"

// The Expression 2 archives.
let expression2Tag = "v2.18.0"
let expression2Base = "https://github.com/bithuman-product/homebrew-bithuman/releases/download/\(expression2Tag)"

// The Essence 2 archives. Essence2Kit fetches its runtime files from this release too.
let essence2Tag = "essence2-v1.14.2"
let essence2Base = "https://github.com/bithuman-product/homebrew-bithuman/releases/download/\(essence2Tag)"

let package = Package(
    name: "bithuman",
    platforms: [
        // The package floor. Build Essence 2 apps for iOS 26 / macOS 26.
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        // Legacy, frozen at v2.4.0. New apps take Expression2 or Essence2Kit.
        .library(name: "bitHumanKit", targets: ["bitHumanKit"]),
        // The shared engine interface, as source. Not beside Expression2.
        .library(name: "BithumanEngineProtocol", targets: ["BithumanEngineProtocol"]),
        // Expression 2 with a Swift API; the protocol and UnifiedModelHeader ride along.
        .library(name: "Expression2", targets: ["Expression2Binary", "BithumanEngineProtocolBinary", "UnifiedModelHeaderBinary"]),
        // Essence 2 as a C library. ONNX Runtime, UnifiedModelHeader and the link settings
        // are required parts of it, not options.
        .library(name: "Essence2", targets: ["libessence2", "onnxruntime", "UnifiedModelHeaderBinary", "Essence2LinkSettings"]),
        // Essence 2 with a Swift API over the Essence2 product. Its runtime files download
        // once, checked against sha256s pinned in Sources/Essence2Kit.
        .library(name: "Essence2Kit", targets: ["Essence2Kit"]),
    ],
    targets: [
        .binaryTarget(
            name: "bitHumanKit",
            url: "\(releaseBase)/bitHumanKit.xcframework.zip",
            checksum: "5c536e37919b693591dff234db8627c01952ae24ae58651aeacbd875bd78e9db"
        ),
        // Swift 5 language mode: this source predates Swift 6 strict concurrency.
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
        // The `…Binary` names keep these targets unique beside the packages that build them.
        .binaryTarget(
            name: "Expression2Binary",
            url: "\(expression2Base)/Expression2.xcframework.zip",
            checksum: "83c3a87179e432f440bef78a0d576e060609482b2081e9a04243e3ed28c4881a"
        ),
        .binaryTarget(
            name: "BithumanEngineProtocolBinary",
            url: "\(expression2Base)/BithumanEngineProtocol.xcframework.zip",
            checksum: "cd3b31f19897c2de4fb49689139cff93e76eb403f4e3a9d3f7b7842f23a30f35"
        ),
        .binaryTarget(
            name: "UnifiedModelHeaderBinary",
            url: "\(expression2Base)/UnifiedModelHeader.xcframework.zip",
            checksum: "e65594ff447fa59aa6cc123eb2c478c85bd4f580cd9fbf455506558bec4843dd"
        ),
        // The Essence 2 engine. Its module map declares `Essence2` and `CLibEssence2`.
        .binaryTarget(
            name: "libessence2",
            url: "\(essence2Base)/libessence2.xcframework.zip",
            checksum: "ac1f3157d1cc9d47a3e42f51d9ade611288ea59ae63e1b5de3169ee41a75f93a"
        ),
        // The Apple libraries libessence2.a calls, passed to the app's final link.
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
        // Source only, over the Essence2 C interface.
        .target(
            name: "Essence2Kit",
            dependencies: ["libessence2", "onnxruntime", "UnifiedModelHeaderBinary", "Essence2LinkSettings"],
            path: "Sources/Essence2Kit"
        ),
        .testTarget(
            name: "Essence2KitTests",
            dependencies: ["Essence2Kit"],
            path: "Tests/Essence2KitTests"
        ),
        // ONNX Runtime, which libessence2 needs at the app's final link.
        .binaryTarget(
            name: "onnxruntime",
            url: "\(essence2Base)/onnxruntime.xcframework.zip",
            checksum: "7d631c161ae0d9c6f01095bcb5556d0b4f0205dc5111e6d2ddae82cc7050a7ed"
        ),
    ]
)
