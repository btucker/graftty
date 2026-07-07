/// Renders the team-aware hook instructions text described in the agent-teams design doc.
///
/// Implements TEAM-3.1 / TEAM-3.2. Mechanism only — no behavioral prescription;
/// coordination policy is the user's to define.
public enum TeamInstructionsRenderer {

    public static func render(team: TeamView, viewer: TeamMember) -> String {
        switch viewer.role {
        case .lead:    return renderLead(team: team, viewer: viewer)
        case .coworker: return renderCoworker(team: team, viewer: viewer)
        }
    }

    // MARK: - Lead variant

    private static func renderLead(team: TeamView, viewer: TeamMember) -> String {
        let coworkers = team.members.filter { $0.role == .coworker }
        let worktreeLines = coworkers
            .map { "  - \"\($0.name)\" — branch \($0.branch), worktree \($0.worktreePath)" }
            .joined(separator: "\n")

        return """
        You are "\(viewer.name)" in the Graftty team for repo "\(team.repoDisplayName)".
        This is the main worktree: \(viewer.worktreePath) on branch \(viewer.branch).

        Other worktrees:
        \(worktreeLines.isEmpty ? "  (none)" : worktreeLines)

        Send a direct message:
          graftty team msg <name> "<message>"

        Repo/worktree status events route here:
          - team_member_joined — attrs: team, member, branch, worktree.
          - team_member_left — attrs: team, member, reason (removed | exited).
          - pr_state_changed — PR transitioned (open/closed/merged).
          - ci_conclusion_changed — CI conclusion changed.
          - merge_state_changed — PR mergeability changed.

        Direct `team_message` rows arrive through inbox hook updates.
        Current roster:
          graftty team list
        """
    }

    // MARK: - Coworker variant

    private static func renderCoworker(team: TeamView, viewer: TeamMember) -> String {
        let lead = team.lead
        let peerCoworkers = team.members.filter {
            $0.role == .coworker && $0.worktreePath != viewer.worktreePath
        }
        let worktreeLines = peerCoworkers
            .map { "  - \"\($0.name)\" — branch \($0.branch), worktree \($0.worktreePath)" }
            .joined(separator: "\n")

        return """
        You are "\(viewer.name)" in the Graftty team for repo "\(team.repoDisplayName)".
        This worktree: \(viewer.worktreePath) on branch \(viewer.branch).

        Main worktree: "\(lead.name)" — branch \(lead.branch), worktree \(lead.worktreePath).
        Other worktrees:
        \(worktreeLines.isEmpty ? "  (none)" : worktreeLines)

        Send a direct message:
          graftty team msg <name> "<message>"

        Direct messages arrive through inbox hook updates.
        Status events route to the main worktree.

        Current roster:
          graftty team list
        """
    }
}
