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
    public nonisolated static let fullscreenIdleThreshold: TimeInterval = 30

    /// One-stop factory for the WebSocket transport + `SessionClient`
    /// pair. Both `SingleSessionView` (initial / re-dial) and
    /// `WorktreeDetailView` (preview pool) need the same triplet — URL
    /// composition + WS construction + SessionClient binding.
    ///
    /// When `remoteHost` is non-nil (iPad paired-host path), the factory
    /// opens an SSH terminal session over WebRTC via
    /// `RemoteHostConnection.openTerminalSession(sessionName:)`. When nil
    /// (iPhone path, or iPad before signaling lands), the factory falls
    /// back to a plain `URLSessionWebSocketClient` pointed at `/ws`.
    static func live(
        baseURL: URL,
        sessionName: String,
        role: Role = .fullscreen,
        remoteHost: RemoteHostConnection? = nil
    ) -> SessionClient {
        SessionClient(
            sessionName: sessionName,
            webSocketFactory: {
                if let remoteHost {
                    return try await remoteHost.openTerminalSession(sessionName: sessionName)
                }
                let wsURL = RootView.makeWebSocketURL(base: baseURL, session: sessionName)
                return URLSessionWebSocketClient(url: wsURL)
            },
            idleThreshold: role == .preview ? previewIdleThreshold : fullscreenIdleThreshold,
            role: role
        )
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
