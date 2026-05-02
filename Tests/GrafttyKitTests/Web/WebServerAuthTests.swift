import Testing
import Foundation
@testable import GrafttyKit
import GrafttyProtocol

@Suite("WebServer — auth gate", .serialized)
struct WebServerAuthTests {

    private static func makeConfig(port: Int = 0) -> WebServer.Config {
        WebServer.Config(
            port: port,
            zmxExecutable: URL(fileURLWithPath: "/dev/null"),
            zmxDir: URL(fileURLWithPath: "/tmp")
        )
    }

    @Test func deniedRequestReturns403() async throws {
        let server = WebServer(
            config: Self.makeConfig(),
            auth: WebServer.AuthPolicy(isAllowed: { _ in false }),
            bindAddresses: ["127.0.0.1"],
            tlsProvider: try makeTestTLSProvider()
        )
        try server.start()
        defer { server.stop() }
        guard case let .listening(_, port) = server.status else {
            Issue.record("server not listening"); return
        }
        let (_, response) = try await trustAllData(from: URL(string: "https://localhost:\(port)/")!)
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 403)
    }

    @Test func deniedSessionsRequestReturns403WithoutCallingProvider() async throws {
        let probe = SessionsProviderProbe()
        let server = WebServer(
            config: WebServer.Config(
                port: 0,
                zmxExecutable: URL(fileURLWithPath: "/dev/null"),
                zmxDir: URL(fileURLWithPath: "/tmp"),
                sessionsProvider: { await probe.sessions() }
            ),
            auth: WebServer.AuthPolicy(isAllowed: { _ in false }),
            bindAddresses: ["127.0.0.1"],
            tlsProvider: try makeTestTLSProvider()
        )
        try server.start()
        defer { server.stop() }
        guard case let .listening(_, port) = server.status else {
            Issue.record("server not listening"); return
        }
        let (_, response) = try await trustAllData(
            from: URL(string: "https://localhost:\(port)/sessions")!
        )
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 403)
        #expect(await probe.callCount == 0)
    }

    @Test("""
    @spec WEB-5.4: When a client requests `GET /sessions`, the application shall respond with a JSON array of the currently-running sessions, one entry per live pane across all running worktrees, with fields `name` (the zmx session name derived per `ZMX-2.1`), `worktreePath`, `repoDisplayName`, and `worktreeDisplayName`. The bundled client's root page (`/`) shall fetch this endpoint and render a clickable picker grouped by `repoDisplayName`, so a user who visits the server's root URL without a session query gets a functional entry point rather than a bare "no session" placeholder. Access to `/sessions` shall be gated by the same Tailscale-whois authorization as every other path (`WEB-2.1` / `WEB-2.2`).
    """)
    func sessionsEndpointReturnsJSONFromProvider() async throws {
        let expected = [
            SessionInfo(
                name: "graftty-alpha",
                worktreePath: "/repos/alpha",
                repoDisplayName: "alpha",
                worktreeDisplayName: "main"
            ),
            SessionInfo(
                name: "graftty-beta",
                worktreePath: "/repos/beta/.worktrees/feature",
                repoDisplayName: "beta",
                worktreeDisplayName: "feature"
            ),
        ]
        let server = WebServer(
            config: WebServer.Config(
                port: 0,
                zmxExecutable: URL(fileURLWithPath: "/dev/null"),
                zmxDir: URL(fileURLWithPath: "/tmp"),
                sessionsProvider: { expected }
            ),
            auth: WebServer.AuthPolicy(isAllowed: { _ in true }),
            bindAddresses: ["127.0.0.1"],
            tlsProvider: try makeTestTLSProvider()
        )
        try server.start()
        defer { server.stop() }
        guard case let .listening(_, port) = server.status else {
            Issue.record("server not listening"); return
        }
        let (data, response) = try await trustAllData(
            from: URL(string: "https://localhost:\(port)/sessions")!
        )
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Type") == "application/json; charset=utf-8")
        let decoded = try JSONDecoder().decode([SessionInfo].self, from: data)
        #expect(decoded == expected)
    }

    @Test("""
    @spec WEB-3.1: The application shall serve a single static page at `/` (and `/index.html`) that bootstraps the bundled web client.
    """)
    func staticIndexRoutesServeHTML() async throws {
        let server = WebServer(
            config: Self.makeConfig(),
            auth: WebServer.AuthPolicy(isAllowed: { _ in true }),
            bindAddresses: ["127.0.0.1"],
            tlsProvider: try makeTestTLSProvider()
        )
        try server.start()
        defer { server.stop() }
        guard case let .listening(_, port) = server.status else {
            Issue.record("server not listening"); return
        }
        let (data, response) = try await trustAllData(from: URL(string: "https://localhost:\(port)/")!)
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/html") == true)
        let html = String(data: data, encoding: .utf8) ?? ""
        #expect(html.contains("<div id=\"root\">"))

        let (explicitData, explicitResponse) = try await trustAllData(
            from: URL(string: "https://localhost:\(port)/index.html")!
        )
        let explicitHTTP = explicitResponse as! HTTPURLResponse
        #expect(explicitHTTP.statusCode == 200)
        #expect(explicitHTTP.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/html") == true)
        let explicitHTML = String(data: explicitData, encoding: .utf8) ?? ""
        #expect(explicitHTML.contains("<div id=\"root\">"))
    }

    @Test("""
    @spec WEB-3.2: When a client requests any path that does not match a bundled static asset and does not begin with `/ws`, the application shall respond with the bundled `index.html` body and `Content-Type: text/html; charset=utf-8`. This serves the SPA fallback for client-side-routed URLs such as `/session/<name>`.
    """)
    func spaFallbackServesIndexForUnknownPath() async throws {
        let server = WebServer(
            config: Self.makeConfig(),
            auth: WebServer.AuthPolicy(isAllowed: { _ in true }),
            bindAddresses: ["127.0.0.1"],
            tlsProvider: try makeTestTLSProvider()
        )
        try server.start()
        defer { server.stop() }
        guard case let .listening(_, port) = server.status else {
            Issue.record("server not listening"); return
        }
        let (data, response) = try await trustAllData(
            from: URL(string: "https://localhost:\(port)/session/whatever")!
        )
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/html") == true)
        let body = String(data: data, encoding: .utf8) ?? ""
        #expect(body.contains("<div id=\"root\">"), "SPA fallback should serve index.html body")
    }

    @Test func wsPathReturns404WithoutUpgradeHeader() async throws {
        let server = WebServer(
            config: Self.makeConfig(),
            auth: WebServer.AuthPolicy(isAllowed: { _ in true }),
            bindAddresses: ["127.0.0.1"],
            tlsProvider: try makeTestTLSProvider()
        )
        try server.start()
        defer { server.stop() }
        guard case let .listening(_, port) = server.status else {
            Issue.record("server not listening"); return
        }
        let (_, response) = try await trustAllData(
            from: URL(string: "https://localhost:\(port)/ws")!
        )
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 404, "/ws without Upgrade must NOT fall through to index.html")
    }

    @Test func servesAppJS() async throws {
        let server = WebServer(
            config: Self.makeConfig(),
            auth: WebServer.AuthPolicy(isAllowed: { _ in true }),
            bindAddresses: ["127.0.0.1"],
            tlsProvider: try makeTestTLSProvider()
        )
        try server.start()
        defer { server.stop() }
        guard case let .listening(_, port) = server.status else {
            Issue.record("server not listening"); return
        }
        let (data, response) = try await trustAllData(
            from: URL(string: "https://localhost:\(port)/app.js")!
        )
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Type") == "application/javascript; charset=utf-8")
        #expect(data.count > 100)
    }

    /// Regression for `bug-web-content-length-mismatch`: serving a large
    /// bundled asset like `app.js` (~318KB) must deliver the full declared
    /// `Content-Length` of bytes, all the way to EOF on a raw TCP read.
    /// The original server closed the channel immediately after
    /// `writeAndFlush` without waiting on the flush promise, so TCP send
    /// buffers that couldn't hold the whole body in one shot led Chrome
    /// to surface `ERR_CONTENT_LENGTH_MISMATCH`.
    #if false
    // TODO: rewrite over TLS (WEB-3.6 regression still needs coverage via
    // rawHTTPSGet using NWConnection + NWProtocolTLS). The original raw-
    // socket helper bypassed URLSession to reliably back up the server's
    // TCP send queue and catch the close-before-flush race; an HTTPS
    // rewrite needs the same byte-level control after the TLS handshake.
    @Test func appJSRawReadMatchesContentLength() async throws {}
    #endif

    @Test func appJSBodyLengthMatchesContentLength() async throws {
        let server = WebServer(
            config: Self.makeConfig(),
            auth: WebServer.AuthPolicy(isAllowed: { _ in true }),
            bindAddresses: ["127.0.0.1"],
            tlsProvider: try makeTestTLSProvider()
        )
        try server.start()
        defer { server.stop() }
        guard case let .listening(_, port) = server.status else {
            Issue.record("server not listening"); return
        }
        let expected = try WebStaticResources.asset(for: "/app.js").data.count
        let (data, response) = try await trustAllData(
            from: URL(string: "https://localhost:\(port)/app.js")!
        )
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Length") == "\(expected)")
        #expect(data.count == expected,
                "expected full \(expected) bytes, got \(data.count) — content-length mismatch")
    }

    @Test func certHotSwap_newConnectionsUseNewContext() async throws {
        let provider = try makeTestTLSProvider()
        let server = WebServer(
            config: Self.makeConfig(),
            auth: WebServer.AuthPolicy(isAllowed: { _ in true }),
            bindAddresses: ["127.0.0.1"],
            tlsProvider: provider
        )
        try server.start()
        defer { server.stop() }
        guard case let .listening(_, port) = server.status else {
            Issue.record("server not listening"); return
        }
        let session = trustAllSession()
        defer { session.invalidateAndCancel() }
        let (_, r1) = try await session.data(
            from: URL(string: "https://localhost:\(port)/")!
        )
        #expect((r1 as! HTTPURLResponse).statusCode == 200)

        // Swap in a freshly-built context for the same cert bytes and
        // confirm a new request still works (old context is released,
        // new context is picked up on the next accept).
        provider.swap(try makeTestTLSContext())
        let (_, r2) = try await session.data(
            from: URL(string: "https://localhost:\(port)/")!
        )
        #expect((r2 as! HTTPURLResponse).statusCode == 200)
    }
}

private actor SessionsProviderProbe {
    private var calls = 0

    var callCount: Int { calls }

    func sessions() -> [SessionInfo] {
        calls += 1
        return []
    }
}
