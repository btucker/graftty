import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyKit

@Suite(.serialized)
struct AgentCompletionsEndpointTests {
    @Test("@spec TEAM-15.10: When an authorized web-access client requests agent completion with a worktree query, the application shall pass the decoded worktree ID to the catalog provider and return its candidates as JSON, and shall reject unauthorized clients before loading the catalog.")
    func authenticatedCatalogAndWorktreeQuery() async throws {
        if skipInCI() { return }
        let expected = AgentCompletionCandidate(address: "/repo/fix#codex", projectPath: "/repo", projectName: "repo",
            worktreePath: "relay-worktree-opaque", worktreeName: "fix", hostName: "This Mac", runtime: "codex")
        let target = "relay-worktree-opaque space%"
        for allowed in [false, true] {
            let config = WebServer.Config(port: 0, zmxExecutable: URL(fileURLWithPath: "/dev/null"),
                zmxDir: URL(fileURLWithPath: "/tmp"), agentCompletionsProvider: { worktree in
                    #expect(allowed)
                    #expect(worktree == target)
                    return [expected]
                })
            let server = WebServer(config: config, auth: .init(isAllowed: { _ in allowed }),
                bindAddresses: ["127.0.0.1"], tlsProvider: try makeTestTLSProvider())
            try server.start()
            defer { server.stop() }
            guard case .listening(_, let port) = server.status else { Issue.record("Server did not start"); return }
            var url = URLComponents(string: "https://localhost:\(port)/agent-completions")!
            url.queryItems = [.init(name: "worktree", value: target)]
            let (data, response) = try await trustAllData(from: url.url!)
            #expect((response as? HTTPURLResponse)?.statusCode == (allowed ? 200 : 403))
            if allowed { #expect(try JSONDecoder().decode([AgentCompletionCandidate].self, from: data) == [expected]) }
        }
    }
}
