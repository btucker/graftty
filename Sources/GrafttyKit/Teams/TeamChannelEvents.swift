import Foundation

/// Builders for the four `team_*` channel event types described in TEAM-5.* of SPECS.md.
///
/// These are thin constructors over `ChannelServerMessage.event(...)` so callers don't
/// duplicate the `type` string and attribute-key conventions.
public enum TeamChannelEvents {

    // MARK: - team_message (TEAM-5.1)

    public static func teamMessage(
        team: String,
        from sender: String,
        text: String
    ) -> ChannelServerMessage {
        .event(
            type: "team_message",
            attrs: ["team": team, "from": sender],
            body: text
        )
    }

    // MARK: - team_member_joined (TEAM-5.2)

    public static func memberJoined(
        team: String,
        member: String,
        branch: String,
        worktree: String
    ) -> ChannelServerMessage {
        .event(
            type: "team_member_joined",
            attrs: [
                "team": team,
                "member": member,
                "branch": branch,
                "worktree": worktree,
            ],
            body: "Coworker \"\(member)\" joined."
        )
    }

    // MARK: - team_member_left (TEAM-5.3)

    public enum LeaveReason: String, Sendable, Equatable {
        case removed
        case exited
    }

    public static func memberLeft(
        team: String,
        member: String,
        reason: LeaveReason
    ) -> ChannelServerMessage {
        .event(
            type: "team_member_left",
            attrs: [
                "team": team,
                "member": member,
                "reason": reason.rawValue,
            ],
            body: "Coworker \"\(member)\" left (\(reason.rawValue))."
        )
    }

    // MARK: - team_pr_merged (TEAM-5.4)

    public static func prMerged(
        team: String,
        member: String,
        prNumber: Int,
        branch: String,
        mergeSha: String
    ) -> ChannelServerMessage {
        .event(
            type: "team_pr_merged",
            attrs: [
                "team": team,
                "member": member,
                "pr_number": String(prNumber),
                "branch": branch,
                "merge_sha": mergeSha,
            ],
            body: "Coworker \"\(member)\"'s PR #\(prNumber) (\(branch)) merged."
        )
    }
}
