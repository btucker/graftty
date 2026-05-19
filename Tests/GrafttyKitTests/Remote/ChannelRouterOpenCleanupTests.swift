import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyKit

@Suite("ChannelRouter.open() — rolls back handlersByID on sendFrame failure.")
struct ChannelRouterOpenCleanupTests {

    @Test
    func failedOpenRemovesHandlerFromMap() async throws {
        let transport = FailingTransport()
        let router = ChannelRouter(transport: transport)
        let handler = RecordingHandler(channelType: "noop")

        await #expect(throws: Error.self) {
            try await router.open(type: "noop", handler: handler)
        }

        // After the failed open, an inbound `close(id=1)` frame must NOT
        // dispatch to the stranded handler. The router's internal `dispatch`
        // path is what would route a close, so we install the router's
        // receive callback then deliver a close frame manually.
        await router.start()
        let closeFrame = ChannelFrame.close(ChannelClose(id: ChannelID(1)))
        let bytes = try ChannelFrameCoder.encode(closeFrame)
        await transport.deliverInbound(bytes)
        let closed = await handler.closed
        #expect(closed == false, "handler should have been removed from handlersByID after sendFrame failure")
    }
}

private actor FailingTransport: ChannelTransport {
    struct SendError: Error { }
    private var inbound: (@Sendable (Data) async -> Void)?

    func send(_ data: Data) async throws { throw SendError() }

    func onReceive(_ handler: @escaping @Sendable (Data) async -> Void) async {
        self.inbound = handler
    }

    func deliverInbound(_ data: Data) async {
        await inbound?(data)
    }
}
