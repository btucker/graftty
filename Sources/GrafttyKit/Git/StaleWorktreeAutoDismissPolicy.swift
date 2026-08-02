import Foundation

/// Pure eligibility policy for removing worktrees that have remained
/// deleted for the full grace period.
public enum StaleWorktreeAutoDismissPolicy {
    public static let defaultGracePeriod: TimeInterval = 60 * 60

    public static func expiredWorktreeIDs(
        in appState: AppState,
        now: Date,
        gracePeriod: TimeInterval = defaultGracePeriod
    ) -> [WorktreeEntry.ID] {
        appState.repos.flatMap { repo in
            repo.worktrees.compactMap { worktree in
                guard worktree.state == .stale,
                      let staleSince = worktree.staleSince,
                      now.timeIntervalSince(staleSince) >= gracePeriod else {
                    return nil
                }
                return worktree.id
            }
        }
    }
}
