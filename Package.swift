// swift-tools-version: 5.10

import PackageDescription

// CI runs `swift build` / `swift test` which default to the debug
// configuration; matching that here means warnings fail the local
// build too and we don't find out from a CI round-trip. Release
// configuration stays lenient so a future Swift version's new
// warnings don't block shipping.
let strictWarnings: [SwiftSetting] = [
    .unsafeFlags(["-warnings-as-errors"], .when(configuration: .debug)),
]

let package = Package(
    name: "Graftty",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Graftty", targets: ["Graftty"]),
        // Product name "graftty-cli" (not "graftty") to avoid case-insensitive
        // filesystem collision with the "Graftty" app binary. When the app is
        // bundled for distribution, this binary is installed as "graftty"
        // at Graftty.app/Contents/MacOS/graftty per ATTN-1.1.
        .executable(name: "graftty-cli", targets: ["GrafttyCLI"]),
        .library(name: "GrafttyKit", targets: ["GrafttyKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        .target(
            name: "GrafttyKit",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
            ],
            resources: [
                .copy("Web/Resources"),
            ],
            swiftSettings: strictWarnings
        ),
        .executableTarget(
            name: "Graftty",
            dependencies: [
                "GrafttyKit",
                .product(name: "GhosttyKit", package: "libghostty-spm"),
            ],
            resources: [
                .copy("Resources/plugins"),
            ],
            swiftSettings: strictWarnings
        ),
        .executableTarget(
            name: "GrafttyCLI",
            dependencies: [
                "GrafttyKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: strictWarnings
        ),
        .testTarget(
            name: "GrafttyKitTests",
            dependencies: ["GrafttyKit"],
            resources: [
                .process("Hosting/Fixtures"),
                .copy("Web/Fixtures"),
            ],
            swiftSettings: strictWarnings
        ),
    ]
)
