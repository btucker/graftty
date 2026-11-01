import Testing
@testable import GrafttyProtocol

struct SidebarAgentPresentationTests {
    @Test("@spec LAYOUT-2.178: While a worktree is shown in the sidebar, the application shall list only its live agent sessions with provider identity and retain ordinary terminals in the complete workspace inventory.")
    func sidebarOmitsShellsAndClosedAgents() {
        let leaves: [PaneLayoutNode] = ["shell", "codex", "claude", "closed"].map {
            .leaf(sessionName: $0, title: $0, attentionText: nil, isBusy: false, attentionSource: nil)
        }
        let tree = leaves.dropFirst().reduce(leaves[0]) { .split(direction: .horizontal, ratio: 0.5, left: $0, right: $1) }
        let row = WorktreePanes(path: "/repo", displayName: "repo", repoDisplayName: "repo", displayBranch: "main",
            state: .running, isMainCheckout: true, prBadge: nil, stats: nil, attentionText: nil, layout: tree,
            agents: [
                .init(id: "a", name: "Build", provider: "codex", status: "running", sessionName: "codex"),
                .init(id: "b", name: "Review", provider: "claude", status: "waiting", sessionName: "claude"),
                .init(id: "c", name: "Old", provider: "codex", status: "closed", sessionName: "closed"),
                .init(id: "d", name: "Failed", provider: "claude", status: "failed", sessionName: nil)
            ])
        #expect(row.sidebarAgentLeaves.map(\.sessionName) == ["codex", "claude"])
        #expect(row.layout?.leaves.count == 4)
        for metadata: [AgentSessionInfo]? in [[], nil] {
            let shellOnly = WorktreePanes(path: "/repo", displayName: "repo", repoDisplayName: "repo", displayBranch: "main",
                state: .running, isMainCheckout: true, prBadge: nil, stats: nil, attentionText: nil, layout: tree, agents: metadata)
            #expect(shellOnly.sidebarAgentLeaves.isEmpty)
        }
    }
}
