#if canImport(UIKit)
import Foundation
import LocalAuthentication
import Observation

public protocol BiometricAuthenticator: Sendable {
    func authenticate() async -> Result<Void, Error>
}

public struct LocalAuthenticationAuthenticator: BiometricAuthenticator {
    public init() {}

    public func authenticate() async -> Result<Void, Error> {
        let context = LAContext()
        context.localizedFallbackTitle = "Use passcode"
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock Graftty"
            ) { ok, error in
                if ok { continuation.resume(returning: .success(())) }
                else { continuation.resume(returning: .failure(error ?? NSError(domain: "LA", code: -1))) }
            }
        }
    }
}

@Observable
@MainActor
public final class BiometricGate {

    public enum State: Equatable { case locked, unlocked }

    public private(set) var state: State = .locked

    private let clock: any Clock
    private let authenticator: any BiometricAuthenticator
    private let idleTimeout: TimeInterval
    private var backgroundedAt: Date?

    public init(
        clock: any Clock = SystemClock(),
        authenticator: any BiometricAuthenticator = LocalAuthenticationAuthenticator(),
        idleTimeout: TimeInterval = 5 * 60
    ) {
        self.clock = clock
        self.authenticator = authenticator
        self.idleTimeout = idleTimeout
    }

    public func authenticate() async {
        switch await authenticator.authenticate() {
        case .success:
            state = .unlocked
            backgroundedAt = nil
        case .failure:
            state = .locked
        }
    }

    public func applicationDidEnterBackground() {
        guard state == .unlocked else { return }
        backgroundedAt = clock.now
    }

    public func applicationWillEnterForeground() {
        guard let since = backgroundedAt else { return }
        if clock.now.timeIntervalSince(since) >= idleTimeout {
            state = .locked
        }
        backgroundedAt = nil
    }
}
#endif
