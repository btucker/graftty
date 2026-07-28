import Testing
import Foundation
import GrafttyProtocol
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
///
/// @spec WEB-7.3: The application shall reject `POST /worktrees` requests with invalid JSON, missing fields, or whitespace-only `worktreeName`/`branchName` with `400 Bad Request` and a JSON `{error: "<message>"}` body. `GET /worktrees` and other verbs shall return `405 Method Not Allowed`. Request bodies exceeding 64 KiB shall return `413 Payload Too Large` before any creator is invoked.
@Suite("WebServer — /repos + /worktrees endpoints", .serialized)
struct WebServerWorktreeEndpointTests {

    private static func makeConfig(
        repos: [WebServer.RepoInfo] = [],
        relayedRepos: [WebServer.RepoInfo] = [],
        worktrees: [WorktreePanes] = [],
        relayedWorktrees: [WorktreePanes] = [],
        creator: (@Sendable (WebServer.CreateWorktreeRequest) async -> WebServer.CreateWorktreeOutcome)? = nil,
        defaultBranchPuller: (@Sendable (WebServer.PullDefaultBranchRequest) async -> WebServer.PullDefaultBranchOutcome)? = nil
    ) -> WebServer.Config {
        WebServer.Config(
            port: 0,
            zmxExecutable: URL(fileURLWithPath: "/dev/null"),
            zmxDir: URL(fileURLWithPath: "/tmp"),
            reposProvider: { repos },
            relayedReposProvider: { relayedRepos },
            worktreeCreator: creator,
            defaultBranchPuller: defaultBranchPuller,
            worktreePanesProvider: { worktrees },
            relayedWorktreePanesProvider: { relayedWorktrees }
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

    @Test("""
    @spec WEB-7.1: When a client requests `GET /repos`, the application shall respond with a JSON array of the currently-tracked repositories (one entry per top-level `RepoEntry` in `AppState.repos`) with fields `path` (opaque absolute path round-tripped on `POST /worktrees`), `displayName` (matching the native sidebar's top-level label), and optional `defaultBranchStatus` (`branchName`, `remoteRef`, `behindCount`) when the default checkout is behind its origin default branch. Access is gated by the same Tailscale-whois authorization (`WEB-2.1` / `WEB-2.2`).
    """)
    func reposEndpointEncodesProviderOutput() async throws {
        if skipInCI() { return }

        let (server, port) = try Self.startServer(config: Self.makeConfig(repos: [
            WebServer.RepoInfo(
                path: "/tmp/alpha",
                displayName: "alpha",
                defaultBranchStatus: .init(
                    branchName: "main",
                    remoteRef: "origin/main",
                    behindCount: 2
                )
            ),
            WebServer.RepoInfo(path: "/tmp/beta", displayName: "beta"),
        ]))
        defer { server.stop() }

        let (data, response) = try await trustAllData(
            from: URL(string: "https://localhost:\(port)/repos")!
        )
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/json") == true)
        let decoded = try JSONDecoder().decode([WebServer.RepoInfo].self, from: data)
        #expect(decoded.count == 2)
        #expect(decoded[0].displayName == "alpha")
        #expect(decoded[0].defaultBranchStatus?.branchName == "main")
        #expect(decoded[0].defaultBranchStatus?.remoteRef == "origin/main")
        #expect(decoded[0].defaultBranchStatus?.behindCount == 2)
        #expect(decoded[1].path == "/tmp/beta")
        #expect(decoded[1].defaultBranchStatus == nil)
    }

    @Test
    func relayedReposRequireFeatureAdvertisement() async throws {
        if skipInCI() { return }

        let (server, port) = try Self.startServer(config: Self.makeConfig(
            repos: [.init(path: "/tmp/local", displayName: "local")],
            relayedRepos: [
                .init(path: "relay-repository-1", displayName: "remote"),
            ]
        ))
        defer { server.stop() }

        let url = URL(string: "https://localhost:\(port)/repos")!
        let (legacyData, _) = try await trustAllData(from: url)
        let legacy = try JSONDecoder().decode(
            [WebServer.RepoInfo].self,
            from: legacyData
        )
        #expect(legacy.map(\.displayName) == ["local"])

        var relayRequest = URLRequest(url: url)
        relayRequest.setValue(
            "another-feature, \(RemoteWorktreeFeatures.oneHopRelay)",
            forHTTPHeaderField: RemoteWorktreeFeatures.headerName
        )
        let (relayData, _) = try await trustAllData(for: relayRequest)
        let relayAware = try JSONDecoder().decode(
            [WebServer.RepoInfo].self,
            from: relayData
        )
        #expect(relayAware.map(\.displayName) == ["local", "remote"])
    }

    @Test
    func relayedWorktreesRequireFeatureAdvertisement() async throws {
        if skipInCI() { return }

        let local = WorktreePanes(
            path: "/tmp/local",
            displayName: "local",
            repoDisplayName: "repo",
            displayBranch: "main",
            state: .closed,
            isMainCheckout: true,
            prBadge: nil,
            stats: nil,
            attentionText: nil,
            layout: nil
        )
        let remote = WorktreePanes(
            path: "relay-worktree-1",
            displayName: "remote",
            repoDisplayName: "repo",
            displayBranch: "feature",
            state: .closed,
            isMainCheckout: false,
            prBadge: nil,
            stats: nil,
            attentionText: nil,
            layout: nil
        )
        let (server, port) = try Self.startServer(config: Self.makeConfig(
            worktrees: [local],
            relayedWorktrees: [remote]
        ))
        defer { server.stop() }

        let url = URL(
            string: "https://localhost:\(port)/worktrees/panes"
        )!
        let (legacyData, _) = try await trustAllData(from: url)
        let legacy = try JSONDecoder().decode(
            [WorktreePanes].self,
            from: legacyData
        )
        #expect(legacy.map(\.displayName) == ["local"])

        var relayRequest = URLRequest(url: url)
        relayRequest.setValue(
            RemoteWorktreeFeatures.oneHopRelay,
            forHTTPHeaderField: RemoteWorktreeFeatures.headerName
        )
        let (relayData, _) = try await trustAllData(for: relayRequest)
        let relayAware = try JSONDecoder().decode(
            [WorktreePanes].self,
            from: relayData
        )
        #expect(relayAware.map(\.displayName) == ["local", "remote"])
    }

    @Test func deniedReposRequestReturns403WithoutCallingProvider() async throws {
        if skipInCI() { return }

        let config = WebServer.Config(
            port: 0,
            zmxExecutable: URL(fileURLWithPath: "/dev/null"),
            zmxDir: URL(fileURLWithPath: "/tmp"),
            reposProvider: {
                Issue.record("reposProvider should not run before auth succeeds")
                return []
            }
        )
        let (server, port) = try Self.startServer(config: config, isAllowed: { _ in false })
        defer { server.stop() }

        let (_, response) = try await trustAllData(
            from: URL(string: "https://localhost:\(port)/repos")!
        )
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 403)
    }

    @Test func reposEndpointReturnsEmptyArrayWhenNoProvider() async throws {
        if skipInCI() { return }

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

        let (data, response) = try await trustAllData(
            from: URL(string: "https://localhost:\(port)/repos")!
        )
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 200)
        let decoded = try JSONDecoder().decode([WebServer.RepoInfo].self, from: data)
        #expect(decoded.isEmpty)
    }

