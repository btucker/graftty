import Testing
import Foundation
@testable import GrafttyKit

/// Pins the spec STATE-2.3 rendering split: worktree-scoped attention
/// lives on the worktree row, pane-scoped attention lives on each
/// pane row — no cross-rendering. Prior to this helper, a single
/// `graftty notify` produced one capsule per pane (N panes = N
/// identical capsules in the sidebar), which buried the signal.
@Suite("""
SidebarAttentionLayout

@spec STATE-2.3: While a worktree entry has a worktree-scoped attention overlay, the sidebar shall render its text in a red capsule on the worktree's own row (next to the branch label), regardless of the worktree's running state. One worktree-scoped notification produces exactly one visible capsule — pane rows render only their own pane-scoped overlays per STATE-2.2 and do not mirror the worktree-scoped text. A notification set while a worktree is closed therefore remains visible on its row without requiring the user to launch panes first.
""")
struct SidebarAttentionLayoutTests {

    @Test func worktreeScopedAttentionRendersOnceRegardlessOfPaneCount() {
        var entry = WorktreeEntry(path: "/w", branch: "main", state: .running)
        entry.attention = Attention(text: "build failed", timestamp: Date())
        // Panes present but none with their own pane-scoped attention —
        // the key surface for the bug: N pane rows must not mean N
        // visible capsules.
        entry.splitTree = SplitTree(root: .leaf(TerminalID()))
        let layout = SidebarAttentionLayout.layout(for: entry)

        #expect(layout.worktreeCapsule == "build failed")
        #expect(layout.paneCapsules.isEmpty,
                "STATE-2.3: worktree-scoped attention must not duplicate onto pane rows")
    }

    @Test func paneScopedAttentionRendersOnlyOnItsOwnPane() {
        var entry = WorktreeEntry(path: "/w", branch: "main", state: .running)
        let t1 = TerminalID()
        let t2 = TerminalID()
        entry.paneAttention[t1] = Attention(text: "✗", timestamp: Date())
        let layout = SidebarAttentionLayout.layout(for: entry)

        #expect(layout.worktreeCapsule == nil)
        #expect(layout.paneCapsules[t1] == "✗")
        #expect(layout.paneCapsules[t2] == nil)
    }

    @Test func bothScopesRenderIndependentlyInTheirOwnSlots() {
        var entry = WorktreeEntry(path: "/w", branch: "main", state: .running)
        let t1 = TerminalID()
        entry.attention = Attention(text: "deploying", timestamp: Date())
        entry.paneAttention[t1] = Attention(text: "✗", timestamp: Date())
        let layout = SidebarAttentionLayout.layout(for: entry)

        #expect(layout.worktreeCapsule == "deploying")
        #expect(layout.paneCapsules[t1] == "✗")
    }

    @Test func noAttentionYieldsEmptyLayout() {
        let entry = WorktreeEntry(path: "/w", branch: "main", state: .running)
        let layout = SidebarAttentionLayout.layout(for: entry)

        #expect(layout.worktreeCapsule == nil)
        #expect(layout.paneCapsules.isEmpty)
    }
}
