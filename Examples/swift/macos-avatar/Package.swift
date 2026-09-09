// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MacOSAvatar",
    platforms: [
        .macOS("26.0")
    ],
    dependencies: [
        .package(name: "bithuman",
                 url: "https://github.com/bithuman-product/homebrew-bithuman.git",
                 from: "2.11.0")
    ],
    targets: [
        .executableTarget(
            name: "MacOSAvatar",
            dependencies: [
                .product(name: "bitHumanKit", package: "bithuman")
            ],
            path: "Sources"
        )
    ]
)
