import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyMobileKit

@MainActor
@Suite("Compact terminal presentation")
struct CompactTerminalPresentationTests {
    @Test("@spec IPAD-2.22: When a compact workspace opens Terminal, the application shall present its shells separately from the selected agent, reuse the selected live shell, and create one shell only when none exists.")
    func opensExistingShellAndCreatesOnlyWhenEmpty() async {
        let presentation = CompactTerminalPresentation()
        var launches = 0
        await presentation.open(in: worktree(shells: ["shell-a", "shell-b"])) {
            launches += 1
            return "new"
        }
        #expect(presentation.isPresented)
        #expect(presentation.selectedSession == "shell-a")
        presentation.select("agent", in: worktree(shells: ["shell-a", "shell-b"]))
        #expect(presentation.selectedSession == "shell-a")
        presentation.select("shell-b", in: worktree(shells: ["shell-a", "shell-b"]))
        presentation.isPresented = false
        await presentation.open(in: worktree(shells: ["shell-a", "shell-b"])) { launches += 1; return "new" }
        #expect(presentation.selectedSession == "shell-b")
        #expect(launches == 0)
        await presentation.open(in: worktree(shells: [])) { launches += 1; return "new" }
        #expect(presentation.selectedSession == "new")
        #expect(launches == 1)
    }

    @Test("@spec IPAD-2.23: When a user dismisses Terminal during shell creation, the application shall retain the resulting shell without reopening the sheet or launching a duplicate.")
    func dismissWhileCreatingDoesNotReopen() async {
        let presentation = CompactTerminalPresentation()
        let row = worktree(shells: [])
        var launches = 0
        await presentation.open(in: row) {
            launches += 1
            await presentation.open(in: row) { launches += 1; return "duplicate" }
            presentation.isPresented = false
            return "created"
        }
        #expect(launches == 1)
        #expect(!presentation.isPresented)
        #expect(presentation.selectedSession == "created")
        presentation.reconcile(in: row)
        #expect(presentation.selectedSession == "created")
        presentation.reconcile(in: worktree(shells: ["created"]))
        presentation.reconcile(in: worktree(shells: ["replacement"]))
        #expect(presentation.selectedSession == "replacement")
    }

    @Test("Delayed legacy inventory does not launch twice, and absent created shells expire.")
    func inventoryAcknowledgmentIsBounded() async {
        let presentation = CompactTerminalPresentation()
        var launches = 0
        let empty = worktree(shells: [])
        await presentation.open(in: empty) { launches += 1; return nil }
        presentation.isPresented = false
        await presentation.open(in: empty) { launches += 1; return nil }
        #expect(launches == 1)
        presentation.reconcile(in: worktree(shells: ["legacy-shell"]))
        #expect(presentation.selectedSession == "legacy-shell")
        #expect(presentation.pendingUntil == nil)
        await presentation.newTerminal { "already-exited" }
        presentation.reconcile(in: worktree(shells: ["replacement"]))
        presentation.expirePendingCreation(now: Date().addingTimeInterval(6))
        #expect(presentation.selectedSession == "replacement")
        #expect(presentation.pendingUntil == nil)
        #expect(presentation.error != nil)
    }

    @Test("Inventory arriving before the split response acknowledges both current and legacy hosts.", arguments: [true, false])
    func inventoryCanPrecedeResponse(exactID: Bool) async {
        let presentation = CompactTerminalPresentation()
        await presentation.open(in: worktree(shells: [])) {
            presentation.reconcile(in: worktree(shells: ["created"]))
            return exactID ? "created" : nil
        }
        #expect(presentation.selectedSession == "created")
        #expect(presentation.pendingUntil == nil)
        #expect(presentation.error == nil)
    }

    @Test("@spec IPAD-2.25: While a compact worktree has no agent with a presentable session, the application shall present its terminal panes full screen without the agent bar, the Terminal sheet, or the agent placeholder.")
    func plainWorktreesStayOffTheAgentWorkspace() {
        let shellOnly = worktree(shells: ["shell"])
        func row(_ agents: [AgentSessionInfo]?) -> WorktreePanes {
            WorktreePanes(path: shellOnly.path, displayName: shellOnly.displayName, repoDisplayName: shellOnly.repoDisplayName,
                displayBranch: shellOnly.displayBranch, state: .running, isMainCheckout: true, prBadge: nil, stats: nil,
                attentionText: nil, layout: shellOnly.layout, agents: agents)
        }
        let closedWithoutSession = AgentSessionInfo(id: "old", name: "Old", provider: "codex", status: "closed", sessionName: nil)
        for plain in [row(nil), row([]), row([closedWithoutSession])] {
            #expect(CompactTerminalPresentation.agentWorkspace(path: "/repo", rows: [plain], fallback: plain) == nil)
        }
        #expect(CompactTerminalPresentation.agentWorkspace(path: "/repo", rows: [], fallback: row([])) == nil)
        #expect(CompactTerminalPresentation.agentWorkspace(path: "/repo", rows: [shellOnly], fallback: nil) == shellOnly)
        #expect(CompactTerminalPresentation.agentWorkspace(path: "/repo", rows: [], fallback: shellOnly) == shellOnly)
        #expect(CompactTerminalPresentation.agentWorkspace(path: "/other", rows: [shellOnly], fallback: nil) == nil)
    }

    private func worktree(shells: [String]) -> WorktreePanes {
        let sessions = ["agent"] + shells
        let layout = sessions.dropFirst().reduce(PaneLayoutNode.leaf(sessionName: "agent", title: "Agent", attentionText: nil, isBusy: false, attentionSource: nil)) { tree, session in
            .split(direction: .horizontal, ratio: 0.5, left: tree,
                right: .leaf(sessionName: session, title: session, attentionText: nil, isBusy: false, attentionSource: nil))
        }
        return WorktreePanes(path: "/repo", displayName: "main", repoDisplayName: "repo", displayBranch: "main", state: .running,
            isMainCheckout: true, prBadge: nil, stats: nil, attentionText: nil, layout: layout,
            agents: [.init(id: "agent", name: "Agent", provider: "codex", status: "running", sessionName: "agent")])
    }
}
