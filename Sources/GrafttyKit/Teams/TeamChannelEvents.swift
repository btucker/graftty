import Foundation

/// Builders for the four `team_*` channel event types described in TEAM-5.* of SPECS.md.
///
/// These are thin constructors over `ChannelServerMessage.event(...)` so callers don't
/// duplicate the `type` string and attribute-key conventions.
public enum TeamChannelEvents {

    /// Wire-format type names for the three `team_*` channel events (TEAM-5.*).
    public enum EventType {
        public static let message       = "team_message"
        public static let memberJoined  = "team_member_joined"
        public static let memberLeft    = "team_member_left"
    }

    // MARK: - team_message (TEAM-5.1)

    public static func teamMessage(
        team: String,
        from sender: String,
        text: String
    ) -> ChannelServerMessage {
        .event(
            type: EventType.message,
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
            type: EventType.memberJoined,
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
            type: EventType.memberLeft,
            attrs: [
                "team": team,
                "member": member,
                "reason": reason.rawValue,
            ],
            body: "Coworker \"\(member)\" left (\(reason.rawValue))."
        )
    }

}
