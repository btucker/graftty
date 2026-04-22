#if canImport(UIKit)
import Foundation
import Testing
@testable import GrafttyMobileKit
import GrafttyProtocol

@Suite
@MainActor
struct SessionClientTests {

    final class FakeWS: WebSocketClient, @unchecked Sendable {
        var sent: [WebSocketFrame] = []
        var closed = false
        func send(_ frame: WebSocketFrame) async throws { sent.append(frame) }
        func receive() async throws -> WebSocketFrame {
            try await Task.sleep(nanoseconds: 10_000_000_000)
            throw CancellationError()
        }
        func close() { closed = true }
    }

    @Test
    func sendingBytesFromTerminalGoesOutAsBinary() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocket: ws)
        defer { client.stop() }
        // Simulate libghostty surface emitting bytes.
        client.session.sendInput(Data([0x68, 0x69]))   // "hi"
        // Allow the spawned Task to run.
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(ws.sent.contains(.binary(Data([0x68, 0x69]))))
    }

    @Test
    func sendResizeGoesOutAsJSONTextFrame() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocket: ws)
        defer { client.stop() }
        client.sendResize(cols: 100, rows: 30)
        try await Task.sleep(nanoseconds: 100_000_000)
        guard case .text(let payload) = ws.sent.first else {
            Issue.record("expected text frame first")
            return
        }
        let envelope = try WebControlEnvelope.parse(Data(payload.utf8))
        #expect(envelope == .resize(cols: 100, rows: 30))
    }

    @Test
    func stopClosesWebSocket() {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocket: ws)
        client.stop()
        #expect(ws.closed)
    }
}
#endif
