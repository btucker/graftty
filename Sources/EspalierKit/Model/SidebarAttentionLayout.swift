import Foundation

/// Sidebar rendering split for attention overlays (STATE-2.3).
///
/// The CLI path (`espalier notify`) writes to `WorktreeEntry.attention`
/// (worktree-scoped); shell-integration events (`COMMAND_FINISHED`)
/// write to `WorktreeEntry.paneAttention[terminalID]` (pane-scoped).
/// Each surface renders in its own slot — the worktree row carries the
/// worktree-scoped capsule, each pane row carries only its own
/// pane-scoped capsule. Kept as a pure helper so a unit test can pin
/// the invariant that one `notify` produces exactly one visible
/// capsule, independent of pane count.
public enum SidebarAttentionLayout {
    public struct Layout: Equatable {
        public let worktreeCapsule: String?
        public let paneCapsules: [TerminalID: String]

        public init(worktreeCapsule: String?, paneCapsules: [TerminalID: String]) {
            self.worktreeCapsule = worktreeCapsule
            self.paneCapsules = paneCapsules
        }
    }

    public static func layout(for worktree: WorktreeEntry) -> Layout {
        Layout(
            worktreeCapsule: worktree.attention?.text,
            paneCapsules: worktree.paneAttention.mapValues { $0.text }
        )
    }
}
