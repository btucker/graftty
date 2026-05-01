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
    /// One-stop factory for the `URLSessionWebSocketClient` + `SessionClient`
    /// pair. Both `SingleSessionView` (initial / re-dial) and
    /// `WorktreeDetailView` (preview pool) need the same triplet — URL
    /// composition + WS construction + SessionClient binding.
    static func live(baseURL: URL, sessionName: String) -> SessionClient {
        let wsURL = RootView.makeWebSocketURL(base: baseURL, session: sessionName)
        let ws = URLSessionWebSocketClient(url: wsURL)
        return SessionClient(sessionName: sessionName, webSocket: ws)
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
