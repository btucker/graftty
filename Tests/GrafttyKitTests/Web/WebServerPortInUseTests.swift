import Testing
import Foundation
@testable import GrafttyKit

/// Pins that `WebServer.start` classifies an EADDRINUSE bind failure
/// as `.portUnavailable` on the WebServer instance. `WebServerController`
/// currently overwrites this with `.error(rawString)` in its catch
/// block — the raw NIO error (`"bind(descriptor:ptr:bytes:): Address
/// already in use) (errno: 48)"`) is opaque to users. The controller
/// fix must read `server.status` after the throw; this test lets a
/// future refactor delete the controller's separate classification
/// logic with confidence.
@Suite("WebServer — port-in-use classification")
struct WebServerPortInUseTests {

    @Test func secondBindOnSamePortReportsPortUnavailable() throws {
        // Bind the first server to an ephemeral port, then capture the
        // port and try to start a second server on the same port. The
        // second start() must throw AND set `status = .portUnavailable`.
        let tlsProvider = try makeTestTLSProvider()
        let first = WebServer(
            config: WebServer.Config(port: 0, zmxExecutable: URL(fileURLWithPath: "/bin/echo"), zmxDir: URL(fileURLWithPath: "/tmp")),
            auth: WebServer.AuthPolicy(isAllowed: { _ in true }),
            bindAddresses: ["127.0.0.1"],
            tlsProvider: tlsProvider
        )
        try first.start()
        defer { first.stop() }

        guard case let .listening(_, port) = first.status else {
            Issue.record("first server not listening; got \(first.status)")
            return
        }

        let second = WebServer(
            config: WebServer.Config(port: port, zmxExecutable: URL(fileURLWithPath: "/bin/echo"), zmxDir: URL(fileURLWithPath: "/tmp")),
            auth: WebServer.AuthPolicy(isAllowed: { _ in true }),
            bindAddresses: ["127.0.0.1"],
            tlsProvider: tlsProvider
        )

        #expect(throws: (any Error).self) {
            try second.start()
        }

        #expect(
            second.status == .portUnavailable,
            "port-in-use must classify as .portUnavailable, not .error(raw); got \(second.status)"
        )
    }
}
