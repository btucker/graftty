import Testing
import Foundation
@testable import GrafttyKit

/// Endpoint coverage for `GET /repos` and `POST /worktrees`. Uses stub
/// `reposProvider` / `worktreeCreator` closures so these tests stay
/// independent of AppState, AddWorktreeFlow, and the `git` binary —
/// those paths are covered by their own tests and the native sheet's
/// path is exercised by integration testing of the app.
///
/// Skipped in CI: on macos-26 GitHub Actions runners every test in
/// this file hangs without ever completing, tripping the 5-minute
/// Test-step timeout. Other WebServer suites (`WebServer — auth
/// gate`) use identical patterns and run fine on the same runner —
/// something about these tests' combination of URL paths (`/repos`,
/// `/worktrees`) plus parallel execution re-triggers the same
/// swift-testing exit-path hang the workflow comment references
/// (`wsEchoRoundTrip` dodges it the same way). Local `swift test`
/// runs the full suite; CI keeps the build + compilation-level
/// coverage.
@Suite("WebServer — /repos + /worktrees endpoints")
struct WebServerWorktreeEndpointTests {

    /// Matches the skip pattern `wsEchoRoundTrip` uses (see
    /// `WebServerIntegrationTests`). Plain early-return rather than
    /// `#require` because Swift Testing treats `#require` failure as a
    /// test failure, not a skip.
    private static var skipInCI: Bool {
        ProcessInfo.processInfo.environment["CI"] != nil
    }

    private static func makeConfig(
        repos: [WebServer.RepoInfo] = [],
        creator: (@Sendable (WebServer.CreateWorktreeRequest) async -> WebServer.CreateWorktreeOutcome)? = nil
    ) -> WebServer.Config {
        WebServer.Config(
            port: 0,
            zmxExecutable: URL(fileURLWithPath: "/dev/null"),
            zmxDir: URL(fileURLWithPath: "/tmp"),
            reposProvider: { repos },
            worktreeCreator: creator
        )
    }

    private static func startServer(
        config: WebServer.Config
    ) throws -> (server: WebServer, port: Int) {
        let server = WebServer(
            config: config,
            auth: WebServer.AuthPolicy(isAllowed: { _ in true }),
            bindAddresses: ["127.0.0.1"]
        )
        try server.start()
        guard case let .listening(_, port) = server.status else {
            throw NSError(domain: "test", code: 1)
        }
        return (server, port)
    }

