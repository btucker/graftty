import Foundation
import GrafttyCommandUI
import GrafttyProtocol
import Testing
@testable import GrafttyMobileKit

@Suite("Pane Attention navigation")
@MainActor
struct MobilePaneAttentionTests {
    @Test("@spec IOS-4.34: While a mobile pane is open, its back button shall badge unviewed Needs Attention cards from other worktrees and open Needs Attention when tapped with a nonzero badge.")
    func countsOtherWorktreesAndOpensNeedsYou() {
        let navigation = SidebarNavigationState(prefix: "pane-attention.\(UUID())")
        let current = worktree("current")
        let other = worktree("other")
        let viewed = worktree("viewed")
        let completedCommand = worktree("command", source: .commandFinished)
        let rows = [current, other, viewed, completedCommand]
        navigation.opened(SidebarProjection.activity([viewed])[0])
        #expect(MobilePaneAttention.pendingCount(worktrees: rows, currentWorktree: current.path, navigation: navigation) == 1)
        navigation.filter = .running
        navigation.query = "old search"
        MobilePaneAttention.open(worktrees: rows, projects: SidebarProjection.projects(rows), navigation: navigation)
        #expect(navigation.showsAttention)
        #expect(navigation.filter == .needsYou)
        #expect(navigation.query.isEmpty)
        #expect(MobilePaneAttention.pendingCount(worktrees: [current, viewed, completedCommand], currentWorktree: current.path, navigation: navigation) == 0)
    }

    @Test("A new stop at a previously viewed worktree counts again")
    func newerOccurrenceCounts() {
        let navigation = SidebarNavigationState(prefix: "pane-attention.\(UUID())")
        let first = worktree("other")
        navigation.opened(SidebarProjection.activity([first])[0])
        let next = worktree("other", stoppedAt: 110)
        #expect(MobilePaneAttention.pendingCount(worktrees: [next], currentWorktree: "/current", navigation: navigation) == 1)
    }

    private func worktree(_ name: String, source: AttentionSource = .agentStop, stoppedAt: TimeInterval = 100) -> WorktreePanes {
        WorktreePanes(path: "/\(name)", displayName: name, repoDisplayName: "Project", displayBranch: name,
            state: .running, isMainCheckout: false, prBadge: nil, stats: nil,
            attentionText: source == .commandFinished ? "Done" : nil,
            attentionSource: source == .commandFinished ? source : nil, layout: nil,
            sidebar: .init(id: name, projectID: "project", unseenAgentStop: source == .agentStop
                ? .init(agentName: "Codex", stoppedAt: Date(timeIntervalSince1970: stoppedAt)) : nil))
    }
}
