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
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "Graftty", targets: ["Graftty"]),
        // Product name "graftty-cli" (not "graftty") to avoid case-insensitive
        // filesystem collision with the "Graftty" app binary. When the app is
        // bundled for distribution, this binary is installed as "graftty"
        // at Graftty.app/Contents/Helpers/graftty (`scripts/bundle.sh`) — not
        // `Contents/MacOS/`, since the GUI binary `Graftty` lives there and a
        // sibling lowercase `graftty` would resolve to the GUI on case-
        // insensitive volumes. See `BundlePathSanitizer` for the runtime
        // PATH override that protects spawned panes from the same trap.
        .executable(name: "graftty-cli", targets: ["GrafttyCLI"]),
        .executable(name: "appcast-updater", targets: ["appcast-updater"]),
        .library(name: "GrafttyKit", targets: ["GrafttyKit"]),
        .library(name: "GrafttyMobileKit", targets: ["GrafttyMobileKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.26.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        .package(url: "https://github.com/stencilproject/Stencil.git", from: "0.15.1"),
    ],
    targets: [
        .target(
            name: "GrafttyProtocol",
            swiftSettings: strictWarnings
        ),
        .target(
            name: "AppcastUpdater",
            swiftSettings: strictWarnings
        ),
        .target(
            name: "GrafttyKit",
            dependencies: [
                "GrafttyProtocol",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Stencil", package: "Stencil"),
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
                "GrafttyProtocol",
                .product(name: "GhosttyKit", package: "libghostty-spm"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Stencil", package: "Stencil"),
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
        .executableTarget(
            name: "appcast-updater",
            dependencies: ["AppcastUpdater"],
            swiftSettings: strictWarnings
        ),
        .testTarget(
            name: "GrafttyProtocolTests",
            dependencies: ["GrafttyProtocol"],
            swiftSettings: strictWarnings
        ),
        .testTarget(
            name: "AppcastUpdaterTests",
            dependencies: ["AppcastUpdater"],
            resources: [
                .copy("Fixtures"),
            ],
            swiftSettings: strictWarnings
        ),
        .testTarget(
            name: "GrafttyKitTests",
            dependencies: ["GrafttyKit", "GrafttyProtocol"],
            resources: [
                .process("Hosting/Fixtures"),
                .copy("Web/Fixtures"),
            ],
            swiftSettings: strictWarnings
        ),
        .target(
            name: "GrafttyMobileKit",
            dependencies: [
                "GrafttyProtocol",
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
            ],
            swiftSettings: strictWarnings
        ),
        .testTarget(
            name: "GrafttyMobileKitTests",
            dependencies: ["GrafttyMobileKit"],
            swiftSettings: strictWarnings
        ),
        .testTarget(
            name: "GrafttyTests",
            dependencies: ["Graftty"],
            swiftSettings: strictWarnings
        ),
    ]
)
