import GrafttyCommandUI
import GrafttyProtocol
import Observation

@MainActor
enum MobilePaneAttention {
    @Observable @MainActor
    final class Routes {
        var pending: [ObjectIdentifier: SidebarActivityItem] = [:]
    }
    private static let routes = Routes()

    static func pendingRoute(for navigation: SidebarNavigationState) -> SidebarActivityItem? {
        routes.pending[ObjectIdentifier(navigation)]
    }

    static func consumePendingRoute(for navigation: SidebarNavigationState) {
        routes.pending.removeValue(forKey: ObjectIdentifier(navigation))
    }

    static func route(_ item: SidebarActivityItem, navigation: SidebarNavigationState) {
        navigation.showProject(item.projectID)
        navigation.rememberedWorktrees[item.projectID] = item.worktreeID
        routes.pending[ObjectIdentifier(navigation)] = item
    }

    /// Stored system notifications can outlive the host's opaque route table.
    static func resolvedRoute(_ item: SidebarActivityItem, worktrees: [WorktreePanes]) -> SidebarActivityItem? {
        guard let target = worktrees.first(where: { worktree in
            guard SidebarProjection.projectID(worktree) == item.projectID else { return false }
            if let stableID = worktree.sidebar?.id {
                return item.id == stableID || item.id.hasPrefix(stableID + ":")
            }
            return worktree.path == item.worktreeID
        }) else { return nil }
        var resolved = item
        resolved.worktreeID = target.path
        return resolved
    }

    static func openTarget(for context: SidebarWorktreeContext) -> SidebarActivityItem {
        context.pending.first ?? context.item
    }

    static func pendingCount(worktrees: [WorktreePanes], currentWorktree: String?, navigation: SidebarNavigationState) -> Int {
        let pending = worktrees.filter { $0.path != currentWorktree && $0.state.hasOnDiskWorktree && !navigation.worktreeContext($0).pending.isEmpty }
        return Set(pending.map { SidebarProjection.projectID($0) + "\u{0}" + $0.path }).count
    }

    static func displayedWorktrees(_ worktrees: [WorktreePanes]) -> [WorktreePanes] {
        WorktreePickerGrouping.regions(worktrees, searching: false).flatMap { region in
            region.groups.flatMap {
                SidebarWorktreeReportOrder.displayedWorktrees($0.worktrees,
                    section: region.sidebarSection)
            }
        }
    }

    @discardableResult
    static func open(worktrees: [WorktreePanes], projects: [SidebarProject], navigation: SidebarNavigationState,
                     currentWorktree: String? = nil) -> SidebarActivityItem? {
        let otherWorktrees = displayedWorktrees(worktrees)
        guard let item = navigation.nextPendingWorktree(in: otherWorktrees, projectID: nil, after: currentWorktree),
              projects.contains(where: { $0.id == item.projectID }) else { return nil }
        route(item, navigation: navigation)
        return item
    }
}
