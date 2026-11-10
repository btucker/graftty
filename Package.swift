// swift-tools-version: 6.0

import PackageDescription
import Foundation

#if os(Windows)
// Bootstrap the native terminal without the Apple renderer or POSIX host.
// Native SSH is pending: upstream NIOSSH has no supported Windows CSPRNG.
let package = Package(
    name: "Graftty",
    products: [
        .library(name: "GrafttyWindowsTerminal", targets: ["GrafttyWindowsTerminal"]),
    ],
    targets: [
        .target(name: "CGrafttyConPTY", linkerSettings: [.linkedLibrary("kernel32")]),
        .target(name: "GrafttyWindowsTerminal", dependencies: ["CGrafttyConPTY"]),
        .testTarget(name: "GrafttyWindowsTerminalTests", dependencies: ["GrafttyWindowsTerminal"]),
    ],
    swiftLanguageModes: [.v5]
)
#else
let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
#if os(macOS)
// libghostty is built from the pinned Ghostty commit and the patch series in
// deps/ghostty by `scripts/deps prepare`, which links it into .deps/ and
// records its input key (see deps/README.md). scripts/swiftpm and bundle.sh
// prepare it automatically; Xcode users run `scripts/deps prepare --platforms
// macos,ios` once. The key plus the header's modification time also form a
// compiler definition that changes Clang's module context hash, so a rebuilt
// header never meets a stale libghostty.pcm.
let rendererIdentity: String = {
    let deps = repositoryRoot.appendingPathComponent(".deps")
    guard let line = try? String(contentsOf: deps.appendingPathComponent("ghostty.key"), encoding: .utf8),
          let key = line.split(separator: " ").first, key.count == 64 else {
        fatalError("libghostty is not prepared. Run scripts/deps prepare (add --platforms macos,ios for Xcode).")
    }
    let header = deps.appendingPathComponent("GhosttyKit.xcframework/macos-arm64_x86_64/Headers/libghostty/ghostty.h")
    let modified = (try? header.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    return key.prefix(32) + "_" + String(Int(modified?.timeIntervalSince1970 ?? 0))
}()
let rendererSettings: [SwiftSetting] = [
    .unsafeFlags(["-Xcc", "-DGRAFTTY_RENDERER_" + rendererIdentity]),
    .define("GRAFTTY_PAGED_HISTORY"),
]
#else
let rendererSettings: [SwiftSetting] = []
#endif
// GhosttyKit and GhosttyTerminal came from Lakr233/libghostty-spm (MIT; see
// deps/ghostty/LICENSE-libghostty-spm). They keep its Swift 6 settings.
let ghosttySwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("ExistentialAny"),
] + rendererSettings

// CI runs `swift build` / `swift test` which default to the debug
// configuration; matching that here means warnings fail the local
// build too and we don't find out from a CI round-trip. Release
// configuration stays lenient so a future Swift version's new
// warnings don't block shipping.
let strictWarnings: [SwiftSetting] = [
    .unsafeFlags(["-warnings-as-errors"], .when(configuration: .debug)),
] + rendererSettings

#if os(Linux)
let isLinux = true
let containerProcessDependencies: [Target.Dependency] = [.product(name: "Subprocess", package: "swift-subprocess")]
let appleDependencies: [Package.Dependency] = []
let appleKitDependencies: [Target.Dependency] = []
let webRTCDependencies: [Target.Dependency] = []
#else
let isLinux = false
let containerProcessDependencies: [Target.Dependency] = []
let appleDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/Lakr233/DisplayLink.git", from: "3.0.1"),
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    .package(url: "https://github.com/stasel/WebRTC.git", from: "137.0.0"),
]
let appleKitDependencies: [Target.Dependency] = [.product(name: "Sparkle", package: "Sparkle")]
let webRTCDependencies: [Target.Dependency] = [.product(name: "WebRTC", package: "WebRTC")]
#endif
let cryptoDependencies: [Target.Dependency] = [.product(name: "Crypto", package: "swift-crypto")]
let linuxKitExclusions = ["Updater", "Editor", "Model/PNGThumbnail.swift",
                          "Ports/PortBindingsModel.swift"]
