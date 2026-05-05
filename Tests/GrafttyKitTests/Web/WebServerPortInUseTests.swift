import Testing
import Foundation
@testable import GrafttyKit

/// Pins that `WebServer.start` classifies an EADDRINUSE bind failure
/// as `.portUnavailable` on the WebServer instance. `WebServerController`
/// also calls the same `WebServer.isAddressInUse(_:)` helper before
/// falling back to `.error(rawString)`, so the user sees "Port in use"
/// rather than an opaque NIO bind error.
@Suite("WebServer — port-in-use classification")
struct WebServerPortInUseTests {

    @Test("""
    @spec WEB-1.11: When the server fails to bind because the configured port is already in use (EADDRINUSE), the application shall surface the status as `.portUnavailable` — rendered as "Port in use" in the Settings pane — rather than the raw NIO error string (`"bind(descriptor:ptr:bytes:): Address already in use) (errno: 48)"`). Recognition is locale-stable: classify by the bridged `NSPOSIXErrorDomain` + `EADDRINUSE` errno code, with the NIO string-match kept as a secondary path. Both `WebServer.start` and `WebServerController` use a single shared `WebServer.isAddressInUse(_:)` classifier so they cannot drift on recognising the same error.
    """)
    func secondBindOnSamePortReportsPortUnavailable() throws {
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

    @Test func addressInUseClassifierAcceptsPOSIXErrnoAndStringFallback() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(EADDRINUSE))
        #expect(WebServer.isAddressInUse(posix))

        struct StringOnlyError: Error, CustomStringConvertible {
            let description = "bind(descriptor:ptr:bytes:): Address already in use) (errno: 48)"
        }
        #expect(WebServer.isAddressInUse(StringOnlyError()))
        #expect(!WebServer.isAddressInUse(NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED))))
    }
}