    @Test func worktreesPostReturnsSessionOnSuccess() async throws {
        if skipInCI() { return }

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
        var req = URLRequest(url: URL(string: "https://localhost:\(port)/worktrees")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let (data, response) = try await trustAllData(for: req)
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 200)
        let decoded = try JSONDecoder().decode(WebServer.CreateWorktreeResponse.self, from: data)
        #expect(decoded.sessionName == "graftty-abcdef")
        #expect(decoded.worktreePath == "/tmp/repo/.worktrees/feature-x")
    }

    @Test("""
    @spec WEB-7.12: When a client sends `POST /repos/default-branch/pull` with `{repoPath}`, the application shall run the injected default-branch puller for that repository and respond `200` with `{ok: true}` on success, `409` with `{error}` when git rejects the pull, and `503` when the puller is not wired.
    """)
    func defaultBranchPullEndpointReturnsSuccess() async throws {
        if skipInCI() { return }

        nonisolated(unsafe) var pulled: [String] = []
        let puller: @Sendable (WebServer.PullDefaultBranchRequest) async -> WebServer.PullDefaultBranchOutcome = { req in
            pulled.append(req.repoPath)
            return .success(WebServer.PullDefaultBranchResponse(ok: true))
        }
        let (server, port) = try Self.startServer(config: Self.makeConfig(defaultBranchPuller: puller))
        defer { server.stop() }

        let body = try JSONEncoder().encode(WebServer.PullDefaultBranchRequest(repoPath: "/tmp/repo"))
        var req = URLRequest(url: URL(string: "https://localhost:\(port)/repos/default-branch/pull")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let (data, response) = try await trustAllData(for: req)
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 200)
        let decoded = try JSONDecoder().decode(WebServer.PullDefaultBranchResponse.self, from: data)
        #expect(decoded.ok)
        #expect(pulled == ["/tmp/repo"])
    }

