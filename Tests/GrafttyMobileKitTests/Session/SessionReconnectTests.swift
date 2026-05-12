#if canImport(UIKit)
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

    @Test("""
    @spec IOS-7.4: On WebSocket failure (upgrade failure, read/write error, or close frame not initiated by the app) for a pane whose session name is still listed in `/sessions`, the application shall display a per-pane "disconnected" banner with "Reconnect" and "Back to sessions" buttons. While the host view is visible, the application shall retry automatically with exponential backoff: the delay starts at 1 second, doubles after each successive failure, and is capped at 30 seconds. Each successful connect resets the delay to 1 second. When the host view is not visible, no automatic retry shall occur.
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
}
#endif
