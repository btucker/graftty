import Foundation
import Testing
@testable import GrafttyKit

/// PWD-2.3 intent: "follow the pane the user is actively typing into" — i.e.
/// only yank the UI to the destination worktree when the reassigned pane
/// WAS the user's active typing target. Before this policy, any
/// background-pane `cd` across worktree boundaries would hijack the
/// user's view. Andy's "4 concurrent Claude sessions" scenario made this
/// immediately pathological: any claude doing `cd` in a non-viewed
/// worktree would yank Andy's selection away mid-typing.
@Suite("""
PWDReassignmentPolicy — UI-follow decision

@spec PWD-2.3: When a reassignment completes, the application shall set the destination worktree as the selected worktree and focus the moved pane — but only when the reassigned pane was the focused pane of the currently-selected worktree at the moment of the move. For any reassignment of a non-focused pane (a background shell's `cd`, e.g. an autonomous claude-code session in a worktree the user isn't looking at), the sidebar shall reflect the move via `PWD-2.1` / `PWD-2.2` but the user's current selection shall not change. This guards against multiple concurrent agent sessions autonomously yanking the user's view around; without the gate a single background `cd` hijacks the UI mid-typing.
""")
struct PWDReassignmentPolicyTests {

    @Test func followsWhenUserIsTypingInTheMovedPane() {
        let paneID = TerminalID()
        let source = "/tmp/wt-source"
        #expect(PWDReassignmentPolicy.shouldFollowToDestination(
            selectedWorktreePath: source,
            sourceWorktreePath: source,
            sourceFocusedTerminalID: paneID,
            reassignedTerminalID: paneID
        ))
    }

    @Test func doesNotFollowWhenUserIsViewingADifferentWorktree() {
        // Classic "background pane cd" repro: user is on worktree A, some
        // claude session in worktree B moves to C. Selection must stay on A.
        let paneID = TerminalID()
        #expect(!PWDReassignmentPolicy.shouldFollowToDestination(
            selectedWorktreePath: "/tmp/wt-user-is-here",
            sourceWorktreePath: "/tmp/wt-where-pane-was",
            sourceFocusedTerminalID: paneID,
            reassignedTerminalID: paneID
        ))
    }

    @Test func doesNotFollowWhenReassignedPaneWasNotFocused() {
        // User IS viewing the source worktree, but the moved pane isn't the
        // one the user's keyboard is aimed at. Selection must stay.
        let typingInto = TerminalID()
        let movingAway = TerminalID()
        let source = "/tmp/wt-source"
        #expect(!PWDReassignmentPolicy.shouldFollowToDestination(
            selectedWorktreePath: source,
            sourceWorktreePath: source,
            sourceFocusedTerminalID: typingInto,
            reassignedTerminalID: movingAway
        ))
    }

    @Test func doesNotFollowWhenNothingIsSelected() {
        // No selection (first launch pre-click, or post-Dismiss). A PWD
        // reassignment from some background pane shouldn't spontaneously
        // pick a worktree for the user.
        let paneID = TerminalID()
        #expect(!PWDReassignmentPolicy.shouldFollowToDestination(
            selectedWorktreePath: nil,
            sourceWorktreePath: "/tmp/wt-source",
            sourceFocusedTerminalID: paneID,
            reassignedTerminalID: paneID
        ))
    }

    @Test func doesNotFollowWhenSourceHadNoFocusedPane() {
        // Source worktree existed in the tree but had no focused pane
        // (edge case — shouldn't happen in practice, but the policy still
        // should not hijack selection based on an absent focus).
        let paneID = TerminalID()
        let source = "/tmp/wt-source"
        #expect(!PWDReassignmentPolicy.shouldFollowToDestination(
            selectedWorktreePath: source,
            sourceWorktreePath: source,
            sourceFocusedTerminalID: nil,
            reassignedTerminalID: paneID
        ))
    }
}
