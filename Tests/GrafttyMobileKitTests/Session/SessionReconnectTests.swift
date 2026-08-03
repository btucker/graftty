#if canImport(UIKit)
import CryptoKit
import Foundation
import Testing
@testable import GrafttyMobileKit
import GrafttyProtocol

@Suite
@MainActor
struct SessionReconnectTests {

    final class FailingWS: WebSocketClient, @unchecked Sendable {
        func send(_ frame: WebSocketFrame) async throws {}
        func receive() async throws -> WebSocketFrame {
            throw URLError(.networkConnectionLost)
        }
        func close() {}
    }

    final class IdleWS: WebSocketClient, @unchecked Sendable {
        func send(_ frame: WebSocketFrame) async throws {}
        func receive() async throws -> WebSocketFrame {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            throw CancellationError()
        }
        func close() {}
    }

    final class EndedWS: WebSocketClient, @unchecked Sendable {
        func send(_ frame: WebSocketFrame) async throws {}
        func receive() async throws -> WebSocketFrame {
            throw TerminalSessionClient.ClientError.sessionEnded(exitStatus: 0)
        }
        func close() {}
    }

    final class FactoryRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _creations = 0
        var creations: Int { lock.withLock { _creations } }
        var nextProvider: @Sendable () -> WebSocketClient = { IdleWS() }
        func make() -> WebSocketClient {
            lock.withLock {
                _creations += 1
                return nextProvider()
            }
        }
    }

    /// Wait briefly so the spawned receive Task reaches the await point.
    /// 50ms is plenty for an in-memory factory call + one async hop.
    func quiesce() async {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    /// Waits for an async state transition without assuming a fixed amount of
    /// scheduler progress. Simulator startup and CryptoKit key construction
    /// can make the remote-provider path take longer than `quiesce()` on CI.
    func waitUntil(
        timeout: TimeInterval = 2.0,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @Test("""
    @spec IOS-7.4: On authenticated terminal-channel failure for a pane whose session name is still present in the latest paired panes-state snapshot, the application shall display a per-pane "disconnected" banner with "Reconnect" and "Back to worktrees" buttons. While the host view is visible, the application shall retry automatically with exponential backoff: the delay starts at 1 second, doubles after each successive failure, and is capped at 30 seconds. Each successful connect resets the delay to 1 second. When the host view is not visible, no automatic retry shall occur.
    """)
    func receiveErrorTransitionsToReconnecting() async throws {
        let clock = VirtualClock()
        let factory = FactoryRecorder()
        factory.nextProvider = { FailingWS() }
        let client = SessionClient(
            sessionName: "s",
            webSocketFactory: factory.make,
            clock: clock,
            backoffSchedule: [1, 2, 4, 8, 16, 30]
        )
        defer { client.stop() }
        client.start()
        await quiesce()
        #expect(client.connectionState == .reconnecting(attempt: 1))
        #expect(factory.creations == 1)
    }

    @Test("""
    @spec IOS-7.5: When the host reports that a live terminal process reached EOF, the iPad application shall mark that pane ended and shall not reconnect its terminal channel. Clean process exit is distinct from the retryable authenticated-channel failures in `IOS-7.4`; reattaching after EOF can recreate the zmx session before the host removes the pane from its authoritative split tree.
    """)
    func cleanTerminalExitStopsWithoutReconnect() async throws {
        let clock = VirtualClock()
        let factory = FactoryRecorder()
        factory.nextProvider = { EndedWS() }
        let client = SessionClient(
            sessionName: "s",
            webSocketFactory: factory.make,
            clock: clock,
            backoffSchedule: [1, 2, 4]
        )
        defer { client.stop() }
        client.start()
        await quiesce()

        #expect(client.connectionState == .ended)
        #expect(factory.creations == 1)
        clock.advance(by: 30)
        await quiesce()
        #expect(factory.creations == 1)
    }

    @Test
    func backoffEscalatesAcrossRepeatedFailures() async throws {
        let clock = VirtualClock()
        let factory = FactoryRecorder()
        factory.nextProvider = { FailingWS() }
        let client = SessionClient(
            sessionName: "s",
            webSocketFactory: factory.make,
            clock: clock,
            backoffSchedule: [1, 2, 4]
        )
        defer { client.stop() }
        client.start()
        await quiesce()
        // After first failure, attempt 1 with 1s delay pending.
        #expect(client.connectionState == .reconnecting(attempt: 1))
        clock.advance(by: 1.0)
        await quiesce()
        // Second WS attempted, fails, attempt 2 with 2s delay pending.
        #expect(client.connectionState == .reconnecting(attempt: 2))
        #expect(factory.creations == 2)
        clock.advance(by: 2.0)
        await quiesce()
        #expect(client.connectionState == .reconnecting(attempt: 3))
        #expect(factory.creations == 3)
    }

    @Test
    func successfulConnectResetsAttemptCounter() async throws {
        let clock = VirtualClock()
        let factory = FactoryRecorder()
        var calls = 0
        factory.nextProvider = {
            calls += 1
            return calls == 1 ? FailingWS() : IdleWS()
        }
        let client = SessionClient(
            sessionName: "s",
            webSocketFactory: factory.make,
            clock: clock,
            backoffSchedule: [1, 2, 4]
        )
        defer { client.stop() }
        client.start()
        await quiesce()
        #expect(client.connectionState == .reconnecting(attempt: 1))
        clock.advance(by: 1.0)
        await quiesce()
        // Second WS is IdleWS — receive parks → state is .live.
        #expect(client.connectionState == .live)
    }

    @Test
    func forceReconnectNowCancelsBackoffSleep() async throws {
        let clock = VirtualClock()
        let factory = FactoryRecorder()
        factory.nextProvider = { FailingWS() }
        let client = SessionClient(
            sessionName: "s",
            webSocketFactory: factory.make,
            clock: clock,
            backoffSchedule: [30]  // long enough we won't auto-trigger
        )
        defer { client.stop() }
        client.start()
        await quiesce()
        #expect(client.connectionState == .reconnecting(attempt: 1))
        let beforeForce = factory.creations
        client.forceReconnectNow()
        await quiesce()
        #expect(factory.creations == beforeForce + 1)
    }

    @Test
    func stopDuringBackoffCancelsCleanly() async throws {
        let clock = VirtualClock()
        let factory = FactoryRecorder()
        factory.nextProvider = { FailingWS() }
        let client = SessionClient(
            sessionName: "s",
            webSocketFactory: factory.make,
            clock: clock,
            backoffSchedule: [10]  // long enough we'd never reach it
        )
        client.start()
        await quiesce()
        #expect(client.connectionState == .reconnecting(attempt: 1))
        client.stop()
        await quiesce()
        // No additional factory calls after stop.
        let snapshot = factory.creations
        clock.advance(by: 10.0)
        await quiesce()
        #expect(factory.creations == snapshot)
    }

    // MARK: - W3 Task 4 / Task-3 finding 1: per-dial coordinator re-consult

    /// Builds a `RemoteHostConnection` that was never negotiated —
    /// `openTerminalSession` throws `ConnectionError.notConnected`
    /// synchronously (no networking, no WebRTC handshake), which is
    /// exactly what a connection looks like once
    /// `RemoteConnectionCoordinator.invalidate(host:)` has torn it down
    /// out from under a still-dialing `SessionClient`.
    private nonisolated static func makeDeadConnection() -> RemoteHostConnection {
        let key = Curve25519.Signing.PrivateKey()
        let fingerprint = RemoteIdentityFingerprint(
            of: try! RemoteIdentityPublicKey(rawRepresentation: key.publicKey.rawRepresentation)
        )
        return RemoteHostConnection(clientKey: key, expectedHostFingerprint: fingerprint)
    }

    /// Thread-safe counter recording how many times
    /// `remoteConnectionProvider` was invoked. Each call returns a FRESH
    /// dead connection (never the same instance twice) — mirroring what
    /// `RemoteConnectionCoordinator.connection(for:)` does after an
    /// eviction: hand back a newly negotiated (here: newly *constructed*,
    /// deliberately never negotiated) connection rather than the same
    /// stale one.
    private final class ProviderRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _invocationCount = 0
        var invocationCount: Int { lock.withLock { _invocationCount } }

        func provide() async -> RemoteHostConnection? {
            lock.withLock { _invocationCount += 1 }
            return makeDeadConnection()
        }
    }

    @Test("""
    W3 Task 4 (closes Task-3 finding 1, HIGH): `SessionClient.live`'s `remoteConnectionProvider` shall be re-consulted on EVERY dial the internal backoff loop performs, not resolved once and baked into the WebSocket factory closure — the prior behavior redialed a dead `RemoteHostConnection` forever, recoverable only by an external re-dial (a scenePhase flip).
    """)
    func remoteConnectionProviderIsReconsultedOnEveryBackoffAttempt() async throws {
        let clock = VirtualClock()
        let provider = ProviderRecorder()
        let client = SessionClient.live(
            baseURL: URL(string: "http://example.invalid")!,
            sessionName: "s",
            remoteConnectionProvider: { await provider.provide() },
            clock: clock,
            backoffSchedule: [1, 2, 4]
        )
        defer { client.stop() }
        client.start()
        await waitUntil {
            provider.invocationCount == 1 &&
                client.connectionState == .reconnecting(attempt: 1) &&
                clock.hasPendingSleep(for: 1.0)
        }
        // First dial: the provider hands back a dead connection whose
        // `openTerminalSession` throws immediately, feeding the same
        // backoff path a plain socket failure would.
        #expect(provider.invocationCount == 1)
        #expect(client.connectionState == .reconnecting(attempt: 1))
        #expect(
            clock.hasPendingSleep(for: 1.0),
            "the first backoff sleep must be registered before time advances"
        )

        clock.advance(by: 1.0)
        await waitUntil {
            provider.invocationCount == 2 &&
                client.connectionState == .reconnecting(attempt: 2) &&
                clock.hasPendingSleep(for: 2.0)
        }
        // Second dial. Before this fix, the connection resolved for the
        // FIRST dial was captured by value in the factory closure and
        // reused forever — this asserts the provider closure itself,
        // not a cached connection, is what `SessionClient`'s backoff
        // loop calls on every attempt.
        #expect(provider.invocationCount == 2, "the provider must be asked again on the second dial, not just the first")
        #expect(client.connectionState == .reconnecting(attempt: 2))
        #expect(
            clock.hasPendingSleep(for: 2.0),
            "the second backoff sleep must be registered before time advances"
        )

        clock.advance(by: 2.0)
        await waitUntil {
            provider.invocationCount == 3 &&
                client.connectionState == .reconnecting(attempt: 3) &&
                clock.hasPendingSleep(for: 4.0)
        }
        #expect(provider.invocationCount == 3, "and again on the third dial")
        #expect(client.connectionState == .reconnecting(attempt: 3))
    }
}
#endif
