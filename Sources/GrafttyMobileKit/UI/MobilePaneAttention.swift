import GrafttyCommandUI
import GrafttyProtocol

@MainActor
enum MobilePaneAttention {
    static func pendingCount(worktrees: [WorktreePanes], currentWorktree: String?, navigation: SidebarNavigationState) -> Int {
        let pending = SidebarProjection.activity(worktrees).filter {
            $0.worktreeID != currentWorktree && $0.needsAttention && !navigation.hasViewed($0)
        }
        return SidebarActivityCounts(items: pending).attentionByWorktree.values.reduce(0, +)
    }

    static func open(worktrees: [WorktreePanes], projects: [SidebarProject], navigation: SidebarNavigationState) {
        navigation.filter = .needsYou
        navigation.enterAttention(projects: projects, items: SidebarProjection.activity(worktrees))
    }
}
