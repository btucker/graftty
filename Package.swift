// swift-tools-version: 5.10

import PackageDescription
import Foundation

// Allows the snapshot-enabled renderer to be built and tested from its
// reproducible local package before publishing the binary dependency.
let localGhosttyPath: String? = {
    if let path = ProcessInfo.processInfo.environment["GRAFTTY_GHOSTTY_PACKAGE_PATH"] {
        return path.isEmpty ? nil : path
    }
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent(".dependencies/libghostty-spm").path
    return FileManager.default.fileExists(atPath: path + "/Package.swift") ? path : nil
}()
let ghosttyDependency: Package.Dependency = {
    if let path = localGhosttyPath {
        return .package(name: "libghostty-spm", path: path)
    }
    return .package(url: "https://github.com/btucker/libghostty-spm.git", revision: "52a84d611b1442dbeffa972b37022346a8a32ec6")
}()

// CI runs `swift build` / `swift test` which default to the debug
// configuration; matching that here means warnings fail the local
// build too and we don't find out from a CI round-trip. Release
// configuration stays lenient so a future Swift version's new
// warnings don't block shipping.
let strictWarnings: [SwiftSetting] = [
    .unsafeFlags(["-warnings-as-errors"], .when(configuration: .debug)),
] + (localGhosttyPath == nil ? [] : [.define("GRAFTTY_PAGED_HISTORY")])

#if os(Linux)
let isLinux = true
let appleDependencies: [Package.Dependency] = []
let appleKitDependencies: [Target.Dependency] = []
let webRTCDependencies: [Target.Dependency] = []
#else
let isLinux = false
let appleDependencies: [Package.Dependency] = [
    ghosttyDependency,
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    .package(url: "https://github.com/stasel/WebRTC.git", from: "137.0.0"),
]
let appleKitDependencies: [Target.Dependency] = [.product(name: "Sparkle", package: "Sparkle")]
let webRTCDependencies: [Target.Dependency] = [.product(name: "WebRTC", package: "WebRTC")]
#endif
let cryptoDependencies: [Target.Dependency] = [.product(name: "Crypto", package: "swift-crypto")]
let linuxKitExclusions = ["Updater", "Editor", "Model/PNGThumbnail.swift", "Model/ProjectIconDiscovery.swift",
                          "Ports/PortBindingsModel.swift"]
let appleTargets: Set<String> = ["AppcastUpdater", "appcast-updater", "AppcastUpdaterTests", "Graftty", "GrafttyCommandUI", "GrafttyCommandUITests", "GrafttyMobileKit",
                               "GrafttyMobileKitTests", "GrafttyTests", "OwnershipModelTests", "GrafttyRemoteClientTests"]