    @Test func defaultBranchPullEndpointReturns503WhenUnwired() async throws {
        if skipInCI() { return }

        let (server, port) = try Self.startServer(config: Self.makeConfig())
        defer { server.stop() }

        let body = try JSONEncoder().encode(WebServer.PullDefaultBranchRequest(repoPath: "/tmp/repo"))
        var req = URLRequest(url: URL(string: "https://localhost:\(port)/repos/default-branch/pull")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let (data, response) = try await trustAllData(for: req)
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 503)
        struct ErrEnv: Codable { let error: String }
        let decoded = try JSONDecoder().decode(ErrEnv.self, from: data)
        #expect(decoded.error.contains("not available"))
    }

    @Test func defaultBranchPullEndpointGitFailureReturns409WithError() async throws {
        if skipInCI() { return }

        let puller: @Sendable (WebServer.PullDefaultBranchRequest) async -> WebServer.PullDefaultBranchOutcome = { _ in
            .gitFailed("fatal: Not possible to fast-forward")
        }
        let (server, port) = try Self.startServer(config: Self.makeConfig(defaultBranchPuller: puller))
        defer { server.stop() }

        let body = try JSONEncoder().encode(WebServer.PullDefaultBranchRequest(repoPath: "/tmp/repo"))
        var req = URLRequest(url: URL(string: "https://localhost:\(port)/repos/default-branch/pull")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let (data, response) = try await trustAllData(for: req)
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 409)
        struct ErrEnv: Codable { let error: String }
        let decoded = try JSONDecoder().decode(ErrEnv.self, from: data)
        #expect(decoded.error.contains("fast-forward"))
    }

    @Test func defaultBranchPullEndpointInvalidInputReturns400WithoutInvokingPuller() async throws {
        if skipInCI() { return }

        let puller: @Sendable (WebServer.PullDefaultBranchRequest) async -> WebServer.PullDefaultBranchOutcome = { _ in
            Issue.record("puller should not run on invalid input")
            return .internalFailure("should not reach")
        }
        let (server, port) = try Self.startServer(config: Self.makeConfig(defaultBranchPuller: puller))
        defer { server.stop() }

        var invalidJSON = URLRequest(url: URL(string: "https://localhost:\(port)/repos/default-branch/pull")!)
        invalidJSON.httpMethod = "POST"
        invalidJSON.setValue("application/json", forHTTPHeaderField: "Content-Type")
        invalidJSON.httpBody = Data("not json".utf8)

        let (_, invalidJSONResponse) = try await trustAllData(for: invalidJSON)
        #expect((invalidJSONResponse as! HTTPURLResponse).statusCode == 400)

        let body = try JSONEncoder().encode(WebServer.PullDefaultBranchRequest(repoPath: "   "))
        var emptyPath = URLRequest(url: URL(string: "https://localhost:\(port)/repos/default-branch/pull")!)
        emptyPath.httpMethod = "POST"
        emptyPath.setValue("application/json", forHTTPHeaderField: "Content-Type")
        emptyPath.httpBody = body

        let (_, emptyPathResponse) = try await trustAllData(for: emptyPath)
        #expect((emptyPathResponse as! HTTPURLResponse).statusCode == 400)
    }

