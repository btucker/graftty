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
        let coworkerLines = coworkers
            .map { "  - \"\($0.name)\" — branch \($0.branch), worktree \($0.worktreePath)" }
            .joined(separator: "\n")

        return """
        You are "\(viewer.name)" — the LEAD worktree of Graftty agent team for repo \
        "\(team.repoDisplayName)", running in worktree \(viewer.worktreePath) on branch \(viewer.branch).

        Your coworkers (other worktrees of this repo with an agent session):
        \(coworkerLines.isEmpty ? "  (none yet)" : coworkerLines)

        To send a message to any teammate, run this shell command:
          graftty team msg <teammate-name> "<your message>"

        You may receive these automated team events that coworkers do NOT receive \
        directly (routed to the lead so the user has a single point to define \
        team-wide coordination policy):
          - team_member_joined — a new coworker joined; attrs: team, member, branch, worktree.
          - team_member_left   — a coworker left; attrs: team, member, reason (removed | exited).
          - pr_state_changed   — a worktree's PR transitioned (open/closed/merged); routing per matrix.
          - ci_conclusion_changed — a worktree's CI conclusion changed; routing per matrix.
          - merge_state_changed — a worktree's PR mergability changed; routing per matrix.

        You will also receive direct `team_message` rows from coworkers or the user \
        through Graftty team inbox hook updates at tool or stop boundaries.

        To see the current roster at any time:
          graftty team list
        """
    }

    // MARK: - Coworker variant

    private static func renderCoworker(team: TeamView, viewer: TeamMember) -> String {
        let lead = team.lead
        let peerCoworkers = team.members.filter {
            $0.role == .coworker && $0.worktreePath != viewer.worktreePath
        }
        let peerLines = peerCoworkers
            .map { "  - \"\($0.name)\" — branch \($0.branch), worktree \($0.worktreePath)" }
            .joined(separator: "\n")

        return """
        You are "\(viewer.name)" — a coworker on Graftty agent team for repo \
        "\(team.repoDisplayName)", running in worktree \(viewer.worktreePath) on branch \(viewer.branch).

        Your lead: "\(lead.name)" — worktree \(lead.worktreePath), branch \(lead.branch).
        Your peer coworkers (you may message these directly too):
        \(peerLines.isEmpty ? "  (none)" : peerLines)

        To send a message to the lead or any peer, run this shell command:
          graftty team msg <recipient-name> "<your message>"

        You will receive incoming messages through Graftty team inbox hook updates \
        at tool or stop boundaries.

        You do NOT receive status events about other coworkers — those route to the lead.

        To see the current roster at any time:
          graftty team list
        """
    }
}
