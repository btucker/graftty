import Testing
import Foundation
import GrafttyProtocol
@testable import GrafttyKit

struct AgentCompletionCatalogTests {
    @Test("@spec TEAM-15.12: When completion opens in a quiet or externally located tracked worktree, the application shall determine current-project priority from registered worktree membership rather than candidate presence or directory nesting.")
    func quietExternalWorktreePriority() {
        let project = RepoEntry(path: "/projects/a", displayName: "A", worktrees: [.init(path: "/projects/b/quiet", branch: "quiet")])
        let candidate = AgentCompletionCandidate(address: "/projects/a/fix#codex", projectPath: project.path,
            projectName: "Z Project", worktreePath: "/projects/a/fix", worktreeName: "fix", hostName: "Mac", runtime: "codex")
        let other = AgentCompletionCandidate(address: "/projects/b/fix#codex", projectPath: "/projects/b",
            projectName: "A Project", worktreePath: "/projects/b/fix", worktreeName: "fix", hostName: "Mac", runtime: "codex")
        let entries = AgentCompletionCatalog.contextualized([other, candidate], worktreePath: "/projects/b/quiet", repos: [project])
        #expect(AgentCompletionCandidate.matching(entries, query: "", currentWorktreePath: "/projects/b/quiet").first?.address == candidate.address)
        #expect(AgentCompletionCandidate.matching(entries, query: "", currentWorktreePath: "relay-worktree-quiet").first?.address == candidate.address)
    }
    @Test("@spec TEAM-15.5: When native agent completion loads the catalog, the application shall include reachable top-level agents from every tracked project, omit stale and untracked agents, and use stable worktree/provider addresses with canonical host routing for remote candidates.")
    func onlyRoutableAgents() {
        let repo = RepoEntry(path: "/repo", displayName: "Project", worktrees: [.init(path: "/repo/fix", branch: "fix")])
        func record(_ session: String, subagent: Bool = false, path: String = "/repo/fix") -> TeamPresenceRecord {
            .init(teamID: TeamLookup.id(forRepoPath: "/repo"), worktree: path, runtime: .codex,
                  paneSessionName: nil, pid: 123, registeredAt: Date(), runtimeSessionID: session, isSubagent: subagent)
        }
        let entries = AgentCompletionCatalog.local(repos: [repo], records: [record("live"), record("stale"), record("child", subagent: true), record("outside", path: "/untracked")], isReachable: { $0.runtimeSessionID != "stale" })
        #expect(entries.count == 1)
        #expect(entries.first?.address == "/repo/fix#codex")
        #expect(entries.first?.projectPath == "/repo")
        let remoteAgent = TeamListAgent(id: "codex-0123456789ab", address: "graftty-mac://host/repo/fix#codex-0123456789ab", runtime: .codex, displayName: nil, isReachable: true, paneSessionName: nil)
        let remote = TeamListMember(name: "Build Mac/Project/fix", branch: "fix", worktreePath: "graftty-mac://host/repo/fix", isMainWorktree: false, isRunning: true, agents: [remoteAgent], projectPath: "graftty-mac://host/repo", projectName: "Project")
        let candidates = AgentCompletionCatalog.remote(members: [remote])
        #expect(candidates.first?.address == "graftty-mac://host/repo/fix#codex")
        #expect(candidates.first?.hostName == "Build Mac")
        #expect(candidates.first?.projectPath == "graftty-mac://host/repo")
    }

    @Test("@spec TEAM-15.6: When a paired client requests agent completions, the application shall round-trip the candidate catalog through the worktree management protocol without changing routing addresses.")
    func managementRoundTrip() throws {
        let request = WorktreeManagementRequest.agentCompletions
        #expect(try JSONDecoder().decode(WorktreeManagementRequest.self, from: JSONEncoder().encode(request)) == request)
        let scoped = WorktreeManagementRequest.worktreeAgentCompletions(worktreeID: "relay-worktree-opaque")
        #expect(try JSONDecoder().decode(WorktreeManagementRequest.self, from: JSONEncoder().encode(scoped)) == scoped)
        let response = WorktreeManagementResponse.agentCompletions([.init(address: "/repo/fix#codex", projectPath: "/repo", projectName: "Repo", worktreePath: "/repo/fix", worktreeName: "fix", hostName: "This Mac", runtime: "codex")])
        #expect(try JSONDecoder().decode(WorktreeManagementResponse.self, from: JSONEncoder().encode(response)) == response)
    }
}
