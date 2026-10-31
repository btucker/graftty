import Foundation
import Testing
@testable import GrafttyProtocol

struct AgentSessionInfoTests {
    @Test("@spec LAYOUT-2.165: When publishing agent metadata, the application shall retain every session in the legacy pane inventory so older clients can still reach inactive tabs and drawer terminals.")
    func additiveMetadataRetainsLegacyInventory() throws {
        let row = WorktreePanes(path: "/repo", displayName: "main", repoDisplayName: "repo", displayBranch: "main",
            state: .running, isMainCheckout: true, prBadge: nil, stats: nil, attentionText: nil,
            layout: .leaf(sessionName: "session", title: "Agent", attentionText: nil, isBusy: false, attentionSource: nil),
            agents: [.init(id: "codex-123456789abc", name: "Review", provider: "codex", status: "running", sessionName: "session")])
        let restored = try JSONDecoder().decode(WorktreePanes.self, from: JSONEncoder().encode(row))
        #expect(restored.layout?.leaves.map(\.sessionName) == ["session"])
        #expect(restored.agents == row.agents)
        #expect(row.with(path: "/relay/repo").agents == row.agents)
        let old = Data(#"{"path":"/old","displayName":"main","repoDisplayName":"repo"}"#.utf8)
        #expect(try JSONDecoder().decode(WorktreePanes.self, from: old).agents == nil)
    }
    @Test("@spec LAYOUT-2.167: When an agent resumes after completion, the application shall retain earlier assignment results in Context metadata.")
    func retainsPreviousResults() throws {
        let agent = AgentSessionInfo(id: "agent", name: "Review", provider: "codex", status: "running", sessionName: "session",
            previousResults: ["Reviewed the first assignment"])
        let restored = try JSONDecoder().decode(AgentSessionInfo.self, from: JSONEncoder().encode(agent))
        #expect(restored.previousResults == ["Reviewed the first assignment"])
        #expect(restored.result == nil)
    }

}
