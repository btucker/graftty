import Foundation

/// Wire-shape envelope for events written to the team inbox. Kept around
/// after the channel-router teardown because the inbox dispatcher and
/// per-recipient renderer still need to round-trip `(type, attrs, body)`
/// payloads through JSON.
public enum ChannelServerMessage: Codable, Equatable, Sendable {
    case event(type: String, attrs: [String: String], body: String)

    private enum CodingKeys: String, CodingKey {
        case type, attrs, body
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .event(type, attrs, body):
            try c.encode(type, forKey: .type)
            try c.encode(attrs, forKey: .attrs)
            try c.encode(body, forKey: .body)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        let attrs = try c.decodeIfPresent([String: String].self, forKey: .attrs) ?? [:]
        let body = try c.decode(String.self, forKey: .body)
        self = .event(type: type, attrs: attrs, body: body)
    }
}

/// Builders for the `team_*` event types described in TEAM-5.* of SPECS.md.
///
/// These are thin constructors over `ChannelServerMessage.event(...)` so callers don't
/// duplicate the `type` string and attribute-key conventions.
public enum TeamChannelEvents {

    /// Wire-format type names for the `team_*` events (TEAM-5.*).
    public enum EventType {
        public static let message       = "team_message"
        public static let memberJoined  = "team_member_joined"
        public static let memberLeft    = "team_member_left"
    }

    /// Wire-format event-type strings used in inbox `kind` fields and as
    /// `ChannelServerMessage.event(type:)` discriminators for the routable
    /// PR/CI/merge events. Constants rather than an enum so the codebase
    /// can round-trip unknown types (e.g., a future event added by a
    /// downstream tool).
    public enum WireType {
        public static let prStateChanged       = "pr_state_changed"
        public static let ciConclusionChanged  = "ci_conclusion_changed"
        public static let mergeStateChanged    = "merge_state_changed"
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
