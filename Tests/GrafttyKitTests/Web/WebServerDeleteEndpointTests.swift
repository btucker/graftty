import Testing
import Foundation
@testable import GrafttyKit

/// Endpoint coverage for `POST /worktrees/delete`. Uses a stub
/// `worktreeRemover` closure so these tests stay independent of
/// `DeleteWorktreeFlow`, `AppState`, and the `git` binary.
///
/// Skipped in CI for the same swift-testing exit-path reasons that
/// skip `WebServerWorktreeEndpointTests`; see that file's header
/// comment for the full rationale.
@Suite("WebServer — /worktrees/delete endpoint", .serialized)
struct WebServerDeleteEndpointTests {

    private static var skipInCI: Bool {
        ProcessInfo.processInfo.environment["CI"] != nil
    }

    private static func makeConfig(
        remover: (@Sendable (WebServer.DeleteWorktreeRequest) async -> WebServer.DeleteWorktreeOutcome)? = nil
    ) -> WebServer.Config {
        WebServer.Config(
            port: 0,
            zmxExecutable: URL(fileURLWithPath: "/dev/null"),
            zmxDir: URL(fileURLWithPath: "/tmp"),
            worktreeRemover: remover
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

    private static func postDelete(
        port: Int,
        worktreePath: String,
        force: Bool
    ) async throws -> (Data, HTTPURLResponse) {
        let body = try JSONEncoder().encode(WebServer.DeleteWorktreeRequest(
            worktreePath: worktreePath, force: force
        ))
        var req = URLRequest(url: URL(string: "https://localhost:\(port)/worktrees/delete")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, response) = try await trustAllData(for: req)
        return (data, response as! HTTPURLResponse)
    }

    @Test("""
    @spec WEB-7.8: When a client sends `POST /worktrees/delete` with `{ "worktreePath": "<abs>", "force": <bool> }`, the application shall route the request through `DeleteWorktreeFlow.delete` and respond `200 { "dismissed": <bool> }` on success. `dismissed` shall be `true` when the flow took the GIT-3.6 / GIT-4.13 prune-on-vanished branch and `false` when `git worktree remove` succeeded. The `/worktrees/delete` endpoint accepts `POST` only; other verbs return `405 Method Not Allowed`.
    """)
    func deleteSuccessReturnsDismissedFlag() async throws {
        if Self.skipInCI { return }

        let remover: @Sendable (WebServer.DeleteWorktreeRequest) async -> WebServer.DeleteWorktreeOutcome = { req in
            #expect(req.worktreePath == "/tmp/repo/.worktrees/feature-x")
            #expect(req.force == false)
            return .success(WebServer.DeleteWorktreeResponse(dismissed: false))
        }
        let (server, port) = try Self.startServer(config: Self.makeConfig(remover: remover))
        defer { server.stop() }

        let (data, http) = try await Self.postDelete(
            port: port,
            worktreePath: "/tmp/repo/.worktrees/feature-x",
            force: false
        )
        #expect(http.statusCode == 200)
        let decoded = try JSONDecoder().decode(WebServer.DeleteWorktreeResponse.self, from: data)
        #expect(decoded.dismissed == false)
    }

    @Test func deleteSuccessWithPruneBranchReturnsDismissedTrue() async throws {
        if Self.skipInCI { return }

        let remover: @Sendable (WebServer.DeleteWorktreeRequest) async -> WebServer.DeleteWorktreeOutcome = { _ in
            .success(WebServer.DeleteWorktreeResponse(dismissed: true))
        }
        let (server, port) = try Self.startServer(config: Self.makeConfig(remover: remover))
        defer { server.stop() }

        let (data, http) = try await Self.postDelete(
            port: port, worktreePath: "/tmp/repo/.worktrees/stale", force: false
        )
        #expect(http.statusCode == 200)
        let decoded = try JSONDecoder().decode(WebServer.DeleteWorktreeResponse.self, from: data)
        #expect(decoded.dismissed == true)
    }

    @Test func deleteGetReturns405() async throws {
        if Self.skipInCI { return }

        let (server, port) = try Self.startServer(config: Self.makeConfig(
            remover: { _ in .internalFailure("unused") }
        ))
        defer { server.stop() }

        let (_, response) = try await trustAllData(
            from: URL(string: "https://localhost:\(port)/worktrees/delete")!
        )
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 405)
    }

    @Test("""
    @spec WEB-7.9: If the server-side delete flow encounters a git failure that `--force` could resolve, then the application shall respond `409 Conflict` with `{ "error": "<stderr>", "forceAllowed": true, "shortStatus": "<git status --short output>" }`. When `--force` has already been attempted, or the failure class is one `--force` cannot help (e.g. main-checkout rejection), the response shall be `409 Conflict` with `forceAllowed: false` and no `shortStatus` field.
    """)
    func deleteForceableFailureReturns409WithStatus() async throws {
        if Self.skipInCI { return }

        let remover: @Sendable (WebServer.DeleteWorktreeRequest) async -> WebServer.DeleteWorktreeOutcome = { _ in
            .gitFailedForceable(
                stderr: "fatal: contains modified or untracked files, use --force to delete it",
                shortStatus: " M foo.swift\n?? bar.swift"
            )
        }
        let (server, port) = try Self.startServer(config: Self.makeConfig(remover: remover))
        defer { server.stop() }

        let (data, http) = try await Self.postDelete(
            port: port, worktreePath: "/tmp/repo/.worktrees/dirty", force: false
        )
        #expect(http.statusCode == 409)
        struct Body: Codable { let error: String; let forceAllowed: Bool; let shortStatus: String? }
        let decoded = try JSONDecoder().decode(Body.self, from: data)
        #expect(decoded.forceAllowed == true)
        #expect(decoded.shortStatus == " M foo.swift\n?? bar.swift")
        #expect(decoded.error.contains("--force"))
    }

    @Test func deleteFinalFailureReturns409WithoutShortStatus() async throws {
        if Self.skipInCI { return }

        let remover: @Sendable (WebServer.DeleteWorktreeRequest) async -> WebServer.DeleteWorktreeOutcome = { _ in
            .gitFailedFinal("fatal: main working tree cannot be removed")
        }
        let (server, port) = try Self.startServer(config: Self.makeConfig(remover: remover))
        defer { server.stop() }

        let (data, http) = try await Self.postDelete(
            port: port, worktreePath: "/tmp/repo", force: false
        )
        #expect(http.statusCode == 409)
        struct Body: Codable { let error: String; let forceAllowed: Bool; let shortStatus: String? }
        let decoded = try JSONDecoder().decode(Body.self, from: data)
        #expect(decoded.forceAllowed == false)
        #expect(decoded.shortStatus == nil)
    }

    @Test func deleteInvalidJSONReturns400() async throws {
        if Self.skipInCI { return }

        let (server, port) = try Self.startServer(config: Self.makeConfig(
            remover: { _ in Issue.record("remover should not run on invalid JSON"); return .internalFailure("x") }
        ))
        defer { server.stop() }

        var req = URLRequest(url: URL(string: "https://localhost:\(port)/worktrees/delete")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("not json".utf8)
        let (_, response) = try await trustAllData(for: req)
        #expect((response as! HTTPURLResponse).statusCode == 400)
    }

    @Test func deleteEmptyPathReturns400WithoutInvokingRemover() async throws {
        if Self.skipInCI { return }

        let (server, port) = try Self.startServer(config: Self.makeConfig(
            remover: { _ in Issue.record("remover should not run on empty path"); return .internalFailure("x") }
        ))
        defer { server.stop() }

        let (_, http) = try await Self.postDelete(port: port, worktreePath: "   ", force: false)
        #expect(http.statusCode == 400)
    }

    @Test func deleteNotFoundReturns404() async throws {
        if Self.skipInCI { return }

        let remover: @Sendable (WebServer.DeleteWorktreeRequest) async -> WebServer.DeleteWorktreeOutcome = { _ in
            .notFound("unknown worktree path")
        }
        let (server, port) = try Self.startServer(config: Self.makeConfig(remover: remover))
        defer { server.stop() }

        let (_, http) = try await Self.postDelete(
            port: port, worktreePath: "/tmp/nope", force: false
        )
        #expect(http.statusCode == 404)
    }

    @Test("""
    @spec WEB-7.10: If the server's `worktreeRemover` closure is not injected, then `POST /worktrees/delete` shall respond `503 Service Unavailable` with `{ "error": "worktree deletion not available" }`. This matches the create endpoint's pre-injection contract (WEB-7.4 sibling) so a mobile or web client can distinguish "not supported yet" from "wrong URL".
    """)
    func deleteWithoutRemoverReturns503() async throws {
        if Self.skipInCI { return }

        let (server, port) = try Self.startServer(config: Self.makeConfig(remover: nil))
        defer { server.stop() }

        let (data, http) = try await Self.postDelete(
            port: port, worktreePath: "/tmp/x", force: false
        )
        #expect(http.statusCode == 503)
        struct Body: Codable { let error: String }
        let decoded = try JSONDecoder().decode(Body.self, from: data)
        #expect(decoded.error.contains("not available"))
    }

    @Test func deleteDeniedReturns403WithoutInvokingRemover() async throws {
        if Self.skipInCI { return }

        let (server, port) = try Self.startServer(
            config: Self.makeConfig(
                remover: { _ in Issue.record("remover should not run before auth succeeds"); return .internalFailure("x") }
            ),
            isAllowed: { _ in false }
        )
        defer { server.stop() }

        let (_, http) = try await Self.postDelete(
            port: port, worktreePath: "/tmp/x", force: false
        )
        #expect(http.statusCode == 403)
    }
}
