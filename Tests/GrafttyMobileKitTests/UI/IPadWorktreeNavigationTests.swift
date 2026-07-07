#if canImport(UIKit)
import Testing
import GrafttyProtocol
@testable import GrafttyMobileKit

@Suite("iPad worktree navigation")
struct IPadWorktreeNavigationTests {
    private func wt(
        _ path: String,
        attention: Bool = false,
        state: WorktreeWireState = .running
    ) -> WorktreePanes {
        WorktreePanes(
            path: path,
            displayName: path,
            repoDisplayName: "repo",
            displayBranch: path,
            state: state,
            isMainCheckout: false,
            prBadge: nil,
            stats: nil,
            attentionText: attention ? "needs input" : nil,
            layout: nil
        )
    }

    @Test("""
@spec IPAD-8.1: When the user presses next_tab on iPad and another selectable worktree has attention, the application shall select the next attention-carrying worktree in cyclic sidebar order.
""")
    func nextTabPrefersAttention() {
        #expect(IPadWorktreeNavigation.nextPath(
            in: [wt("/a"), wt("/b"), wt("/c", attention: true)],
            selectedPath: "/a",
            forward: true
        ) == "/c")
    }

    @Test("""
@spec IPAD-8.2: When no other iPad worktree has attention, next_tab and previous_tab shall cycle through selectable worktrees in sidebar order.
""")
    func cyclesWhenNoAttention() {
        let list = [wt("/a"), wt("/b"), wt("/c")]
        #expect(IPadWorktreeNavigation.nextPath(in: list, selectedPath: "/a", forward: true) == "/b")
        #expect(IPadWorktreeNavigation.nextPath(in: list, selectedPath: "/a", forward: false) == "/c")
    }

    @Test("""
@spec IPAD-8.3: iPad worktree navigation shall skip stale, creating, and deleting worktrees even when they carry attention.
""")
    func skipsNonSelectable() {
        let list = [
            wt("/a"),
            wt("/stale", attention: true, state: .stale),
            wt("/creating", attention: true, state: .creating),
            wt("/deleting", attention: true, state: .deleting),
            wt("/c")
        ]
        #expect(IPadWorktreeNavigation.nextPath(in: list, selectedPath: "/a", forward: true) == "/c")
    }

    @Test("""
@spec IPAD-8.6: When no current iPad worktree is selected, forward Ctrl+Tab shall start before the first selectable worktree and reverse Ctrl+Shift+Tab shall start after the last selectable worktree.
""")
    func startsAtEdgesWhenNothingSelected() {
        let list = [wt("/a"), wt("/b"), wt("/c")]
        #expect(IPadWorktreeNavigation.nextPath(in: list, selectedPath: nil, forward: true) == "/a")
        #expect(IPadWorktreeNavigation.nextPath(in: list, selectedPath: nil, forward: false) == "/c")
    }

    @Test("""
@spec IPAD-8.4: Pane-scoped attention shall count for iPad attention-first worktree navigation, excluding the currently selected worktree.
""")
    func paneAttentionCountsAndCurrentExcluded() {
        let paneAttention = WorktreePanes(
            path: "/b",
            displayName: "b",
            repoDisplayName: "repo",
            displayBranch: "b",
            state: .running,
            isMainCheckout: false,
            prBadge: nil,
            stats: nil,
            attentionText: nil,
            layout: .leaf(
                sessionName: "s",
                title: "shell",
                attentionText: "ping",
                isBusy: false,
                attentionSource: .agentStop
            )
        )
        #expect(IPadWorktreeNavigation.nextPath(
            in: [wt("/a", attention: true), paneAttention],
            selectedPath: "/a",
            forward: true
        ) == "/b")
    }
}
#endif