// GrafttyKitTests compiles every file on Linux except `Apple/` (tests that
// need AppKit, macOS-only APIs or GrafttyKit code excluded from Linux) and
// this list of files not yet ported, each annotated with what blocks it (an
// open issue, or a tool or API the Linux build lacks; #687 tracks the rest).
// Shrink it as files are ported or moved under `Apple/`; do not add to it.
// scripts/check-linux-test-allowlist.py checks both.
let linuxPendingKitTests = [
    "CLI/CLIRunnerTests.swift", // #666: GNU env not-found message
    "Git/WorktreeMonitorTests.swift", // contentStreamCountForTesting is macOS-only (FSEvents)
    "Remote/ZmxAttachEngineTests.swift", // runs the bundled macOS zmx
    "SidebarHostNavigationTests.swift", // uses ProjectIconDiscovery (ImageIO)
    "Teams/AgentPluginInstallerTests.swift", // #667: Codex TOML parse differs on Linux
    "Teams/ShellStartupCommandTests.swift", // needs zsh
    "Web/AgentCompletionsEndpointTests.swift", // HTTPS via the trust-all URLSession client (Security serverTrust)
    "Web/GhosttyKeybindingsEndpointTests.swift", // HTTPS via the trust-all URLSession client (Security serverTrust)
    "Web/WebServerAuthTests.swift", // HTTPS via the trust-all URLSession client (Security serverTrust)
    "Web/WebServerDeleteEndpointTests.swift", // HTTPS via the trust-all URLSession client (Security serverTrust)
    "Web/WebServerIntegrationTests.swift", // HTTPS via the trust-all URLSession client (Security serverTrust)
    "Web/WebServerWorktreeEndpointTests.swift", // HTTPS via the trust-all URLSession client (Security serverTrust)
    "WorktreeSleep/ShellSleepActivityTests.swift", // needs zsh
    "Zmx/ZmxLauncherTests.swift", // #653: Linux zmx path case
    "Zmx/ZmxNativeHostManagedIntegrationTests.swift", // runs the bundled macOS zmx
    "Zmx/ZmxResizePropagationTests.swift", // runs the bundled macOS zmx
    "Zmx/ZmxSurvivalIntegrationTests.swift", // runs the bundled macOS zmx
]
let appleTargets: Set<String> = ["GhosttyKit", "GhosttyTerminal", "GhosttyTerminalTests", "libghostty", "AppcastUpdater", "appcast-updater", "AppcastUpdaterTests", "Graftty", "GrafttyCommandUI", "GrafttyCommandUITests", "GrafttyMobileKit",
                               "GrafttyMobileKitTests", "GrafttyTests", "OwnershipModelTests", "GrafttyRemoteClientTests",
                               "GrafttyRemoteTestSupport"]

