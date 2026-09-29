import Testing
import GrafttyProtocol
@testable import Graftty

@MainActor
struct BreadcrumbBarTests {
    @Test("@spec LAYOUT-1.6: When the breadcrumb displays a selected worktree with an assigned emoji, the application shall show that emoji before its worktree name, using the selected remote snapshot's emoji without falling back to a local worktree's emoji.")
    func selectedWorktreeEmoji() {
        #expect(BreadcrumbBar.selectedWorktreeEmoji(localEmoji: "🌲", remoteWorktree: nil) == "🌲")
        #expect(BreadcrumbBar.selectedWorktreeEmoji(localEmoji: nil, remoteWorktree: nil) == nil)

        #expect(BreadcrumbBar.selectedWorktreeEmoji(localEmoji: "🌲", remoteWorktree: remote(emoji: "🚀")) == "🚀")
        #expect(BreadcrumbBar.selectedWorktreeEmoji(localEmoji: "🌲", remoteWorktree: remote(emoji: nil)) == nil)
        #expect(BreadcrumbBar.selectedWorktreeEmoji(localEmoji: "🌲", remoteWorktree: remote(emoji: nil, hasSidebar: false)) == nil)
    }

    private func remote(emoji: String?, hasSidebar: Bool = true) -> WorktreePanes {
        WorktreePanes(
            path: "/remote/feature", displayName: "feature", repoDisplayName: "Remote",
            displayBranch: "feature", state: .running, isMainCheckout: false,
            prBadge: nil, stats: nil, attentionText: nil, layout: nil,
            sidebar: hasSidebar ? .init(id: "remote-worktree", projectID: "remote-project", emoji: emoji) : nil
        )
    }
}
