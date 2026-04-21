import Testing
@testable import GrafttyKit

// `WebAccessSettings.port` is an `@AppStorage`-backed `Int` with NO
// validation on the write path — the Settings pane's TextField accepts
// any integer the user types. When the user enters an out-of-range
// port (e.g. "99999", "-1", "0"), `WebServerController.reconcile`
// passes it straight to NIO's `bootstrap.bind(host:, port:)`, which
// throws a `NIOBindError`/POSIX error wrapped in "error: ...". The
// user sees a cryptic status like
//   Error: NIOBindError(host: "100.64.0.1", port: 99999, …)
// rather than a human-readable "Port must be 1–65535".
//
// `WebServer.Config.isValidListenablePort(_:)` is the shared gate
// every UI / controller / CLI surface should run their port value
// through before trusting it. Port 0 is allowed (kernel assigns
// ephemeral — integration tests rely on this), 1–65535 are user-
// reachable; everything else is rejected.
@Suite("WebServer — port validation (WEB-1.5)")
struct WebServerPortValidationTests {

    @Test func acceptsEphemeralAutoPort() {
        // Integration tests use port 0 to let the kernel pick a free one.
        #expect(WebServer.Config.isValidListenablePort(0))
    }

    @Test func acceptsWellKnownLowPort() {
        #expect(WebServer.Config.isValidListenablePort(1))
    }

    @Test func acceptsDefaultGrafttyPort() {
        #expect(WebServer.Config.isValidListenablePort(8799))
    }

    @Test func acceptsMaxPort() {
        #expect(WebServer.Config.isValidListenablePort(65535))
    }

    @Test func rejectsNegativePort() {
        #expect(!WebServer.Config.isValidListenablePort(-1))
    }

    @Test func rejectsPortAboveMax() {
        #expect(!WebServer.Config.isValidListenablePort(65536))
    }

    @Test func rejectsVeryLargePort() {
        // User types "99999" into the TextField — most common bug shape.
        #expect(!WebServer.Config.isValidListenablePort(99999))
    }

    @Test func rejectsIntMax() {
        #expect(!WebServer.Config.isValidListenablePort(Int.max))
    }

    @Test func rejectsIntMin() {
        #expect(!WebServer.Config.isValidListenablePort(Int.min))
    }
}
