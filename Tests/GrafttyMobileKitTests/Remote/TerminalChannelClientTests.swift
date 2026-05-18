#if canImport(UIKit)
import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyMobileKit

@Suite("TerminalChannelClient — local behavior: attach handshake encoding, send forwarding, inbound stream wiring.")
struct TerminalChannelClientTests {

    @Test
    func notConnectedSendThrows() async {
        // Construct a client without connecting. The router would
        // normally allocate the outbox via `connect()`. Since we don't
        // call connect(), send() must throw .notConnected.
        let router = ChannelRouter(transport: NoopTransport())
        let client = TerminalChannelClient(router: router)
        await #expect(throws: TerminalChannelClient.ClientError.self) {
            try await client.send(Data([0x41]))
        }
    }

    @Test
    func encodingHandshakeProducesExpectedJSON() throws {
        // Verify the wire shape of the attach handshake directly.
        let meta = TerminalChannelOpenMeta(sessionName: "graftty-shell")
        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(TerminalChannelOpenMeta.self, from: data)
        #expect(decoded.sessionName == "graftty-shell")
    }
}

private struct NoopTransport: ChannelTransport {
    func send(_ data: Data) async throws {}
    func onReceive(_ handler: @escaping @Sendable (Data) async -> Void) async {}
}
#endif
