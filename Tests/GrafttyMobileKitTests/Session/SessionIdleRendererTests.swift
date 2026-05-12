#if canImport(UIKit)
import Foundation
import Testing
@testable import GrafttyMobileKit

@Suite
@MainActor
struct SessionIdleRendererTests {

    final class IdleWS: WebSocketClient, @unchecked Sendable {
        func send(_ frame: WebSocketFrame) async throws {}
        func receive() async throws -> WebSocketFrame {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            throw CancellationError()
        }
        func close() {}
    }

    func quiesce() async { try? await Task.sleep(nanoseconds: 50_000_000) }

    @Test("""
    @spec IOS-10.3: When a `SessionClient` has received no PTY bytes and processed no user input for ≥ `idleThreshold` (default 30s), the application shall transition its `renderActivity` to `.idle`.
    """)
    func renderActivityFlipsToIdleAfterThreshold() async throws {
        let clock = VirtualClock()
        let client = SessionClient(
            sessionName: "s",
            webSocketFactory: { IdleWS() },
            clock: clock,
            idleThreshold: 30,
            idleCheckInterval: 5
        )
        defer { client.stop() }
        client.start()
        await quiesce()
        #expect(client.renderActivity == .active)
        clock.advance(by: 31)
        await quiesce()
        #expect(client.renderActivity == .idle)
    }

    @Test
    func userInputBumpsActivityAndKeepsActive() async throws {
        let clock = VirtualClock()
        let client = SessionClient(
            sessionName: "s",
            webSocketFactory: { IdleWS() },
            clock: clock,
            idleThreshold: 30,
            idleCheckInterval: 5
        )
        defer { client.stop() }
        client.start()
        await quiesce()
        clock.advance(by: 28)
        await quiesce()
        client.sendEscape()
        await quiesce()
        clock.advance(by: 28)
        await quiesce()
        #expect(client.renderActivity == .active)
    }

    @Test("""
    @spec IOS-10.5: When a `SessionClient` is `.idle` and a new PTY byte is received, the application shall transition its `renderActivity` to `.active` and remount `TerminalPaneView` within one runloop tick.
    """)
    func wakeRendererFlipsBackToActive() async throws {
        let clock = VirtualClock()
        let client = SessionClient(
            sessionName: "s",
            webSocketFactory: { IdleWS() },
            clock: clock,
            idleThreshold: 30,
            idleCheckInterval: 5
        )
        defer { client.stop() }
        client.start()
        await quiesce()
        clock.advance(by: 31)
        await quiesce()
        #expect(client.renderActivity == .idle)
        client.wakeRenderer()
        await quiesce()
        #expect(client.renderActivity == .active)
    }

    @Test
    func stopCancelsIdleWatchdog() async throws {
        let clock = VirtualClock()
        let client = SessionClient(
            sessionName: "s",
            webSocketFactory: { IdleWS() },
            clock: clock,
            idleThreshold: 30,
            idleCheckInterval: 5
        )
        client.start()
        await quiesce()
        client.stop()
        await quiesce()
        let pending = clock.pendingSleepCount
        clock.advance(by: 100)
        await quiesce()
        #expect(clock.pendingSleepCount <= pending)
    }
}
#endif
