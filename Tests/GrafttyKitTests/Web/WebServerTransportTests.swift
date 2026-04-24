import Foundation
import Testing
@testable import GrafttyKit

@Suite("WebServer — transport security", .serialized)
struct WebServerTransportTests {

    private static func makeConfig(port: Int = 0) -> WebServer.Config {
        WebServer.Config(
            port: port,
            zmxExecutable: URL(fileURLWithPath: "/dev/null"),
            zmxDir: URL(fileURLWithPath: "/tmp")
        )
    }

    @Test func plainLoopbackServerServesHTTP() async throws {
        let server = WebServer(
            config: Self.makeConfig(),
            auth: WebServer.AuthPolicy(isAllowed: { _ in true }),
            bindAddresses: ["127.0.0.1"],
            transportSecurity: .plainHTTPLoopbackOnly
        )
        try server.start()
        defer { server.stop() }

        guard case let .listening(_, port) = server.status else {
            Issue.record("server not listening")
            return
        }

        let (data, response) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(port)/")!
        )
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/html") == true)
        let body = String(data: data, encoding: .utf8) ?? ""
        #expect(body.contains("<div id=\"root\">"))
    }

    @Test func plainHTTPRejectsNonLoopbackBind() throws {
        let server = WebServer(
            config: Self.makeConfig(),
            auth: WebServer.AuthPolicy(isAllowed: { _ in true }),
            bindAddresses: ["0.0.0.0"],
            transportSecurity: .plainHTTPLoopbackOnly
        )

        #expect(throws: WebServer.TransportSecurity.Error.nonLoopbackPlainHTTPBind("0.0.0.0")) {
            try server.start()
        }
    }
}