    @Test func worktreesPostGitFailureReturns409WithError() async throws {
        if skipInCI() { return }

        let creator: @Sendable (WebServer.CreateWorktreeRequest) async -> WebServer.CreateWorktreeOutcome = { _ in
            .gitFailed("fatal: branch 'foo' already exists")
        }
        let (server, port) = try Self.startServer(config: Self.makeConfig(creator: creator))
        defer { server.stop() }

        let body = try JSONEncoder().encode(WebServer.CreateWorktreeRequest(
            repoPath: "/tmp/repo", worktreeName: "foo", branchName: "foo"
        ))
        var req = URLRequest(url: URL(string: "https://localhost:\(port)/worktrees")!)
        req.httpMethod = "POST"
        req.httpBody = body

        let (data, response) = try await trustAllData(for: req)
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 409, "git-reported failure should map to 409 Conflict")
        struct ErrEnv: Codable { let error: String }
        let decoded = try JSONDecoder().decode(ErrEnv.self, from: data)
        #expect(decoded.error.contains("already exists"))
    }

    @Test func worktreesPostInvalidJSONReturns400() async throws {
        if skipInCI() { return }

        let creator: @Sendable (WebServer.CreateWorktreeRequest) async -> WebServer.CreateWorktreeOutcome = { _ in
            Issue.record("creator should not run on invalid input")
            return .internalFailure("should not reach")
        }
        let (server, port) = try Self.startServer(config: Self.makeConfig(creator: creator))
        defer { server.stop() }

        var req = URLRequest(url: URL(string: "https://localhost:\(port)/worktrees")!)
        req.httpMethod = "POST"
        req.httpBody = Data("not json at all".utf8)

        let (_, response) = try await trustAllData(for: req)
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 400)
    }

    @Test func worktreesPostMissingFieldReturns400WithoutInvokingCreator() async throws {
        if skipInCI() { return }

        let creator: @Sendable (WebServer.CreateWorktreeRequest) async -> WebServer.CreateWorktreeOutcome = { _ in
            Issue.record("creator should not run when required JSON fields are missing")
            return .internalFailure("should not reach")
        }
        let (server, port) = try Self.startServer(config: Self.makeConfig(creator: creator))
        defer { server.stop() }

        var req = URLRequest(url: URL(string: "https://localhost:\(port)/worktrees")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(#"{"repoPath":"/tmp/repo","worktreeName":"feature-x"}"#.utf8)

        let (_, response) = try await trustAllData(for: req)
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 400)
    }

    @Test func worktreesPostEmptyFieldReturns400WithoutInvokingCreator() async throws {
        if skipInCI() { return }

        let creator: @Sendable (WebServer.CreateWorktreeRequest) async -> WebServer.CreateWorktreeOutcome = { _ in
            Issue.record("creator should not run when trimmed input is empty")
            return .internalFailure("should not reach")
        }
        let (server, port) = try Self.startServer(config: Self.makeConfig(creator: creator))
        defer { server.stop() }

        let body = try JSONEncoder().encode(WebServer.CreateWorktreeRequest(
            repoPath: "/tmp/repo", worktreeName: "   ", branchName: "feature-x"
        ))
        var req = URLRequest(url: URL(string: "https://localhost:\(port)/worktrees")!)
        req.httpMethod = "POST"
        req.httpBody = body

        let (_, response) = try await trustAllData(for: req)
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 400)
    }

    @Test func worktreesPostEmptyBranchReturns400WithoutInvokingCreator() async throws {
        if skipInCI() { return }

        let creator: @Sendable (WebServer.CreateWorktreeRequest) async -> WebServer.CreateWorktreeOutcome = { _ in
            Issue.record("creator should not run when trimmed branch is empty")
            return .internalFailure("should not reach")
        }
        let (server, port) = try Self.startServer(config: Self.makeConfig(creator: creator))
        defer { server.stop() }

        let body = try JSONEncoder().encode(WebServer.CreateWorktreeRequest(
            repoPath: "/tmp/repo", worktreeName: "feature-x", branchName: "   "
        ))
        var req = URLRequest(url: URL(string: "https://localhost:\(port)/worktrees")!)
        req.httpMethod = "POST"
        req.httpBody = body

        let (_, response) = try await trustAllData(for: req)
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 400)
    }

    @Test func worktreesGetReturns405() async throws {
        if skipInCI() { return }

        let (server, port) = try Self.startServer(config: Self.makeConfig(
            creator: { _ in .internalFailure("unused") }
        ))
        defer { server.stop() }

        let (_, response) = try await trustAllData(
            from: URL(string: "https://localhost:\(port)/worktrees")!
        )
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 405, "GET /worktrees should return Method Not Allowed")
    }

    @Test func worktreesDeleteReturns405() async throws {
        if skipInCI() { return }

        let (server, port) = try Self.startServer(config: Self.makeConfig(
            creator: { _ in .internalFailure("unused") }
        ))
        defer { server.stop() }

        var req = URLRequest(url: URL(string: "https://localhost:\(port)/worktrees")!)
        req.httpMethod = "DELETE"

        let (_, response) = try await trustAllData(for: req)
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 405, "DELETE /worktrees should return Method Not Allowed")
    }

    @Test func worktreesOversizedBodyReturns413WithoutInvokingCreator() async throws {
        if skipInCI() { return }

        let creator: @Sendable (WebServer.CreateWorktreeRequest) async -> WebServer.CreateWorktreeOutcome = { _ in
            Issue.record("creator should not run for oversized request body")
            return .internalFailure("should not reach")
        }
        let (server, port) = try Self.startServer(config: Self.makeConfig(creator: creator))
        defer { server.stop() }

        var req = URLRequest(url: URL(string: "https://localhost:\(port)/worktrees")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(repeating: UInt8(ascii: "x"), count: 64 * 1024 + 1)

        let (data, response) = try await trustAllData(for: req)
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 413)
        struct ErrEnv: Codable { let error: String }
        let decoded = try JSONDecoder().decode(ErrEnv.self, from: data)
        #expect(decoded.error.contains("exceeds"))
        #expect(decoded.error.contains("65536"))
    }

    @Test func worktreesPostWithoutCreatorReturns503() async throws {
        if skipInCI() { return }

        // No creator injected — `WebServerController` before
        // `setWorktreeCreator` is called, or a test that omits it. The
        // endpoint should advertise unavailability rather than 404 so
        // the client can tell "not supported yet" apart from "wrong URL".
        let (server, port) = try Self.startServer(config: Self.makeConfig(creator: nil))
        defer { server.stop() }

        let body = try JSONEncoder().encode(WebServer.CreateWorktreeRequest(
            repoPath: "/tmp/repo", worktreeName: "feature-x", branchName: "feature-x"
        ))
        var req = URLRequest(url: URL(string: "https://localhost:\(port)/worktrees")!)
        req.httpMethod = "POST"
        req.httpBody = body

        let (_, response) = try await trustAllData(for: req)
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 503)
    }

    @Test func worktreesPostExistingTruePassesUseExistingToClosure() async throws {
        if skipInCI() { return }

        // Verify that `existing: true` in the JSON body is decoded and
        // forwarded to the creator closure as `existing == true`.
        actor Box {
            var value: WebServer.CreateWorktreeRequest?
            func set(_ v: WebServer.CreateWorktreeRequest) { value = v }
        }
        let box = Box()
        let creator: @Sendable (WebServer.CreateWorktreeRequest) async -> WebServer.CreateWorktreeOutcome = { req in
            await box.set(req)
            return .success(WebServer.CreateWorktreeResponse(
                sessionName: "s", worktreePath: "/tmp/wt"
            ))
        }
        let (server, port) = try Self.startServer(config: Self.makeConfig(creator: creator))
        defer { server.stop() }

        let body = Data(#"{"repoPath":"/r","worktreeName":"x","branchName":"feat","existing":true}"#.utf8)
        var req = URLRequest(url: URL(string: "https://localhost:\(port)/worktrees")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let (_, response) = try await trustAllData(for: req)
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 200)
        let captured = await box.value
        #expect(captured?.existing == true)
        #expect(captured?.branchName == "feat")
    }

    @Test func worktreesPostMissingExistingFieldDefaultsFalse() async throws {
        if skipInCI() { return }

        // Back-compat: a payload without `existing` should decode to
        // `existing == false` so older clients keep working.
        actor Box {
            var value: WebServer.CreateWorktreeRequest?
            func set(_ v: WebServer.CreateWorktreeRequest) { value = v }
        }
        let box = Box()
        let creator: @Sendable (WebServer.CreateWorktreeRequest) async -> WebServer.CreateWorktreeOutcome = { req in
            await box.set(req)
            return .success(WebServer.CreateWorktreeResponse(
                sessionName: "s", worktreePath: "/tmp/wt"
            ))
        }
        let (server, port) = try Self.startServer(config: Self.makeConfig(creator: creator))
        defer { server.stop() }

        // No `existing` key in the payload.
        let body = Data(#"{"repoPath":"/r","worktreeName":"x","branchName":"feat"}"#.utf8)
        var req = URLRequest(url: URL(string: "https://localhost:\(port)/worktrees")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let (_, response) = try await trustAllData(for: req)
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 200)
        let captured = await box.value
        #expect(captured?.existing == false)
    }

    @Test func worktreesPostConflictOutcomeReturns409() async throws {
        if skipInCI() { return }

        // A creator returning `.conflict(message:)` should map to HTTP 409
        // so the client can distinguish "branch already mounted" from a
        // validation error (400) or a git process failure (also 409 via
        // .gitFailed, but semantically distinct).
        let creator: @Sendable (WebServer.CreateWorktreeRequest) async -> WebServer.CreateWorktreeOutcome = { _ in
            .conflict(message: "branch already mounted in another worktree")
        }
        let (server, port) = try Self.startServer(config: Self.makeConfig(creator: creator))
        defer { server.stop() }

        let body = try JSONEncoder().encode(WebServer.CreateWorktreeRequest(
            repoPath: "/tmp/repo", worktreeName: "feat", branchName: "feat", existing: true
        ))
        var req = URLRequest(url: URL(string: "https://localhost:\(port)/worktrees")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let (data, response) = try await trustAllData(for: req)
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 409, "conflict outcome should map to 409 Conflict")
        struct ErrEnv: Codable { let error: String }
        let decoded = try JSONDecoder().decode(ErrEnv.self, from: data)
        #expect(decoded.error.contains("already mounted"))
    }
}