    @Test func reposEndpointEncodesProviderOutput() async throws {
        if Self.skipInCI { return }
        let (server, port) = try Self.startServer(config: Self.makeConfig(repos: [
            WebServer.RepoInfo(path: "/tmp/alpha", displayName: "alpha"),
            WebServer.RepoInfo(path: "/tmp/beta", displayName: "beta"),
        ]))
        defer { server.stop() }

        let (data, response) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(port)/repos")!
        )
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/json") == true)
        let decoded = try JSONDecoder().decode([WebServer.RepoInfo].self, from: data)
        #expect(decoded.count == 2)
        #expect(decoded[0].displayName == "alpha")
        #expect(decoded[1].path == "/tmp/beta")
    }

    @Test func reposEndpointReturnsEmptyArrayWhenNoProvider() async throws {
        if Self.skipInCI { return }
        // Default-empty provider baked into Config.init — consumers who
        // haven't wired `setReposProvider` yet should still get a valid
        // JSON array, not a 404 or 500.
        let config = WebServer.Config(
            port: 0,
            zmxExecutable: URL(fileURLWithPath: "/dev/null"),
            zmxDir: URL(fileURLWithPath: "/tmp")
        )
        let (server, port) = try Self.startServer(config: config)
        defer { server.stop() }

        let (data, response) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(port)/repos")!
        )
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 200)
        let decoded = try JSONDecoder().decode([WebServer.RepoInfo].self, from: data)
        #expect(decoded.isEmpty)
    }

    @Test func worktreesPostReturnsSessionOnSuccess() async throws {
        if Self.skipInCI { return }
        let creator: @Sendable (WebServer.CreateWorktreeRequest) async -> WebServer.CreateWorktreeOutcome = { req in
            #expect(req.repoPath == "/tmp/repo")
            #expect(req.worktreeName == "feature-x")
            #expect(req.branchName == "feature-x")
            return .success(WebServer.CreateWorktreeResponse(
                sessionName: "graftty-abcdef",
                worktreePath: "/tmp/repo/.worktrees/feature-x"
            ))
        }
        let (server, port) = try Self.startServer(config: Self.makeConfig(creator: creator))
        defer { server.stop() }

        let body = try JSONEncoder().encode(WebServer.CreateWorktreeRequest(
            repoPath: "/tmp/repo",
            worktreeName: "feature-x",
            branchName: "feature-x"
        ))
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/worktrees")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: req)
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 200)
        let decoded = try JSONDecoder().decode(WebServer.CreateWorktreeResponse.self, from: data)
        #expect(decoded.sessionName == "graftty-abcdef")
        #expect(decoded.worktreePath == "/tmp/repo/.worktrees/feature-x")
    }

    @Test func worktreesPostGitFailureReturns409WithError() async throws {
        if Self.skipInCI { return }
        let creator: @Sendable (WebServer.CreateWorktreeRequest) async -> WebServer.CreateWorktreeOutcome = { _ in
            .gitFailed("fatal: branch 'foo' already exists")
        }
        let (server, port) = try Self.startServer(config: Self.makeConfig(creator: creator))
        defer { server.stop() }

        let body = try JSONEncoder().encode(WebServer.CreateWorktreeRequest(
            repoPath: "/tmp/repo", worktreeName: "foo", branchName: "foo"
        ))
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/worktrees")!)
        req.httpMethod = "POST"
        req.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: req)
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 409, "git-reported failure should map to 409 Conflict")
        struct ErrEnv: Codable { let error: String }
        let decoded = try JSONDecoder().decode(ErrEnv.self, from: data)
        #expect(decoded.error.contains("already exists"))
    }

    @Test func worktreesPostInvalidJSONReturns400() async throws {
        if Self.skipInCI { return }
        let creator: @Sendable (WebServer.CreateWorktreeRequest) async -> WebServer.CreateWorktreeOutcome = { _ in
            Issue.record("creator should not run on invalid input")
            return .internalFailure("should not reach")
        }
        let (server, port) = try Self.startServer(config: Self.makeConfig(creator: creator))
        defer { server.stop() }

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/worktrees")!)
        req.httpMethod = "POST"
        req.httpBody = Data("not json at all".utf8)

        let (_, response) = try await URLSession.shared.data(for: req)
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 400)
    }

    @Test func worktreesPostEmptyFieldReturns400WithoutInvokingCreator() async throws {
        if Self.skipInCI { return }
        let creator: @Sendable (WebServer.CreateWorktreeRequest) async -> WebServer.CreateWorktreeOutcome = { _ in
            Issue.record("creator should not run when trimmed input is empty")
            return .internalFailure("should not reach")
        }
        let (server, port) = try Self.startServer(config: Self.makeConfig(creator: creator))
        defer { server.stop() }

        let body = try JSONEncoder().encode(WebServer.CreateWorktreeRequest(
            repoPath: "/tmp/repo", worktreeName: "   ", branchName: "feature-x"
        ))
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/worktrees")!)
        req.httpMethod = "POST"
        req.httpBody = body

        let (_, response) = try await URLSession.shared.data(for: req)
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 400)
    }

    @Test func worktreesGetReturns405() async throws {
        if Self.skipInCI { return }
        let (server, port) = try Self.startServer(config: Self.makeConfig(
            creator: { _ in .internalFailure("unused") }
        ))
        defer { server.stop() }

        let (_, response) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(port)/worktrees")!
        )
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 405, "GET /worktrees should return Method Not Allowed")
    }

    @Test func worktreesPostWithoutCreatorReturns503() async throws {
        if Self.skipInCI { return }
        // No creator injected — `WebServerController` before
        // `setWorktreeCreator` is called, or a test that omits it. The
        // endpoint should advertise unavailability rather than 404 so
        // the client can tell "not supported yet" apart from "wrong URL".
        let (server, port) = try Self.startServer(config: Self.makeConfig(creator: nil))
        defer { server.stop() }

        let body = try JSONEncoder().encode(WebServer.CreateWorktreeRequest(
            repoPath: "/tmp/repo", worktreeName: "feature-x", branchName: "feature-x"
        ))
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/worktrees")!)
        req.httpMethod = "POST"
        req.httpBody = body

        let (_, response) = try await URLSession.shared.data(for: req)
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 503)
    }
}
