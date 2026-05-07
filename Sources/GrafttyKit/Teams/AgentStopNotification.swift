import Foundation

public struct AgentStopNotificationContent: Sendable, Equatable {
    public let title: String
    public let body: String
    public let userInfo: [String: String]

    public init(title: String, body: String, userInfo: [String: String]) {
        self.title = title
        self.body = body
        self.userInfo = userInfo
    }
}

public struct AgentStopNotificationPayload: Sendable, Equatable {
    public let runtime: TeamHookRuntime
    public let worktreePath: String
    public let sessionID: String
    public let attentionTimestamp: Date

    public init(
        runtime: TeamHookRuntime,
        worktreePath: String,
        sessionID: String,
        attentionTimestamp: Date
    ) {
        self.runtime = runtime
        self.worktreePath = worktreePath
        self.sessionID = sessionID
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
        timestamp: Date
    ) -> AgentStopNotificationContent {
        let runtimeName = displayName(runtime)
        return AgentStopNotificationContent(
            title: "\(runtimeName) needs input",
            body: "\(worktreeName) is waiting for you.",
            userInfo: [
                "kind": "agent_stop",
                "runtime": runtime.rawValue,
                "worktree_path": worktreePath,
                "session_id": sessionID,
                "attention_timestamp": timestampString(timestamp),
            ]
        )
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
            attentionTimestamp: timestamp
        )
    }

    public static func acknowledgeSelection(
        appState: inout AppState,
        worktreePath: String,
        timestamp: Date
    ) {
        appState.selectedWorktreePath = worktreePath
        for repoIndex in appState.repos.indices {
            for worktreeIndex in appState.repos[repoIndex].worktrees.indices
                where appState.repos[repoIndex].worktrees[worktreeIndex].path == worktreePath {
                appState.repos[repoIndex].worktrees[worktreeIndex].clearAttentionIfTimestamp(timestamp)
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

    public static func timestampString(_ date: Date) -> String {
        formatter.string(from: date)
    }

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
