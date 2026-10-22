import Foundation

// Payloads of the widest team requests. `NotificationMessage` writes the
// `type` tag beside these keys, so a payload's keys are the request's wire
// keys (frozen by ATTN-2.25); a payload encoded on its own lacks the tag and
// is not a request. Fields a newer CLI added decode with their historical
// defaults when an older CLI omits them.

/// `team_send`: a message to a worktree, provider, or exact agent.
public struct TeamSendRequest: Codable, Sendable, Equatable {
    public var callerWorktree: String
    public var callerAgentID: String?
    public var recipient: String
    public var text: String
    public var priority: TeamInboxPriority

    public init(callerWorktree: String, callerAgentID: String? = nil, recipient: String, text: String,
                priority: TeamInboxPriority) {
        self.callerWorktree = callerWorktree
        self.callerAgentID = callerAgentID
        self.recipient = recipient
        self.text = text
        self.priority = priority
    }

    enum CodingKeys: String, CodingKey {
        case callerWorktree = "caller_worktree"
        case callerAgentID = "caller_agent_id"
        case recipient, text, priority
    }
}

/// `team_reply`: a reply to a stored inbox message.
public struct TeamReplyRequest: Codable, Sendable, Equatable {
    public var callerWorktree: String
    public var callerAgentID: String?
    public var messageID: String
    public var text: String
    public var priority: TeamInboxPriority
    public var fallback: Bool

    public init(callerWorktree: String, callerAgentID: String? = nil, messageID: String, text: String,
                priority: TeamInboxPriority, fallback: Bool = false) {
        self.callerWorktree = callerWorktree
        self.callerAgentID = callerAgentID
        self.messageID = messageID
        self.text = text
        self.priority = priority
        self.fallback = fallback
    }

    enum CodingKeys: String, CodingKey {
        case callerWorktree = "caller_worktree"
        case callerAgentID = "caller_agent_id"
        case messageID = "message_id"
        case text, priority, fallback
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            callerWorktree: try container.decode(String.self, forKey: .callerWorktree),
            callerAgentID: try container.decodeIfPresent(String.self, forKey: .callerAgentID),
            messageID: try container.decode(String.self, forKey: .messageID),
            text: try container.decode(String.self, forKey: .text),
            priority: try container.decode(TeamInboxPriority.self, forKey: .priority),
            fallback: try container.decodeIfPresent(Bool.self, forKey: .fallback) ?? false
        )
    }
}

/// `team_hook`: one provider hook event, answered with rendered hook output.
public struct TeamHookRequest: Codable, Sendable, Equatable {
    public var callerWorktree: String
    public var callerAgentID: String?
    public var runtime: TeamHookRuntime
    public var event: TeamHookEvent
    public var sessionID: String?
    public var paneSessionName: String?
    public var attentionReason: AgentHookAttentionReason?
    public var stopHookActive: Bool
    public var providerSleepActivity: ProviderSleepActivity?

    public init(callerWorktree: String, callerAgentID: String? = nil, runtime: TeamHookRuntime,
                event: TeamHookEvent, sessionID: String?, paneSessionName: String?,
                attentionReason: AgentHookAttentionReason? = nil, stopHookActive: Bool = false,
                providerSleepActivity: ProviderSleepActivity? = nil) {
        self.callerWorktree = callerWorktree
        self.callerAgentID = callerAgentID
        self.runtime = runtime
        self.event = event
        self.sessionID = sessionID
        self.paneSessionName = paneSessionName
        self.attentionReason = attentionReason
        self.stopHookActive = stopHookActive
        self.providerSleepActivity = providerSleepActivity
    }

    enum CodingKeys: String, CodingKey {
        case callerWorktree = "caller_worktree"
        case callerAgentID = "caller_agent_id"
        case runtime, event
        case sessionID = "session_id"
        case paneSessionName = "pane_session_name"
        case attentionReason = "attention_reason"
        case stopHookActive = "stop_hook_active"
        case providerSleepActivity = "provider_sleep_activity"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            callerWorktree: try container.decode(String.self, forKey: .callerWorktree),
            callerAgentID: try container.decodeIfPresent(String.self, forKey: .callerAgentID),
            runtime: try container.decode(TeamHookRuntime.self, forKey: .runtime),
            event: try container.decode(TeamHookEvent.self, forKey: .event),
            sessionID: try container.decodeIfPresent(String.self, forKey: .sessionID),
            paneSessionName: try container.decodeIfPresent(String.self, forKey: .paneSessionName),
            attentionReason: try container.decodeIfPresent(AgentHookAttentionReason.self, forKey: .attentionReason),
            stopHookActive: try container.decodeIfPresent(Bool.self, forKey: .stopHookActive) ?? false,
            providerSleepActivity: try container.decodeIfPresent(ProviderSleepActivity.self,
                                                                 forKey: .providerSleepActivity)
        )
    }
}

/// `provider_activity`: one-way provider sleep evidence.
public struct ProviderActivityRequest: Codable, Sendable, Equatable {
    public var callerWorktree: String
    public var runtime: TeamHookRuntime
    public var sessionID: String?
    public var paneSessionName: String?
    public var activity: ProviderSleepActivity

    public init(callerWorktree: String, runtime: TeamHookRuntime, sessionID: String?, paneSessionName: String?,
                activity: ProviderSleepActivity) {
        self.callerWorktree = callerWorktree
        self.runtime = runtime
        self.sessionID = sessionID
        self.paneSessionName = paneSessionName
        self.activity = activity
    }

    enum CodingKeys: String, CodingKey {
        case callerWorktree = "caller_worktree"
        case runtime
        case sessionID = "session_id"
        case paneSessionName = "pane_session_name"
        case activity = "provider_sleep_activity"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            callerWorktree: try container.decode(String.self, forKey: .callerWorktree),
            runtime: try container.decode(TeamHookRuntime.self, forKey: .runtime),
            sessionID: try container.decodeIfPresent(String.self, forKey: .sessionID),
            paneSessionName: try container.decodeIfPresent(String.self, forKey: .paneSessionName),
            // A missing or unrecognized value must keep the provider awake.
            activity: (try? container.decode(ProviderSleepActivity.self, forKey: .activity)) ?? .unknown
        )
    }
}
