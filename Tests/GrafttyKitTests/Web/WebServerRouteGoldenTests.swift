import Testing
import Foundation
import GrafttyProtocol
@testable import GrafttyKit

#if os(macOS)
/// Byte-level characterization of every REST route the web client uses:
/// status, content type and body for each provider route and for every
/// outcome, 405, 503 and 400 path of the three POST routes. The golden
/// transcript was recorded from the server before the #483 route table, so
/// any wire change shows up as a diff. JSON bodies are compared with sorted
/// keys (see `normalized`).
///
/// Re-record with `GRAFTTY_RECORD_REST_GOLDEN=1` only for an intended wire
/// change. Skipped in CI like the other endpoint suites.
@Suite("WebServer — REST route wire transcript", .serialized)
struct WebServerRouteGoldenTests {
    private static let goldenURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("Fixtures/rest-routes.golden.txt")

    private static func startServer(_ config: WebServer.Config) throws -> (WebServer, Int) {
        let server = WebServer(config: config, auth: WebServer.AuthPolicy(isAllowed: { _ in true }),
                               bindAddresses: ["127.0.0.1"], tlsProvider: try makeTestTLSProvider())
        try server.start()
        guard case let .listening(_, port) = server.status else { throw NSError(domain: "test", code: 1) }
        return (server, port)
    }

    /// The outcome a stub returns, chosen by the request's first field.
    private static let wiredConfig = WebServer.Config(
        port: 0,
        zmxExecutable: URL(fileURLWithPath: "/dev/null"),
        zmxDir: URL(fileURLWithPath: "/tmp"),
        sessionsProvider: { [SessionInfo(name: "graftty-1", worktreePath: "/r/wt", repoDisplayName: "r", worktreeDisplayName: "wt")] },
        reposProvider: { [RepoInfo(path: "/r", displayName: "r",
                                   defaultBranchStatus: .init(branchName: "main", remoteRef: "origin/main", behindCount: 2),
                                   origin: WorktreeOrigin(deviceID: .init(value: "mac"), deviceLabel: "Mac", relayDepth: 0))] },
        agentCompletionsProvider: { worktree in worktree == nil ? [] : [] },
        relayedReposProvider: { [RepoInfo(path: "relay-r", displayName: "relay", branches: [])] },
        worktreeCreator: { request in
            switch request.worktreeName {
            case "invalid": return .invalid("bad name")
            case "git": return .gitFailed("fatal: branch exists")
            case "conflict": return .conflict(message: "branch is already mounted at b")
            case "internal": return .internalFailure("no surface")
            default: return .success(.init(sessionName: "graftty-1", worktreePath: "/r/.worktrees/" + request.worktreeName))
            }
        },
        defaultBranchPuller: { request in
            switch request.repoPath {
            case "/invalid": return .invalid("default checkout is not behind origin")
            case "/git": return .gitFailed("not a fast-forward")
            case "/internal": return .internalFailure("boom")
            default: return .success(.init(ok: true))
            }
        },
        worktreeRemover: { request in
            switch request.worktreePath {
            case "/invalid": return .invalid("cannot delete the repo's main checkout")
            case "/missing": return .notFound("unknown worktree path")
            case "/dirty": return .gitFailedForceable(stderr: "contains untracked files", shortStatus: "?? a")
            case "/final": return .gitFailedFinal("locked")
            case "/internal": return .internalFailure("boom")
            default: return .success(.init(dismissed: request.force))
            }
        },
        ghosttyConfigProvider: { "font-size = 13\n" },
        ghosttyKeybindingsProvider: { [:] },
        worktreePanesProvider: { [] }
    )

    private struct Call {
        let label: String
        let method: String
        let path: String
        var body: String?
        var headers: [String: String] = [:]
    }

