import Foundation

/// APNs `userInfo.kind` discriminators. The iOS app keys off these to
/// dispatch alerts vs silent-remove pushes; the strings here are the
/// shared contract between sender (this file + `AgentStopNotification`)
/// and receiver (`DeepLinkRouter` / `PushReceiver` in `GrafttyMobileKit`,
/// which duplicates these constants because of the no-shared-module rule).
public enum PushPayloadKind {
    public static let agentStop = "agent_stop"
    public static let agentStopClear = "agent_stop_clear"
}

public struct ApnsEnvelope: Sendable, Equatable {
    public enum PushType: String, Sendable { case alert, background }

    public let pushType: PushType
    public let topic: String
    public let collapseID: String
    public let payload: Data
    public let priority: Int

    public init(pushType: PushType, topic: String, collapseID: String, payload: Data, priority: Int) {
        self.pushType = pushType
        self.topic = topic
        self.collapseID = collapseID
        self.payload = payload
        self.priority = priority
    }

    /// Construct an alert envelope from an `AgentStopNotificationContent`.
    public static func alert(
        topic: String,
        worktreePath: String,
        attentionTimestamp: Date,
        content: AgentStopNotificationContent
    ) throws -> ApnsEnvelope {
        var info: [String: Any] = [
            "aps": ["alert": ["title": content.title, "body": content.body], "sound": "default"],
        ]
        for (k, v) in content.userInfo { info[k] = v }
        let data = try JSONSerialization.data(withJSONObject: info, options: [.sortedKeys])
        return ApnsEnvelope(pushType: .alert, topic: topic,
                            collapseID: collapseID(worktreePath: worktreePath, attentionTimestamp: attentionTimestamp),
                            payload: data, priority: 10)
    }

    /// Silent-remove envelope carrying `kind: PushPayloadKind.agentStopClear`.
    public static func clear(
        topic: String,
        worktreePath: String,
        attentionTimestamp: Date
    ) throws -> ApnsEnvelope {
        let cid = collapseID(worktreePath: worktreePath, attentionTimestamp: attentionTimestamp)
        let payload: [String: Any] = [
            "aps": ["content-available": 1],
            "kind": PushPayloadKind.agentStopClear,
            "collapse_id": cid,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return ApnsEnvelope(pushType: .background, topic: topic, collapseID: cid,
                            payload: data, priority: 5)
    }

    private static func collapseID(worktreePath: String, attentionTimestamp: Date) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return "\(worktreePath):\(iso.string(from: attentionTimestamp))"
    }
}