let package = Package(
    name: "Graftty",
    defaultLocalization: "en",
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
        .library(name: "GrafttyWindowsTerminal", targets: ["GrafttyWindowsTerminal"]),
        .library(name: "GrafttyRemoteClient", targets: ["GrafttyRemoteClient"]),
        .library(name: "GrafttyCommandUI", targets: ["GrafttyCommandUI"]),
        .library(name: "GrafttyMobileKit", targets: ["GrafttyMobileKit"]),
        // Test-only: the iOS test bundles (Apps/GrafttyMobile/project.yml)
        // can link a package product, not a bare target.
        .library(name: "GrafttyRemoteTestSupport", targets: ["GrafttyRemoteTestSupport"]),
    ] as [Product]).filter { !isLinux || !["appcast-updater", "Graftty", "GrafttyCommandUI", "GrafttyMobileKit", "GrafttyRemoteTestSupport"].contains($0.name) },
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        // REMOTE-9.26: SSHChannelWindow mirrors this release line's 64-packet window.
        .package(url: "https://github.com/apple/swift-nio-ssh.git", .upToNextMinor(from: "0.15.1")),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.26.0"),
        .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.22.0"),
        .package(url: "https://github.com/stencilproject/Stencil.git", from: "0.15.1"),
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", exact: "1.0.2"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", revision: "b9778b054bbdbf2e81deef0494ffecb8683c1e4a"),
    ] + appleDependencies,
    targets: ([
        .target(name: "CGrafttyConPTY"),
        .target(
            name: "GrafttyWindowsTerminal",
            dependencies: [.target(name: "CGrafttyConPTY", condition: .when(platforms: [.windows]))],
            swiftSettings: strictWarnings
        ),
        .testTarget(
            name: "GrafttyWindowsTerminalTests",
            dependencies: ["GrafttyWindowsTerminal"],
            swiftSettings: strictWarnings
        ),
        .testTarget(name: "GrafttyWindowsTransportTests", dependencies: [
            "GrafttyTunnel",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOSSH", package: "swift-nio-ssh"),
            .product(name: "Crypto", package: "swift-crypto"),
        ], swiftSettings: strictWarnings),
        .target(
            name: "GrafttyProtocol",
            dependencies: cryptoDependencies,
            exclude: isLinux ? ["UI"] : [],
            swiftSettings: strictWarnings
        ),
        .target(
            name: "GrafttyCommandUI",
            dependencies: ["GrafttyProtocol"],
            resources: [.process("Resources")],
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
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Stencil", package: "Stencil"),
            ] + appleKitDependencies + cryptoDependencies + containerProcessDependencies,
            exclude: isLinux ? linuxKitExclusions : [],
            resources: [
                .copy("Web/Resources"),
                .copy("AgentPlugins"),
                .copy("HostSetup/Resources/linux-install.sh"),
                .copy("Teams/Resources/codex-wrapper.sh"),
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
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOExtras", package: "swift-nio-extras"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
            ] + webRTCDependencies,
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
                "GhosttyKit",
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
                "GrafttyRemoteClient",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: strictWarnings
        ),
        .executableTarget(
            name: "appcast-updater",
            dependencies: ["AppcastUpdater"],
            swiftSettings: strictWarnings
        ),
        // Shared test scaffolding (#477). Foundation-only so any test target
        // can link it; Kit-dependent doubles live in GrafttyKitTestSupport.
        .target(
            name: "GrafttyTestSupport",
            path: "Tests/GrafttyTestSupport",
            swiftSettings: strictWarnings
        ),
        // The loopback WebRTC peer shared by the GrafttyRemoteClient and
        // GrafttyMobileKit test targets (#477).
        .target(
            name: "GrafttyRemoteTestSupport",
            dependencies: ["GrafttyRemoteClient", "GrafttyTunnel"] + webRTCDependencies,
            path: "Tests/GrafttyRemoteTestSupport",
            swiftSettings: strictWarnings
        ),
        .target(
            name: "GrafttyKitTestSupport",
            dependencies: ["GrafttyKit"],
            path: "Tests/GrafttyKitTestSupport",
            swiftSettings: strictWarnings
        ),
        .testTarget(
            name: "GrafttyTunnelTests",
            dependencies: ["GrafttyTunnel", .product(name: "NIOCore", package: "swift-nio"),
                           .product(name: "NIOPosix", package: "swift-nio"),
                           .product(name: "NIOEmbedded", package: "swift-nio"),
                           .product(name: "NIOSSH", package: "swift-nio-ssh")],
            swiftSettings: strictWarnings
        ),
        .testTarget(
            name: "GrafttyHostTests",
            dependencies: ["GrafttyHost", "GrafttyRemoteClient", "GrafttyKit", "GrafttyProtocol"] + cryptoDependencies,
            swiftSettings: strictWarnings
        ),
        .testTarget(
            name: "GrafttyProtocolTests",
            dependencies: ["GrafttyProtocol", "GrafttyTestSupport"] + cryptoDependencies,
            exclude: isLinux ? ["UI", "WorktreePanesTests.swift"] : [],
            resources: [.copy("Fixtures")],
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
            dependencies: ["GrafttyKit", "GrafttyProtocol", "GrafttyTestSupport", "GrafttyKitTestSupport",
                           .product(name: "NIOEmbedded", package: "swift-nio")] + cryptoDependencies,
            exclude: isLinux ? ["Apple"] + linuxPendingKitTests : [],
            resources: [
                .process("Hosting/Fixtures"),
                .copy("Web/Fixtures"),
            ],
            swiftSettings: strictWarnings
        ),
        .binaryTarget(name: "libghostty", path: ".deps/GhosttyKit.xcframework"),
        .target(
            name: "GhosttyKit",
            dependencies: ["libghostty"],
            swiftSettings: ghosttySwiftSettings,
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Carbon", .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "GhosttyTerminal",
            dependencies: ["GhosttyKit", .product(name: "DisplayLink", package: "DisplayLink")],
            resources: [
                .copy("Resources/Ghostty"),
                .copy("Resources/terminfo"),
                .process("Resources/Localizable.xcstrings"),
            ],
            swiftSettings: ghosttySwiftSettings
        ),
        .testTarget(
            name: "GhosttyTerminalTests",
            dependencies: ["GhosttyKit", "GhosttyTerminal"],
            swiftSettings: ghosttySwiftSettings
        ),
        .target(
            name: "GrafttyMobileKit",
            dependencies: [
                "GrafttyRemoteClient",
                "GrafttyProtocol",
                "GrafttyCommandUI",
                .product(name: "NIO", package: "swift-nio"),
                "GhosttyTerminal",
            ],
            swiftSettings: strictWarnings
        ),
        .testTarget(
            name: "GrafttyMobileKitTests",
            dependencies: ["GrafttyMobileKit", "GrafttyRemoteTestSupport"],
            swiftSettings: strictWarnings
        ),
        .testTarget(
            name: "GrafttyRemoteClientTests",
            dependencies: [
                "GrafttyRemoteClient",
                "GrafttyRemoteTestSupport",
                "GrafttyTunnel",
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
            dependencies: ["Graftty", "GrafttyCLI", "GrafttyTestSupport", "GrafttyKitTestSupport", "GrafttyRemoteTestSupport"],
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
            sources: ["DirectSSHLoopbackTests.swift", "AWSLiveHostTests.swift", "AWSLiveMCPTests.swift", "AWSLiveMCPContainerTests.swift"],
            swiftSettings: strictWarnings
        ),
    ] : []),
    swiftLanguageModes: [.v5]
)
#endif
