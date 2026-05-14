import Testing
import Foundation
@testable import GrafttyKit

/// Endpoint coverage for `POST /push/register`. Uses a stub
/// `pushRegisterHandler` so these tests are independent of
/// `PushDeviceStore` and on-disk persistence — those paths have their
/// own unit tests.
///
/// Skipped in CI for the same reason as
/// `WebServerWorktreeEndpointTests`: on macos-26 GitHub Actions runners
/// the swift-testing exit path hangs when multiple HTTPS tests run in
/// parallel against an in-process WebServer. Local `swift test` runs the
/// full suite; CI keeps the build + compilation-level coverage.
@Suite("WebServer — /push/register endpoint", .serialized)
struct PushRegisterEndpointTests {

    /// Matches the skip pattern used by `WebServerWorktreeEndpointTests`.
    private static var skipInCI: Bool {
        ProcessInfo.processInfo.environment["CI"] != nil
    }

    private static func makeConfig(
        handler: (@Sendable (WebServer.PushRegisterRequest) async -> WebServer.PushRegisterResponse)? = nil
    ) -> WebServer.Config {
        WebServer.Config(
            port: 0,
            zmxExecutable: URL(fileURLWithPath: "/dev/null"),
            zmxDir: URL(fileURLWithPath: "/tmp"),
            pushRegisterHandler: handler
        )
    }

    private static func startServer(
        config: WebServer.Config,
        isAllowed: @escaping @Sendable (String) async -> Bool = { _ in true }
    ) throws -> (server: WebServer, port: Int) {
        let server = WebServer(
            config: config,
            auth: WebServer.AuthPolicy(isAllowed: isAllowed),
            bindAddresses: ["127.0.0.1"],
            tlsProvider: try makeTestTLSProvider()
        )
        try server.start()
        guard case let .listening(_, port) = server.status else {
            throw NSError(domain: "test", code: 1)
        }
        return (server, port)
    }

    @Test func pushRegisterValidPostReturns200AndInvokesHandler() async throws {
        if Self.skipInCI { return }

        let captured = CapturedRequest()
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let handler: @Sendable (WebServer.PushRegisterRequest) async -> WebServer.PushRegisterResponse = { req in
            await captured.set(req)
            return WebServer.PushRegisterResponse(registeredAt: stamp)
        }
        let (server, port) = try Self.startServer(config: Self.makeConfig(handler: handler))
        defer { server.stop() }

        let body = try JSONEncoder().encode(WebServer.PushRegisterRequest(
            deviceToken: "abc123",
            deviceName: "Ben's iPhone",
            platform: "ios"
        ))
        var req = URLRequest(url: URL(string: "https://localhost:\(port)/push/register")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let (data, response) = try await trustAllData(for: req)
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/json") == true)

        let decoded = try JSONDecoder.iso8601().decode(WebServer.PushRegisterResponse.self, from: data)
        #expect(decoded.registeredAt == stamp)

        let observed = await captured.value
        #expect(observed?.deviceToken == "abc123")
        #expect(observed?.deviceName == "Ben's iPhone")
        #expect(observed?.platform == "ios")
    }

    @Test func pushRegisterInvalidJSONReturns400WithErrorField() async throws {
        if Self.skipInCI { return }

        let handler: @Sendable (WebServer.PushRegisterRequest) async -> WebServer.PushRegisterResponse = { _ in
            Issue.record("handler should not run on invalid JSON")
            return WebServer.PushRegisterResponse(registeredAt: Date())
        }
        let (server, port) = try Self.startServer(config: Self.makeConfig(handler: handler))
        defer { server.stop() }

        var req = URLRequest(url: URL(string: "https://localhost:\(port)/push/register")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("not json at all".utf8)

        let (data, response) = try await trustAllData(for: req)
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 400)
        struct ErrEnv: Codable { let error: String }
        let decoded = try JSONDecoder().decode(ErrEnv.self, from: data)
        #expect(!decoded.error.isEmpty)
    }

    @Test func pushRegisterWithoutHandlerReturns503() async throws {
        if Self.skipInCI { return }

        // No handler injected — the Mac hasn't wired push registration
        // yet (e.g., early boot). Endpoint should advertise
        // unavailability rather than 404.
        let (server, port) = try Self.startServer(config: Self.makeConfig(handler: nil))
        defer { server.stop() }

        let body = try JSONEncoder().encode(WebServer.PushRegisterRequest(
            deviceToken: "abc123",
            deviceName: "Ben's iPhone",
            platform: "ios"
        ))
        var req = URLRequest(url: URL(string: "https://localhost:\(port)/push/register")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let (_, response) = try await trustAllData(for: req)
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 503)
    }

    @Test func pushRegisterGetReturns405() async throws {
        if Self.skipInCI { return }

        let handler: @Sendable (WebServer.PushRegisterRequest) async -> WebServer.PushRegisterResponse = { _ in
            Issue.record("handler should not run on GET")
            return WebServer.PushRegisterResponse(registeredAt: Date())
        }
        let (server, port) = try Self.startServer(config: Self.makeConfig(handler: handler))
        defer { server.stop() }

        let (_, response) = try await trustAllData(
            from: URL(string: "https://localhost:\(port)/push/register")!
        )
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 405, "GET /push/register should return Method Not Allowed")
    }
}

/// Tiny actor used to capture the request passed to the stub handler
/// so the test can assert on it after the response round-trip. Avoids
/// the `@Sendable` capture issues of a plain `var` reference.
private actor CapturedRequest {
    private(set) var value: WebServer.PushRegisterRequest?
    func set(_ req: WebServer.PushRegisterRequest) { value = req }
}
