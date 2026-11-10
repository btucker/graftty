import Foundation
import GrafttyProtocol

/// @spec LAYOUT-2.210
/// How many worktrees in each project wait for the person: a question, a
/// notification, or a finished turn they haven't opened, pinned or not. It is
/// the number of Needs you rows plus lit tiles, so a project's count and its
/// list always agree.
public enum SidebarWaitingCounts {
    public static func byProject(_ rows: [WorktreePanes], context: (WorktreePanes) -> SidebarWorktreeContext) -> [String: Int] {
        var result: [String: Int] = [:]
        var seen: Set<String> = []
        for row in rows where seen.insert(MergedWorktreeList.identity(row)).inserted {
            let rowContext = context(row)
            guard SidebarRowStatus.resolve(context: rowContext, worktree: row, isCached: false).waitsForUser else { continue }
            result[SidebarProjection.projectID(row), default: 0] += 1
        }
        return result
    }
}
