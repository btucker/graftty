// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Espalier",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Espalier", targets: ["Espalier"]),
        // Product name "espalier-cli" (not "espalier") to avoid case-insensitive
        // filesystem collision with the "Espalier" app binary. When the app is
        // bundled for distribution, this binary is installed as "espalier"
        // at Espalier.app/Contents/MacOS/espalier per ATTN-1.1.
        .executable(name: "espalier-cli", targets: ["EspalierCLI"]),
        .library(name: "EspalierKit", targets: ["EspalierKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "EspalierKit",
            dependencies: []
        ),
        .executableTarget(
            name: "Espalier",
            dependencies: [
                "EspalierKit",
                .product(name: "GhosttyKit", package: "libghostty-spm"),
            ]
        ),
        .executableTarget(
            name: "EspalierCLI",
            dependencies: [
                "EspalierKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "EspalierKitTests",
            dependencies: ["EspalierKit"]
        ),
    ]
)
