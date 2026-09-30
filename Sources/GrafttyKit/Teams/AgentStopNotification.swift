import Foundation
import GrafttyProtocol

public struct AgentStopNotificationContent: Sendable, Equatable {
    public let title: String
    public let subtitle: String?
    public let body: String
    public let userInfo: [String: String]
    public let identifier: String?

    public init(title: String, subtitle: String? = nil, body: String, userInfo: [String: String], identifier: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.userInfo = userInfo
        self.identifier = identifier
    }
}

public struct AgentStopNotificationPayload: Sendable, Equatable {
    public let runtime: TeamHookRuntime
    public let worktreePath: String
    public let sessionID: String
    /// The zmx pane session name the agent runs in, when known. Lets the
    /// click handler focus the *exact* pane that produced the notification
    /// (resolved via `AgentStopAttentionTarget`) instead of the worktree's
    /// first pane. Nil when the agent isn't in a Graftty pane.
    public let paneSessionName: String?
    public let attentionTimestamp: Date

    public init(
        runtime: TeamHookRuntime,
        worktreePath: String,
        sessionID: String,
        paneSessionName: String?,
        attentionTimestamp: Date
    ) {
        self.runtime = runtime
        self.worktreePath = worktreePath
        self.sessionID = sessionID
        self.paneSessionName = paneSessionName
        self.attentionTimestamp = attentionTimestamp
    }
}

public enum AgentStopNotificationError: Error, Equatable {
    case invalidPayload
}

public enum AgentStopNotification {
    public static func content(
        runtime: TeamHookRuntime,
        worktreeName: String,
        worktreePath: String,
        sessionID: String,
        paneSessionName: String?,
        reason: AgentHookAttentionReason,
        timestamp: Date
    ) -> AgentStopNotificationContent {
        var userInfo = payloadMetadata(runtime: runtime, worktreePath: worktreePath, sessionID: sessionID,
                                       paneSessionName: paneSessionName, timestamp: timestamp)
        userInfo["attention_reason"] = reason.rawValue
        return AgentStopNotificationContent(
            title: attentionText(runtime: runtime, reason: reason),
            body: "\(worktreeName) requires your response.",
            userInfo: userInfo,
            identifier: "agent-attention:\(worktreePath)"
        )
    }

    public static func stoppedTurnContent(
        runtime: TeamHookRuntime, worktreeName: String, worktreePath: String,
        sessionID: String, paneSessionName: String?, stop: SidebarAgentStop, emoji: String?
    ) -> AgentStopNotificationContent? {
        guard let recap = stop.recap else { return nil }
        return AgentStopNotificationContent(
            title: recap.title,
            subtitle: [emoji, worktreeName].compactMap { $0 }.joined(separator: " "),
            body: recap.need ?? recap.completed,
            userInfo: payloadMetadata(runtime: runtime, worktreePath: worktreePath, sessionID: sessionID,
                                      paneSessionName: paneSessionName, timestamp: stop.stoppedAt),
            identifier: "agent-attention:\(worktreePath)"
        )
    }

    private static func payloadMetadata(runtime: TeamHookRuntime, worktreePath: String, sessionID: String,
                                        paneSessionName: String?, timestamp: Date) -> [String: String] {
        // Preserve activation compatibility with older delivered notifications.
        var userInfo = [
            "kind": "agent_stop",
            "runtime": runtime.rawValue,
            "worktree_path": worktreePath,
            "session_id": sessionID,
            "attention_timestamp": timestampString(timestamp),
        ]
        // Optional: only present when the agent runs in a Graftty pane, so
        // older payloads (and worktree-scoped pings) decode unchanged.
        if let paneSessionName {
            userInfo["pane_session_name"] = paneSessionName
        }
        return userInfo
    }

    public static func payload(from userInfo: [String: Any]) throws -> AgentStopNotificationPayload {
        guard userInfo["kind"] as? String == "agent_stop",
              let runtimeRaw = userInfo["runtime"] as? String,
              let runtime = TeamHookRuntime(rawValue: runtimeRaw),
              let worktreePath = userInfo["worktree_path"] as? String,
              let sessionID = userInfo["session_id"] as? String,
              let timestampRaw = userInfo["attention_timestamp"] as? String,
              let timestamp = formatter.date(from: timestampRaw)
        else {
            throw AgentStopNotificationError.invalidPayload
        }
        return AgentStopNotificationPayload(
            runtime: runtime,
            worktreePath: worktreePath,
            sessionID: sessionID,
            paneSessionName: userInfo["pane_session_name"] as? String,
            attentionTimestamp: timestamp
        )
    }

    /// Activating a notification selects the worktree and fully clears its
    /// attention — worktree-scoped AND every pane — exactly like a sidebar
    /// worktree click (both route through `WorktreeEntry.acknowledgeAttention`
    /// so they can't drift). Previously this cleared only worktree-scoped
    /// attention with a timestamp guard, leaving a pane "needs input" pill
    /// stuck after the click.
    public static func acknowledgeSelection(
        appState: inout AppState,
        worktreePath: String
    ) {
        appState.selectedWorktreePath = worktreePath
        for repoIndex in appState.repos.indices {
            for worktreeIndex in appState.repos[repoIndex].worktrees.indices
                where appState.repos[repoIndex].worktrees[worktreeIndex].path == worktreePath {
                appState.repos[repoIndex].worktrees[worktreeIndex].acknowledgeAttention()
            }
        }
    }

    public static func displayName(_ runtime: TeamHookRuntime) -> String {
        switch runtime {
        case .codex:
            return "Codex"
        case .claude:
            return "Claude"
        }
    }

    public static func attentionText(
        runtime: TeamHookRuntime,
        reason: AgentHookAttentionReason
    ) -> String {
        let runtimeName = displayName(runtime)
        switch reason {
        case .permission:
            return "\(runtimeName) needs permission"
        case .question:
            return "\(runtimeName) has a question"
        case .planReview:
            return "\(runtimeName) has a plan to review"
        }
    }

    public static func timestampString(_ date: Date) -> String {
        formatter.string(from: date)
    }

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
