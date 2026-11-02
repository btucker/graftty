import Testing
@testable import GrafttyProtocol

struct SidebarAgentPresentationTests {
    @Test func closedWorktreeKeepsCompletedSidebarTabs() {
        let row = WorktreePanes(path: "/repo", displayName: "repo", repoDisplayName: "repo", displayBranch: "main",
            state: .closed, isMainCheckout: true, prBadge: nil, stats: nil, attentionText: nil,
            layout: nil, agents: [.init(id: "done", name: "Finished", provider: "codex", status: "closed",
                sessionName: nil, retainedSessionName: "done")])
        var workspace = WorkspaceLayout<String>()
        workspace.addAgent("done")
        #expect(row.sidebarAgentLeaves(in: workspace).map(\.sessionName) == ["done"])
        workspace.remove("done")
        #expect(row.sidebarAgentLeaves(in: workspace).isEmpty)
    }

    @Test("@spec LAYOUT-2.188: While a live agent is listed in the sidebar or agent tabs, the application shall use its current terminal title and fall back to its assignment name only when the terminal title is blank.")
    func liveTitleTakesPrecedence() {
        #expect(SidebarAgentTitle.display(terminalTitle: "Investigating focus", agentName: "Review") == "Investigating focus")
        #expect(SidebarAgentTitle.display(terminalTitle: "Tests passing", agentName: "Review") == "Tests passing")
        #expect(SidebarAgentTitle.display(terminalTitle: "", agentName: "Review") == "Review")
        #expect(SidebarAgentTitle.display(terminalTitle: " \n", agentName: "Review") == "Review")
        #expect(SidebarAgentTitle.display(terminalTitle: "Legacy title", agentName: nil) == "Legacy title")
    }

    @Test func workspaceTabsUseCurrentTitleAndPreserveArchivedFallback() {
        func row(_ title: String?) -> WorktreePanes {
            WorktreePanes(path: "/repo", displayName: "repo", repoDisplayName: "repo", displayBranch: "main",
                state: .running, isMainCheckout: true, prBadge: nil, stats: nil, attentionText: nil,
                layout: title.map { .leaf(sessionName: "codex", title: $0, attentionText: nil, isBusy: false, attentionSource: nil) },
                agents: [.init(id: "a", name: "Codex", provider: "codex", status: "running", sessionName: "codex")])
        }
        #expect(row("Investigating focus").workspaceSessionTitle("codex") == "Investigating focus")
        #expect(row("Tests passing").workspaceSessionTitle("codex") == "Tests passing")
        #expect(row(" \n").workspaceSessionTitle("codex") == "Codex")
        #expect(row(nil).workspaceSessionTitle("codex") == "Codex")
        #expect(row(nil).workspaceSessionTitle("missing") == "Terminal")
    }

    @Test
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
                .init(id: "c", name: "Old", provider: "codex", status: "closed", sessionName: nil, retainedSessionName: "closed"),
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

    @Test("@spec LAYOUT-2.178: While a worktree displays agent tabs, the application shall list only those tabs in its sidebar in canvas group and tab order, exclude terminal drawer sessions, and retain completed tabs until dismissed.")
    func sidebarFollowsClientTabsInsteadOfInventory() throws {
        let inventory = ["shell", "a", "b", "c", "drawer"].map {
            PaneLayoutNode.leaf(sessionName: $0, title: $0, attentionText: nil, isBusy: false, attentionSource: nil)
        }
        let tree = inventory.dropFirst().reduce(inventory[0]) {
            .split(direction: .horizontal, ratio: 0.5, left: $0, right: $1)
        }
        let row = WorktreePanes(path: "/repo", displayName: "repo", repoDisplayName: "repo", displayBranch: "main",
            state: .running, isMainCheckout: true, prBadge: nil, stats: nil, attentionText: nil, layout: tree,
            agents: ["a", "b", "c", "drawer"].map {
                AgentSessionInfo(id: $0, name: $0, provider: "codex", status: "running", sessionName: $0)
            } + [.init(id: "done", name: "Completed review", provider: "claude", status: "closed",
                       sessionName: nil, retainedSessionName: "done")])
        let right = WorkspaceLayout<String>.Group(sessions: ["b", "done", "a", "shell"], selected: "b")
        let left = WorkspaceLayout<String>.Group(sessions: ["c"], selected: "c")
        var workspace = WorkspaceLayout<String>(
            root: .split(vertical: false, ratio: 0.5, first: .group(left.id), second: .group(right.id)),
            groups: [right, left])
        workspace.addTerminal("drawer")
        #expect(row.sidebarAgentLeaves(in: workspace).map(\.sessionName) == ["c", "b", "done", "a"])
        #expect(row.sidebarAgentLeaves(in: workspace).first { $0.sessionName == "done" }?.title == "Completed review")
        let moved = workspace.moveTab("a", relativeTo: "b", after: false)
        #expect(moved)
        #expect(row.sidebarAgentLeaves(in: workspace).map(\.sessionName) == ["c", "a", "b", "done"])
        workspace.remove("done")
        #expect(row.sidebarAgentLeaves(in: workspace).map(\.sessionName) == ["c", "a", "b"])
        #expect(row.layout?.leaves.map(\.sessionName) == ["shell", "a", "b", "c", "drawer"])
    }
}