let package = Package(
    name: "Graftty",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: ([
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
        .executable(name: "graftty-host", targets: ["GrafttyHost"]),
        .executable(name: "appcast-updater", targets: ["appcast-updater"]),
        .library(name: "GrafttyKit", targets: ["GrafttyKit"]),
        .library(name: "GrafttyRemoteClient", targets: ["GrafttyRemoteClient"]),
        .library(name: "GrafttyCommandUI", targets: ["GrafttyCommandUI"]),
        .library(name: "GrafttyMobileKit", targets: ["GrafttyMobileKit"]),
    ] as [Product]).filter { !isLinux || !["appcast-updater", "Graftty", "GrafttyCommandUI", "GrafttyMobileKit"].contains($0.name) },
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.13.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.26.0"),
        .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.22.0"),
        .package(url: "https://github.com/stencilproject/Stencil.git", from: "0.15.1"),
    ] + appleDependencies,
    targets: ([
        .target(
            name: "GrafttyProtocol",
            dependencies: cryptoDependencies,
            exclude: isLinux ? ["UI"] : [],
            swiftSettings: strictWarnings
        ),
        .target(
            name: "GrafttyCommandUI",
            dependencies: ["GrafttyProtocol"],
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
                .product(name: "Stencil", package: "Stencil"),
            ] + appleKitDependencies + cryptoDependencies,
            exclude: isLinux ? linuxKitExclusions : [],
            resources: [
                .copy("Web/Resources"),
                .copy("AgentPlugins"),
                // Vendored ghostty runtime resources (CONFIG-2.5) — see
                // GhosttyResources/ghostty/PROVENANCE.md. `ghostty` and
                // `terminfo` land at the bundle root as siblings, mirroring
                // Ghostty.app's Contents/Resources layout, which is what
                // ZmxSpawnConfiguration.availableGhosttyTerminfoDir probes.
                .copy("GhosttyResources/ghostty"),
                .copy("GhosttyResources/terminfo"),
            ],
            swiftSettings: strictWarnings
        ),
        .target(
            name: "GrafttyTunnel",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
            ],
            swiftSettings: strictWarnings
        ),
        .target(
            name: "GrafttyHostAgent",
            dependencies: [
                "GrafttyTunnel",
                "GrafttyKit",
                "GrafttyProtocol",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOExtras", package: "swift-nio-extras"),
            ] + webRTCDependencies + cryptoDependencies,
            swiftSettings: strictWarnings
        ),
        .target(
            name: "GrafttyRemoteClient",
            dependencies: [
                "GrafttyTunnel",
                "GrafttyProtocol",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOExtras", package: "swift-nio-extras"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
            ] + webRTCDependencies + cryptoDependencies,
            swiftSettings: strictWarnings
        ),
        .executableTarget(
            name: "Graftty",
            dependencies: [
                "GrafttyKit",
                "GrafttyHostAgent",
                "GrafttyRemoteClient",
                "GrafttyProtocol",
                "GrafttyCommandUI",
                .product(name: "GhosttyKit", package: "libghostty-spm"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Stencil", package: "Stencil"),
            ],
            swiftSettings: strictWarnings
        ),
        .executableTarget(
            name: "GrafttyHost",
            dependencies: ["GrafttyKit", "GrafttyProtocol", "GrafttyHostAgent",
                           .product(name: "ArgumentParser", package: "swift-argument-parser")] + cryptoDependencies,
            swiftSettings: strictWarnings
        ),
        .executableTarget(
            name: "GrafttyCLI",
            dependencies: [
                "GrafttyKit",
                "GrafttyProtocol",
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
            name: "GrafttyTunnelTests",
            dependencies: ["GrafttyTunnel", .product(name: "NIOCore", package: "swift-nio"),
                           .product(name: "NIOEmbedded", package: "swift-nio"),
                           .product(name: "NIOSSH", package: "swift-nio-ssh")],
            swiftSettings: strictWarnings
        ),
        .testTarget(
            name: "GrafttyProtocolTests",
            dependencies: ["GrafttyProtocol"] + cryptoDependencies,
            exclude: isLinux ? ["UI", "WorktreePanesTests.swift"] : [],
            swiftSettings: strictWarnings
        ),
        .testTarget(
            name: "GrafttyCommandUITests",
            dependencies: ["GrafttyCommandUI"],
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
            dependencies: ["GrafttyKit", "GrafttyProtocol"] + cryptoDependencies,
            sources: isLinux ? ["Process/LinuxProcessStatTests.swift", "Process/HostPOSIXTests.swift", "Host/HeadlessHostRuntimeTests.swift", "HostSetup/LinuxHostSetupTests.swift", "HostSetup/LinuxHostSetupExecutionTests.swift", "HostSetup/LinuxHostPackagingTests.swift",
                "Support/MutableBox.swift", "Teams/TeamTestFixtures.swift", "Notification/SocketIOTests.swift", "Teams/TeamInboxObserverTests.swift", "Web/PtyProcessTests.swift",
                "Zmx/ZmxRunnerTests.swift", "Teams/TeamInboxTests.swift", "Teams/TeamPresenceStorageTests.swift",
                "Teams/AttentionFileHandoffTests.swift", "Remote/MacToMac/GrafttyBonjourServiceTests.swift", "Remote/MacToMac/RemoteMacTransportTests.swift"] : nil,
            resources: [
                .process("Hosting/Fixtures"),
                .copy("Web/Fixtures"),
            ],
            swiftSettings: strictWarnings
        ),
        .target(
            name: "GrafttyMobileKit",
            dependencies: [
                "GrafttyRemoteClient",
                "GrafttyProtocol",
                "GrafttyCommandUI",
                .product(name: "NIO", package: "swift-nio"),
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
            name: "GrafttyRemoteClientTests",
            dependencies: [
                "GrafttyRemoteClient",
                "GrafttyProtocol",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
            ] + webRTCDependencies + cryptoDependencies,
            swiftSettings: strictWarnings
        ),
        .testTarget(
            name: "GrafttyTests",
            dependencies: ["Graftty", "GrafttyCLI"],
            swiftSettings: strictWarnings
        ),
        .testTarget(
            name: "OwnershipModelTests",
            dependencies: ["Graftty", "GrafttyKit", "GrafttyMobileKit", "GrafttyProtocol"],
            path: "Tests/OwnershipModelTests",
            exclude: ["README.md"],
            swiftSettings: strictWarnings
        ),
    ] as [Target]).filter { !isLinux || !appleTargets.contains($0.name) } + (isLinux ? [
        .testTarget(
            name: "GrafttyDirectSSHTests",
            dependencies: ["GrafttyHostAgent", "GrafttyRemoteClient", "GrafttyKit", "GrafttyProtocol"] + cryptoDependencies,
            path: "Tests/GrafttyTests/Remote/SSH",
            sources: ["DirectSSHLoopbackTests.swift"],
            swiftSettings: strictWarnings
        ),
    ] : [])
)
