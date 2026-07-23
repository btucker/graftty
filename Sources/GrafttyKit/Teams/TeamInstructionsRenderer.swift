/// Renders the team-aware hook instructions text described in the agent-teams design doc.
///
/// Implements TEAM-3.1 / TEAM-3.2. Mechanism only — no behavioral prescription;
/// coordination policy is the user's to define.
public enum TeamInstructionsRenderer {

    public static func render(team: TeamView, viewer: TeamMember) -> String {
        viewer.isMainWorktree
            ? renderMainWorktree(team: team, viewer: viewer)
            : renderLinkedWorktree(team: team, viewer: viewer)
    }

    // MARK: - Main-worktree variant

    private static func renderMainWorktree(team: TeamView, viewer: TeamMember) -> String {
        let linkedWorktrees = team.members.filter { !$0.isMainWorktree }
        let worktreeLines = linkedWorktrees
            .map { "  - \"\($0.name)\" — branch \($0.branch), worktree \($0.worktreePath)" }
            .joined(separator: "\n")

        return """
        You are "\(viewer.name)" in the Graftty team for repo "\(team.repoDisplayName)".
        This is the main worktree: \(viewer.worktreePath) on branch \(viewer.branch).

        Other worktrees:
        \(worktreeLines.isEmpty ? "  (none)" : worktreeLines)

        Repo/worktree status events route here:
          - team_member_joined — attrs: team, member, branch, worktree.
          - team_member_left — attrs: team, member, reason (removed | exited).
          - pr_state_changed — PR transitioned (open/closed/merged).
          - ci_conclusion_changed — CI conclusion changed.
          - merge_state_changed — PR mergeability changed.

        Direct `team_message` rows arrive through inbox hook updates.
        """
    }

    // MARK: - Linked-worktree variant

    private static func renderLinkedWorktree(team: TeamView, viewer: TeamMember) -> String {
        let mainWorktree = team.mainWorktree
        let otherLinkedWorktrees = team.members.filter {
            !$0.isMainWorktree && $0.worktreePath != viewer.worktreePath
        }
        let worktreeLines = otherLinkedWorktrees
            .map { "  - \"\($0.name)\" — branch \($0.branch), worktree \($0.worktreePath)" }
            .joined(separator: "\n")

        return """
        You are "\(viewer.name)" in the Graftty team for repo "\(team.repoDisplayName)".
        This worktree: \(viewer.worktreePath) on branch \(viewer.branch).

        Main worktree: "\(mainWorktree.name)" — branch \(mainWorktree.branch), worktree \(mainWorktree.worktreePath).
        Other worktrees:
        \(worktreeLines.isEmpty ? "  (none)" : worktreeLines)

        Direct messages arrive through inbox hook updates.
        Status events route to the main worktree.
        """
    }
}
