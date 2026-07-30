import GrafttyProtocol
import GrafttyRemoteClient
import SwiftUI
import os

#if canImport(UIKit)
private struct BiometricGateKey: EnvironmentKey {
    static let defaultValue: BiometricGate? = nil
}

extension EnvironmentValues {
    var biometricGate: BiometricGate? {
        get { self[BiometricGateKey.self] }
        set { self[BiometricGateKey.self] = newValue }
    }
}

@MainActor
extension Optional where Wrapped == BiometricGate {
    /// `nil` (no gate injected — preview / test contexts) defaults to
    /// "unlocked" so headless surfaces aren't perpetually blocked.
    /// Production code always injects a real gate via RootView.
    var isUnlocked: Bool {
        (self?.state ?? .unlocked) == .unlocked
    }
}

extension SessionClient {
    /// @spec IOS-10.6
    /// Preview-role clients use a tighter idle threshold so quiet panes
    /// release their libghostty display link (via the IOS-10.4 static
    /// snapshot) quickly. 10s gives bursty processes (build watchers,
    /// log tailers ticking every few seconds) enough hysteresis to
    /// stay live without churning surface tear-down + recreation.
    public nonisolated static let previewIdleThreshold: TimeInterval = 10
    public nonisolated static let fullscreenIdleThreshold: TimeInterval = .infinity

    /// Quiet window before a mounted surface's render pace drops to
    /// `.reduced` (~1 fps). Distinct from `idleThreshold`, which
    /// unmounts the surface entirely (previews only).
    public nonisolated static let renderPaceQuietDelay: TimeInterval = 5
    public nonisolated static let reducedRenderPaceInterval: TimeInterval = 1.0

    /// One-stop factory for the terminal transport + `SessionClient`
    /// pair. Both `SingleSessionView` (initial / re-dial) and
    /// `WorktreeDetailView` (preview pool) need the same triplet — URL
    /// composition + WS construction + SessionClient binding.
    ///
    /// `remoteConnectionProvider`, when non-nil, is invoked FRESH on
    /// EVERY dial — not just the first. `SessionClient`'s internal
    /// backoff loop (`spawnOpenTask`) re-invokes `webSocketFactory` on
    /// every reconnect attempt; before this, callers resolved
    /// `coordinator.connection(for:)` once and baked the resulting
    /// (possibly-since-invalidated) `RemoteHostConnection` into the
    /// factory closure, so a dead connection was redialed forever —
    /// only an external re-dial (a scenePhase flip) could recover.
    /// Consulting the provider per-dial means a degraded connection
    /// heals transparently: the coordinator negotiates a fresh
    /// `RemoteHostConnection` (fresh WebRTC + fresh SSH userauth) the
    /// next time the provider is asked. When the provider returns nil
    /// (no coordinator, host unpaired, or negotiation failed) the
    /// factory fails closed. The legacy `/ws` transport remains available
    /// only through an explicit test/compatibility opt-in; production device
    /// pairing never silently downgrades after authentication fails.
    ///
    /// `clock` / `backoffSchedule` default to `SessionClient`'s own
    /// `productionClock()` / `productionBackoffSchedule()` — the single
    /// source both this default and `SessionClient.init`'s own default
    /// read from, so the two never drift independently; tests override
    /// them (e.g. `VirtualClock` + a short schedule) to drive the backoff
    /// loop deterministically while still exercising this factory's real
    /// `remoteConnectionProvider` re-consultation logic instead of a
    /// hand-rolled substitute.
    static func live(
        baseURL: URL,
        sessionName: String,
        role: Role = .fullscreen,
        remoteConnectionProvider: (@Sendable () async -> RemoteHostConnection?)? = nil,
        allowLegacyWebSocketFallback: Bool =
            legacyWebSocketFallbackEnabledByDefault,
        reclaimControlOnOwnerlessConnect: Bool = false,
        clock: any Clock = SessionClient.productionClock(),
        backoffSchedule: [TimeInterval] = SessionClient.productionBackoffSchedule()
    ) -> SessionClient {
        SessionClient(
            sessionName: sessionName,
            webSocketFactory: {
                if let remoteHost = await remoteConnectionProvider?() {
                    return try await remoteHost.openTerminalSession(sessionName: sessionName)
                }
                if sessionName.hasPrefix("relay-pane-") {
                    throw RemoteSessionTransportError
                        .relayRequiresPairedConnection
                }
                guard allowLegacyWebSocketFallback else {
                    throw RemoteSessionTransportError
                        .pairedConnectionUnavailable
                }
                let wsURL = RootView.makeWebSocketURL(base: baseURL, session: sessionName)
                return URLSessionWebSocketClient(url: wsURL)
            },
            clock: clock,
            backoffSchedule: backoffSchedule,
            idleThreshold: role == .preview ? previewIdleThreshold : fullscreenIdleThreshold,
            role: role,
            reclaimControlOnOwnerlessConnect: reclaimControlOnOwnerlessConnect
        )
    }

    /// Security-sensitive production default. Tests that specifically cover
    /// the retired WebSocket transport must opt in at the call site.
    public nonisolated static let legacyWebSocketFallbackEnabledByDefault =
        false
}

enum RemoteSessionTransportError: LocalizedError, Equatable {
    case relayRequiresPairedConnection
    case pairedConnectionUnavailable

    var errorDescription: String? {
        switch self {
        case .relayRequiresPairedConnection:
            return "Remote Mac panes require an active paired connection."
        case .pairedConnectionUnavailable:
            return "The authenticated connection to this paired Mac is unavailable."
        }
    }
}

/// Shared home for authenticated connection observability.
private let remoteWiringLogger = Logger(
    subsystem: "com.quotably.graftty",
    category: "remote-wiring"
)

