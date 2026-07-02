import GrafttyProtocol
import SwiftUI

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

    /// One-stop factory for the WebSocket transport + `SessionClient`
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
    /// factory falls back to a plain `URLSessionWebSocketClient`
    /// pointed at `/ws`.
    ///
    /// `clock` / `backoffSchedule` default to `SessionClient`'s own
    /// production defaults; tests override them (e.g. `VirtualClock` +
    /// a short schedule) to drive the backoff loop deterministically
    /// while still exercising this factory's real
    /// `remoteConnectionProvider` re-consultation logic instead of a
    /// hand-rolled substitute.
    static func live(
        baseURL: URL,
        sessionName: String,
        role: Role = .fullscreen,
        remoteConnectionProvider: (@Sendable () async -> RemoteHostConnection?)? = nil,
        clock: any Clock = SystemClock(),
        backoffSchedule: [TimeInterval] = HostController.backoffSchedule(attempts: 6)
    ) -> SessionClient {
        SessionClient(
            sessionName: sessionName,
            webSocketFactory: {
                if let remoteHost = await remoteConnectionProvider?() {
                    return try await remoteHost.openTerminalSession(sessionName: sessionName)
                }
                let wsURL = RootView.makeWebSocketURL(base: baseURL, session: sessionName)
                return URLSessionWebSocketClient(url: wsURL)
            },
            clock: clock,
            backoffSchedule: backoffSchedule,
            idleThreshold: role == .preview ? previewIdleThreshold : fullscreenIdleThreshold,
            role: role
        )
    }
}

/// Builds the `remoteConnectionProvider` closure `SessionClient.live`
/// consults on every dial: `nil` when there's no coordinator to ask
/// (matches `SessionClient.live`'s own `/ws`-fallback default),
/// otherwise a closure that asks `coordinator.connection(for: host)`
/// FRESH every time it's invoked. Shared by `SingleSessionView`
/// (fullscreen) and `WorktreeDetailView`'s preview pool so both surfaces
/// get the same per-dial re-negotiation behavior from one place.
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
    host: Host
) -> (@Sendable () async -> RemoteHostConnection?)? {
    guard let coordinator else { return nil }
    return { [weak coordinator] in await coordinator?.connection(for: host) }
}

// MARK: - PaneEnvironment

/// Bundles the iPad-only pane façades that ride the per-host
/// `RemoteHostConnection`'s SSH session: a `WorktreePanesStore` for the
/// sidebar's worktree+pane snapshot, and a `PaneControlClient` for typed
/// `split`/`close`/`swap` RPCs. Both fields are `nil` on the iPhone path
/// (and on iPad before signaling has wired up a `RemoteHostConnection`),
/// where the existing `/ws` flow handles terminal traffic and there is
/// no SSH session to multiplex these subsystem channels onto. A future
/// iPhone cutover will populate them on that path too.
///
/// No UI surfaces consume these yet, and W3 Task 3 (wiring
/// `RemoteConnectionCoordinator` into `RootView`/`IPadRootLayout`/
/// `WorktreeDetailView`) re-checked this before threading a call site
/// through: `WorktreeListContent`'s sidebar still polls `GET
/// /worktrees/panes` over HTTP, and there is no pane-control (split/close/
/// swap) UI anywhere yet. Constructing a `PaneEnvironment` today with no
/// reader would just be a second flavor of dead plumbing (an
/// `EnvironmentKey` nothing reads, instead of a function nothing calls),
/// so the call site stays deferred to whichever future task adds the
/// sidebar/pane-control UI that actually reads `worktreePanesStore` /
/// `paneControlClient` — this remains infrastructure only, single-sourced
/// for that consumer to read from once it exists.
public struct PaneEnvironment: Sendable {
    public let worktreePanesStore: WorktreePanesStore?
    public let paneControlClient: PaneControlClient?

    public static let empty = PaneEnvironment(worktreePanesStore: nil, paneControlClient: nil)

    public init(
        worktreePanesStore: WorktreePanesStore?,
        paneControlClient: PaneControlClient?
    ) {
        self.worktreePanesStore = worktreePanesStore
        self.paneControlClient = paneControlClient
    }
}

/// Constructs a `PaneEnvironment` over the supplied per-host
/// `RemoteHostConnection`. Returns `.empty` when `remoteHost` is nil
/// (iPhone, or iPad before signaling lands) or when either subsystem
/// channel fails to open.
///
/// Construction shape: the channel client is built first with no-op
/// callbacks (via `RemoteHostConnection.makePanesStateClient`), then the
/// store is built around it as its driver, then `setCallbacks(...)`
/// backfills the closures pointing at the store, and finally
/// `store.subscribe()` performs the single SSH channel open. This avoids
/// the chicken-and-egg "store needs the client at init, client needs the
/// store in its callbacks" cycle without a placeholder-driver swap.
/// The `pane-control` side is simpler — `PaneControlChannelClient` has
/// no inbound callbacks at construction, so we build, wrap, and open in
/// one chain.
public func buildPaneEnvironment(remoteHost: RemoteHostConnection?) async -> PaneEnvironment {
    guard let remoteHost else { return .empty }
    do {
        // Build panes-state side: client first (with no-op callbacks),
        // then store, then backfill callbacks pointing at the store,
        // then store.subscribe() opens the SSH channel exactly once.
        let panesClient = try await remoteHost.makePanesStateClient(
            onSnapshot: { _ in },
            onClosed: { _ in }
        )
        let worktreePanesStore = WorktreePanesStore(driver: panesClient)
        panesClient.setCallbacks(
            onSnapshot: { [weak worktreePanesStore] snapshot in
                await worktreePanesStore?.applySnapshot(snapshot)
            },
            onClosed: { [weak worktreePanesStore] reason in
                await worktreePanesStore?.markClosed(reason: reason)
            }
        )
        try await worktreePanesStore.subscribe()

        // Build pane-control side: build client, wrap, open via the
        // PaneControlClient façade (which forwards to driver.open()).
        let controlChannel = try await remoteHost.makePaneControlClient()
        let paneControlClient = PaneControlClient(driver: controlChannel)
        try await paneControlClient.open()

        return PaneEnvironment(
            worktreePanesStore: worktreePanesStore,
            paneControlClient: paneControlClient
        )
    } catch {
        return .empty
    }
}
#endif

/// Re-dialing while locked would open WSes behind the lock overlay,
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

/// Rehydration decision after the post-foreground `/sessions` fetch.
/// A transport failure resolves to `.dial` so a transient network blip
/// doesn't strand the user behind a non-retryable banner — WS-level
/// failure handling deals with the genuinely-broken case.
public enum SessionRehydration {
    public enum Decision: Equatable {
        case dial
        case ended
    }

    public static func decide(
        sessionName: String,
        sessionsResult: Result<[SessionInfo], Error>
    ) -> Decision {
        switch sessionsResult {
        case .success(let sessions):
            return sessions.contains { $0.name == sessionName } ? .dial : .ended
        case .failure:
            return .dial
        }
    }
}
