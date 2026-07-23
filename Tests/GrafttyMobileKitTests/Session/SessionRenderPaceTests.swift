#if canImport(UIKit)
import Foundation
import GhosttyTerminal
import Testing
@testable import GrafttyMobileKit

@Suite
@MainActor
struct SessionRenderPaceTests {
    final class IdleWS: WebSocketClient, @unchecked Sendable {
        func send(_ frame: WebSocketFrame) async throws {}
        func receive() async throws -> WebSocketFrame {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            throw CancellationError()
        }
        func close() {}
    }

    func quiesce() async {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    func makeStartedClient(clock: VirtualClock) async -> SessionClient {
        let client = SessionClient(
            sessionName: "s",
            webSocketFactory: { IdleWS() },
            clock: clock,
            backoffSchedule: [1]
        )
        client.start()
        await quiesce()
        return client
    }

    @Test("""
    @spec IOS-10.8: While a terminal session has received no output or user interaction for 5 seconds, the application shall reduce that surface's render pace to at most one frame per second while keeping the surface mounted.
    """)
    func quietSessionReducesRenderPace() async {
        let clock = VirtualClock()
        let client = await makeStartedClient(clock: clock)
        defer { client.stop() }

        #expect(client.renderPace == .full)
        clock.advance(by: SessionClient.renderPaceQuietDelay + 0.1)
        await quiesce()

        #expect(client.renderPace == .reduced(interval: SessionClient.reducedRenderPaceInterval))
    }

    @Test("""
    @spec IOS-10.9: When output, input, or a touch arrives while a surface is render-reduced, the application shall restore full render pace immediately.
    """)
    func activityRestoresFullPace() async {
        let clock = VirtualClock()
        let client = await makeStartedClient(clock: clock)
        defer { client.stop() }

        clock.advance(by: SessionClient.renderPaceQuietDelay + 0.1)
        await quiesce()
        #expect(client.renderPace != .full)

        client.wakeRenderer()
        #expect(client.renderPace == .full)

        // Re-arms: goes quiet again after another full quiet window.
        clock.advance(by: SessionClient.renderPaceQuietDelay + 0.1)
        await quiesce()
        #expect(client.renderPace == .reduced(interval: SessionClient.reducedRenderPaceInterval))
    }

    @Test func activityBeforeDeadlineKeepsFullPace() async {
        let clock = VirtualClock()
        let client = await makeStartedClient(clock: clock)
        defer { client.stop() }

        clock.advance(by: 3)
        client.wakeRenderer()
        await quiesce()
        clock.advance(by: 3)
        await quiesce()

        #expect(client.renderPace == .full)   // only 3s since last activity
    }
}
#endif