    private static let calls: [Call] = [
        Call(label: "ws", method: "GET", path: "/ws"),
        Call(label: "sessions", method: "GET", path: "/sessions"),
        Call(label: "agent-completions", method: "GET", path: "/agent-completions?worktree=%2Fr%2Fwt"),
        Call(label: "repos-local", method: "GET", path: "/repos"),
        Call(label: "repos-relayed", method: "GET", path: "/repos",
             headers: [RemoteWorktreeFeatures.headerName: RemoteWorktreeFeatures.oneHopRelay]),
        Call(label: "panes", method: "GET", path: "/worktrees/panes"),
        Call(label: "ghostty-config", method: "GET", path: "/ghostty-config"),
        Call(label: "keybindings", method: "GET", path: "/ghostty-keybindings"),
        Call(label: "create-get", method: "GET", path: "/worktrees"),
        Call(label: "create-bad-json", method: "POST", path: "/worktrees", body: "{"),
        Call(label: "create-empty", method: "POST", path: "/worktrees",
             body: #"{"repoPath":"/r","worktreeName":" ","branchName":"b"}"#),
        Call(label: "create-ok", method: "POST", path: "/worktrees",
             body: #"{"repoPath":"/r","worktreeName":"a","branchName":"a"}"#),
        Call(label: "create-invalid", method: "POST", path: "/worktrees",
             body: #"{"repoPath":"/r","worktreeName":"invalid","branchName":"a"}"#),
        Call(label: "create-git", method: "POST", path: "/worktrees",
             body: #"{"repoPath":"/r","worktreeName":"git","branchName":"a","existing":true}"#),
        Call(label: "create-conflict", method: "POST", path: "/worktrees",
             body: #"{"repoPath":"/r","worktreeName":"conflict","branchName":"a"}"#),
        Call(label: "create-internal", method: "POST", path: "/worktrees",
             body: #"{"repoPath":"/r","worktreeName":"internal","branchName":"a"}"#),
        Call(label: "pull-get", method: "GET", path: "/repos/default-branch/pull"),
        Call(label: "pull-bad-json", method: "POST", path: "/repos/default-branch/pull", body: "[]"),
        Call(label: "pull-empty", method: "POST", path: "/repos/default-branch/pull", body: #"{"repoPath":"  "}"#),
        Call(label: "pull-ok", method: "POST", path: "/repos/default-branch/pull", body: #"{"repoPath":"/r"}"#),
        Call(label: "pull-invalid", method: "POST", path: "/repos/default-branch/pull", body: #"{"repoPath":"/invalid"}"#),
        Call(label: "pull-git", method: "POST", path: "/repos/default-branch/pull", body: #"{"repoPath":"/git"}"#),
        Call(label: "pull-internal", method: "POST", path: "/repos/default-branch/pull", body: #"{"repoPath":"/internal"}"#),
        Call(label: "delete-get", method: "GET", path: "/worktrees/delete"),
        Call(label: "delete-bad-json", method: "POST", path: "/worktrees/delete", body: #"{"worktreePath":"/r"}"#),
        Call(label: "delete-empty", method: "POST", path: "/worktrees/delete", body: #"{"worktreePath":"","force":false}"#),
        Call(label: "delete-ok", method: "POST", path: "/worktrees/delete", body: #"{"worktreePath":"/r/wt","force":true}"#),
        Call(label: "delete-invalid", method: "POST", path: "/worktrees/delete", body: #"{"worktreePath":"/invalid","force":false}"#),
        Call(label: "delete-missing", method: "POST", path: "/worktrees/delete", body: #"{"worktreePath":"/missing","force":false}"#),
        Call(label: "delete-dirty", method: "POST", path: "/worktrees/delete", body: #"{"worktreePath":"/dirty","force":false}"#),
        Call(label: "delete-final", method: "POST", path: "/worktrees/delete", body: #"{"worktreePath":"/final","force":true}"#),
        Call(label: "delete-internal", method: "POST", path: "/worktrees/delete", body: #"{"worktreePath":"/internal","force":false}"#),
        Call(label: "spa-fallback", method: "GET", path: "/session/graftty-1"),
    ]

    /// Unwired POST routes and keybindings answer 503.
    private static let unwiredCalls: [Call] = [
        Call(label: "unwired-create", method: "POST", path: "/worktrees",
             body: #"{"repoPath":"/r","worktreeName":"a","branchName":"a"}"#),
        Call(label: "unwired-pull", method: "POST", path: "/repos/default-branch/pull", body: #"{"repoPath":"/r"}"#),
        Call(label: "unwired-delete", method: "POST", path: "/worktrees/delete", body: #"{"worktreePath":"/r/wt","force":false}"#),
        Call(label: "unwired-keybindings", method: "GET", path: "/ghostty-keybindings"),
        Call(label: "unwired-repos", method: "GET", path: "/repos"),
    ]

    private static func transcript(_ calls: [Call], port: Int) async throws -> String {
        var lines: [String] = []
        for call in calls {
            var request = URLRequest(url: URL(string: "https://localhost:\(port)\(call.path)")!)
            request.httpMethod = call.method
            for (name, value) in call.headers { request.setValue(value, forHTTPHeaderField: name) }
            if let body = call.body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = Data(body.utf8)
            }
            let (data, response) = try await trustAllData(for: request)
            let http = try #require(response as? HTTPURLResponse)
            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "-"
            // The SPA index is the bundled app; its length pins it without
            // copying the bundle into the transcript.
            let body = call.label == "spa-fallback" ? "<\(data.count) bytes>" : Self.normalized(data)
            lines.append("\(call.label) \(http.statusCode) \(contentType) \(body)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `JSONEncoder` does not fix key order between encodings of the same
    /// value, so JSON bodies are compared with sorted keys; every other
    /// byte (status, content type, values, escaping) is compared as sent.
    private static func normalized(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let sorted = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]) else {
            return String(decoding: data, as: UTF8.self)
        }
        return String(decoding: sorted, as: UTF8.self)
    }

    @Test func everyRouteMatchesTheRecordedWire() async throws {
        if skipInCI() { return }
        let (wired, wiredPort) = try Self.startServer(Self.wiredConfig)
        defer { wired.stop() }
        let (unwired, unwiredPort) = try Self.startServer(WebServer.Config(
            port: 0, zmxExecutable: URL(fileURLWithPath: "/dev/null"), zmxDir: URL(fileURLWithPath: "/tmp")))
        defer { unwired.stop() }

        let actual = try await Self.transcript(Self.calls, port: wiredPort)
            + Self.transcript(Self.unwiredCalls, port: unwiredPort)

        if ProcessInfo.processInfo.environment["GRAFTTY_RECORD_REST_GOLDEN"] != nil {
            try actual.write(to: Self.goldenURL, atomically: true, encoding: .utf8)
            return
        }
        let golden = try String(contentsOf: Self.goldenURL, encoding: .utf8)
        for (expected, got) in zip(golden.split(separator: "\n"), actual.split(separator: "\n")) {
            #expect(got == expected)
        }
        #expect(actual == golden)
    }
}
#endif
