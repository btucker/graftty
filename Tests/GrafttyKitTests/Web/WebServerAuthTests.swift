import Testing
import Foundation
@testable import GrafttyKit

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
        let (_, response) = try await trustAllSession().data(from: URL(string: "https://localhost:\(port)/")!)
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 403)
    }

    @Test func allowedRequestServesHTML() async throws {
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
        let (data, response) = try await trustAllSession().data(from: URL(string: "https://localhost:\(port)/")!)
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/html") == true)
        let html = String(data: data, encoding: .utf8) ?? ""
        #expect(html.contains("<div id=\"root\">"))
    }

    @Test func spaFallbackServesIndexForUnknownPath() async throws {
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
        let (data, response) = try await trustAllSession().data(
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
        let (_, response) = try await trustAllSession().data(
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
        let (data, response) = try await trustAllSession().data(
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
        let (data, response) = try await trustAllSession().data(
            from: URL(string: "https://localhost:\(port)/app.js")!
        )
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Length") == "\(expected)")
        #expect(data.count == expected,
                "expected full \(expected) bytes, got \(data.count) — content-length mismatch")
    }
}
