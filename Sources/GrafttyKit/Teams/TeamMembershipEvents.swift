import Foundation
import GrafttyProtocol

/// Helpers for firing `team_member_joined` and `team_member_left` events
/// (TEAM-5.2 and TEAM-5.3) when worktrees are added to or removed from a
/// team-enabled repo. Routes through `TeamEventDispatcher` so the event
/// lands as an inbox row addressed to the team lead.
public enum TeamMembershipEvents {

    /// Fire `team_member_joined` to the lead when a new worktree joins.
    ///
    /// Conditions that suppress the event:
    /// - `teamsEnabled` is false.
    /// - The repo has fewer than 2 worktrees (the joiner is alone).
    /// - The joiner is the lead itself (nobody else to notify).
    /// - The joiner path is not found in `repo.worktrees` (defensive guard).
    public static func fireJoined(
        repo: RepoEntry,
        joinerWorktreePath: String,
        teamsEnabled: Bool,
        dispatcher: TeamEventDispatcher
    ) {
        guard teamsEnabled, repo.worktrees.count >= 2 else { return }
        guard repo.worktrees.contains(where: { $0.path == joinerWorktreePath }) else { return }
        // If joiner is the root worktree (the lead), there is nobody to notify.
        guard repo.path != joinerWorktreePath else { return }

        do {
            try dispatcher.dispatchMemberJoined(
                joinerWorktreePath: joinerWorktreePath,
                repos: [repo]
            )
        } catch {
            NSLog("[Graftty] fireJoined dispatch failed: %@", String(describing: error))
        }
    }

    /// Fire `team_member_left` to the lead when a worktree is removed.
    ///
    /// Conditions that suppress the event:
    /// - `teamsEnabled` is false.
    /// - The lead is no longer present in `repo.worktrees` (nobody to notify).
    /// - The leaver *was* the lead (covered by the lead-gone guard above, and
    ///   also explicitly guarded for clarity).
    ///
    /// The caller passes the repo's state **after** removal so the guard
    /// "lead still exists" works correctly. The leaver's branch and path
    /// are passed separately because the entry is already gone from the model.
    public static func fireLeft(
        repo: RepoEntry,
        leaverBranch: String,
        leaverPath: String,
        reason: TeamChannelEvents.LeaveReason,
        teamsEnabled: Bool,
        dispatcher: TeamEventDispatcher
    ) {
        guard teamsEnabled else { return }
        // Notify the lead only if the lead is still present.
        guard repo.worktrees.contains(where: { $0.path == repo.path }) else { return }
        // If the leaver was the lead itself, don't fire.
        guard leaverPath != repo.path else { return }

        do {
            try dispatcher.dispatchMemberLeft(
                leaverBranch: leaverBranch,
                leaverWorktreePath: leaverPath,
                reason: reason,
                repos: [repo]
            )
        } catch {
            NSLog("[Graftty] fireLeft dispatch failed: %@", String(describing: error))
        }
    }

}
