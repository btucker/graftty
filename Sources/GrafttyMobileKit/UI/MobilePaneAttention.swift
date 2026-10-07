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

    static func openTarget(for context: SidebarWorktreeContext) -> SidebarActivityItem {
        context.pending.first ?? context.item
    }

    static func pendingCount(worktrees: [WorktreePanes], currentWorktree: String?, navigation: SidebarNavigationState) -> Int {
        let pending = worktrees.filter { $0.path != currentWorktree && $0.state.hasOnDiskWorktree && !navigation.worktreeContext($0).pending.isEmpty }
        return Set(pending.map { SidebarProjection.projectID($0) + "\u{0}" + $0.path }).count
    }

    static func displayedWorktrees(_ worktrees: [WorktreePanes]) -> [WorktreePanes] {
        func flatten(_ nodes: [SidebarWorktreeTree]) -> [WorktreePanes] {
            nodes.flatMap { node in
                if let worktree = node.worktree { return [worktree] }
                return flatten(node.children ?? [])
            }
        }
        return WorktreePickerGrouping.grouped(worktrees).flatMap { group in
            let sections = SidebarWorktreeSections(group.worktrees)
            return sections.hasPinMetadata
                ? flatten(SidebarWorktreeTree.nodes(sections.pinned)) + flatten(SidebarWorktreeTree.nodes(sections.tasks))
                : flatten(SidebarWorktreeTree.nodes(group.worktrees))
        }
    }

    @discardableResult
    static func open(worktrees: [WorktreePanes], projects: [SidebarProject], navigation: SidebarNavigationState,
                     currentWorktree: String? = nil) -> SidebarActivityItem? {
        let otherWorktrees = displayedWorktrees(worktrees)
        guard let item = navigation.nextPendingWorktree(in: otherWorktrees, projectID: nil, after: currentWorktree),
              projects.contains(where: { $0.id == item.projectID }) else { return nil }
        navigation.showProject(item.projectID)
        navigation.rememberedWorktrees[item.projectID] = item.worktreeID
        routes.pending[ObjectIdentifier(navigation)] = item
        return item
    }
}
