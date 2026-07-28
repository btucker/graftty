import Foundation

/// Ephemeral macOS notification and activation payload synthesized when a
/// directly connected Mac's durable `WorktreePanes` attention changes.
/// Keeping activation metadata separate lets reconnect collapse newly observed
/// offline attention into one actionable summary instead of replaying every
/// pane as a fresh system alert.
public struct RemoteNotificationEvent: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, Hashable {
        case userNotify = "user_notify"
        case agentStop = "agent_stop"
        case reconnectSummary = "reconnect_summary"
    }

    public let id: UUID
    public let kind: Kind
    public let origin: WorktreeOrigin
    /// Fingerprint of the directly connected Mac that emitted the event.
    /// Device IDs are user-controlled labels and are not unique across
    /// rotated/re-paired identities, so activation must use both values.
    public let originFingerprint: RemoteIdentityFingerprint?
    public let worktreeID: String
    public let paneID: String?
    public let title: String
    public let body: String
    public let timestamp: Date

    public init(
        id: UUID,
        kind: Kind,
        origin: WorktreeOrigin,
        originFingerprint: RemoteIdentityFingerprint? = nil,
        worktreeID: String,
        paneID: String?,
        title: String,
        body: String,
        timestamp: Date
    ) {
        self.id = id
        self.kind = kind
        self.origin = origin
        self.originFingerprint = originFingerprint
        self.worktreeID = worktreeID
        self.paneID = paneID
        self.title = title
        self.body = body
        self.timestamp = timestamp
    }
}
