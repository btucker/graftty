import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyMobileKit

@MainActor
struct MobileWorktreeOverviewTests {
    @Test("@spec IOS-4.55: When the phone shows a worktree with agents, the application shall list agent cards ordered by waiting for the user, working, idle, failed, then finished, each titled by its live terminal title and showing its question or result, followed by the worktree's shells and a one-line purpose from its brief.")
    func ordersAgentsByWhoNeedsTheUser() {
        func leaf(_ session: String, _ title: String, busy: Bool = true, stop: String? = nil) -> PaneLayoutNode {
            .leaf(sessionName: session, title: title, attentionText: stop, isBusy: busy, attentionSource: stop == nil ? nil : .agentStop)
        }
        let layout: PaneLayoutNode = [
            leaf("done", "Codex"), leaf("work", "Running swift test"),
            leaf("wait", "Claude", stop: "Should I push PR 806?"), leaf("idle", "Gemini", busy: false), leaf("shell", "zsh"),
        ].dropFirst().reduce(leaf("done", "Codex")) { .split(direction: .horizontal, ratio: 0.5, left: $0, right: $1) }
        let brief = WorktreeBrief(recap: AttentionRecap(title: "Agent workspaces", context: "Make the worktree recognizable",
            completed: "", next: ""), at: Date())
        let worktree = WorktreePanes(path: "/repo/wt", displayName: "wt", repoDisplayName: "repo", displayBranch: "wt",
            state: .running, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil, layout: layout,
            sidebar: .init(id: "wt", projectID: "repo", brief: brief),
            agents: [
                .init(id: "1", name: "Codex", provider: "codex", status: "closed", sessionName: nil, completionID: "c1",
                      result: "Merged the fix.", retainedSessionName: "done"),
                .init(id: "2", name: "Builder", provider: "codex", status: "running", sessionName: "work"),
                .init(id: "3", name: "Claude", provider: "claude", status: "running", sessionName: "wait"),
                .init(id: "4", name: "Gemini", provider: "gemini", status: "running", sessionName: "idle"),
            ])

        let overview = MobileWorktreeOverview(worktree: worktree)

        #expect(overview.agents.map(\.session) == ["wait", "work", "idle", "done"])
        #expect(overview.agents.map(\.state) == [.needsInput, .working, .idle, .finished])
        #expect(overview.agents[0].message == "Should I push PR 806?")
        #expect(overview.agents[1].title == "Running swift test")
        #expect(overview.agents[1].message == nil)
        #expect(overview.agents[3].message == "Merged the fix.")
        #expect(overview.terminals.map(\.session) == ["shell"])
        #expect(overview.purpose == "Agent workspaces. Make the worktree recognizable.")
    }
}
