import Testing
@testable import Graftty
import GrafttyKit

@Suite("Control socket startup ordering")
struct SocketServerStartupTests {
    @Test("""
    @spec ATTN-2.22: When the application starts the control-socket listener, it shall install its notification and request handlers before accepting connections so a startup request cannot close without a response.
    """)
    func handlersAreConfiguredBeforeListenerStarts() {
        let server = SocketServer(socketPath: "/tmp/graftty-startup-test")
        var events: [String] = []

        SocketServerStartup.start(
            server: server,
            onMessage: { _ in },
            onAsyncRequest: { _ in .ok },
            startListener: { configuredServer in
                #expect(configuredServer === server)
                #expect(configuredServer.onMessage != nil)
                #expect(configuredServer.onAsyncRequest != nil)
                events.append("started")
            },
        )

        #expect(events == ["started"])
    }
}
