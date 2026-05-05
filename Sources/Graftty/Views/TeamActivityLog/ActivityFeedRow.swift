import Foundation
import GrafttyKit

/// Resolved variant for a row in the Team Activity Log. Computed once
/// from a `TeamInboxMessage` by `resolve(_:)`; the view layer renders
/// purely from this value.
enum ActivityFeedRow: Equatable {
    case chat(
        worktree: String,
        recipient: String?,
        body: String,
        timestamp: Date,
        isUrgent: Bool
    )

    case system(
        worktree: String,
        iconName: String,
        body: String,
        timestamp: Date
    )

    case memberJoined(worktree: String)
    case memberLeft(worktree: String)
    case dayDivider(label: String)

    /// Pure mapping. The window's view-model wraps this in a
    /// `RenderedFeedItem` that adds continuation flags and weaves in
    /// `dayDivider` rows between midnight crossings.
    static func resolve(_ message: TeamInboxMessage) -> ActivityFeedRow {
        switch message.kind {
        case TeamChannelEvents.EventType.memberJoined:
            return .memberJoined(worktree: message.to.member)
        case TeamChannelEvents.EventType.memberLeft:
            return .memberLeft(worktree: message.to.member)
        case TeamChannelEvents.EventType.message:
            // Self-message reads as a one-actor entry rather than
            // "alice → alice".
            let recipient: String? = message.from.member == message.to.member
                ? nil
                : message.to.member
            return .chat(
                worktree: message.from.member,
                recipient: recipient,
                body: message.body,
                timestamp: message.createdAt,
                isUrgent: message.priority == .urgent
            )
        default:
            return .system(
                worktree: message.to.member,
                iconName: Self.iconName(forKind: message.kind),
                body: message.body,
                timestamp: message.createdAt
            )
        }
    }

    private static func iconName(forKind kind: String) -> String {
        switch kind {
        case TeamChannelEvents.WireType.prStateChanged: return "circle.fill"
        case TeamChannelEvents.WireType.ciConclusionChanged: return "checkmark.seal"
        case TeamChannelEvents.WireType.mergeStateChanged: return "arrow.triangle.merge"
        default: return "info.circle"
        }
    }
}