/// Builds the `remoteConnectionProvider` closure `SessionClient.live`
/// consults on every dial: asks `coordinator.connection(for: host)`
/// FRESH every time it's invoked. A nil result is terminal-transport
/// unavailability, never permission to downgrade to `/ws`. Shared by
/// `SingleSessionView` (fullscreen) and `WorktreeDetailView`'s preview
/// pool so both surfaces get the same per-dial re-negotiation behavior
/// AND the same fail-closed logging from one place — the preview pool was
/// previously silent on this path.
///
/// Written as a free function with an explicit `if let` rather than
/// `coordinator.map { ... }` returning the closure: `Optional.map`'s
/// generic return type isn't recognized as `@Sendable` at the call site,
/// which trips "converting non-Sendable function value" under the iOS
/// build's stricter concurrency checking (this file's `#if
/// canImport(UIKit)` gate means that mismatch is invisible to a bare
/// `swift build`/`swift test` on macOS, where UIKit isn't importable and
/// this whole file compiles to nothing — the iOS `xcodebuild` target is
/// what actually type-checks it).
@MainActor
func makeRemoteConnectionProvider(
    coordinator: RemoteConnectionCoordinator?,
    host: Host,
    sessionName: String
) -> @Sendable () async -> RemoteHostConnection? {
    { [weak coordinator] in
        guard let coordinator else {
            remoteWiringLogger.error(
                "no connection coordinator for paired host \(host.id, privacy: .public); refusing terminal session \(sessionName, privacy: .public)"
            )
            return nil
        }
        if let connection = await coordinator.connection(for: host) {
            return connection
        }
        remoteWiringLogger.warning(
            "authenticated connection unavailable for host \(host.id, privacy: .public); refusing terminal session \(sessionName, privacy: .public)"
        )
        return nil
    }
}

public typealias RemoteWorktreeSnapshotProvider =
    @MainActor @Sendable (
        RemoteWorktreeLoadProgress?
    ) async throws -> [WorktreePanes]

@MainActor
func makeRemoteWorktreeSnapshotProvider(
    coordinator: RemoteConnectionCoordinator?,
    host: Host
) -> RemoteWorktreeSnapshotProvider? {
    guard let coordinator else { return nil }
    return { [weak coordinator] onProgress in
        guard let coordinator else {
            throw RemoteConnectionCoordinator.ConnectionError.unavailable
        }
        return try await coordinator.worktreePanes(
            for: host,
            onProgress: onProgress
        )
    }
}

// MARK: - PaneEnvironment

/// Bundles the iPad-only pane-control façade riding the per-host
/// `RemoteHostConnection`'s SSH session. The coordinator separately owns
/// the one long-lived panes-state subscription consumed by
/// `WorktreeListContent`; opening one here as well would duplicate every
/// sidebar snapshot channel.
public struct PaneEnvironment: Sendable {
    public let paneControlClient: PaneControlClient?

    public static let empty = PaneEnvironment(paneControlClient: nil)

    public init(paneControlClient: PaneControlClient?) {
        self.paneControlClient = paneControlClient
    }

    public func close() async {
        await paneControlClient?.close()
    }
}

/// Constructs a `PaneEnvironment` over the supplied per-host
/// `RemoteHostConnection`. Returns `.empty` when `remoteHost` is nil
/// (host unpaired, or negotiation failed — either size class) or when
/// pane-control subsystem fails to open.
public func buildPaneEnvironment(remoteHost: RemoteHostConnection?) async -> PaneEnvironment {
    guard let remoteHost else { return .empty }
    var openedPaneControlClient: PaneControlClient?
    do {
        let controlChannel = try await remoteHost.makePaneControlClient()
        let paneControlClient = PaneControlClient(driver: controlChannel)
        try await paneControlClient.open()
        openedPaneControlClient = paneControlClient

        return PaneEnvironment(paneControlClient: paneControlClient)
    } catch {
        await openedPaneControlClient?.close()
        return .empty
    }
}
#endif

/// Re-dialing while locked would open authenticated channels behind the lock,
/// defeating the content-hiding guarantee. Takes a Bool rather than
/// the full `BiometricGate` so this stays platform-agnostic and
/// testable from `swift test` on macOS (where `BiometricGate` is
/// behind `canImport(UIKit)`).
public enum LiveSessionReadiness {
    public static func isActive(scene: ScenePhase, gateUnlocked: Bool) -> Bool {
        scene == .active && gateUnlocked
    }

    /// @spec IOS-10.1
    /// Returns true when the application should release WSes and unmount
    /// live terminal views. `.inactive` is included so that lock-screen
    /// pulls / Control Center / app-switcher windows don't keep
    /// libghostty's display link ticking at 120 Hz.
    public static func shouldTearDown(scene: ScenePhase) -> Bool {
        scene == .inactive || scene == .background
    }
}

/// Rehydration decision after the post-foreground paired panes snapshot.
/// A transport failure resolves to `.dial` so a transient network blip
/// doesn't strand the user behind a non-retryable banner — terminal-channel
/// failure handling deals with the genuinely-broken case.
public enum SessionRehydration {
    public enum Decision: Equatable {
        case dial
        case ended
    }

    public static func decide(
        sessionName: String,
        worktreesResult: Result<[WorktreePanes], Error>
    ) -> Decision {
        switch worktreesResult {
        case .success(let worktrees):
            let stillExists = worktrees.contains { worktree in
                worktree.layout?.leaves.contains {
                    $0.sessionName == sessionName
                } == true
            }
            return stillExists ? .dial : .ended
        case .failure:
            return .dial
        }
    }
}
