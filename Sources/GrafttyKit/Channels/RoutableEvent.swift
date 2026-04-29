import Foundation

/// One of the four event types the channel routing matrix governs.
/// Maps wire-format `ChannelServerMessage.event(...)` payloads to matrix rows.
public enum RoutableEvent: Sendable, Equatable {
    case prStateChanged
    case prMerged
    case ciConclusionChanged
    case mergabilityChanged

    /// Failable initializer: returns nil for events outside the matrix
    /// (e.g. `team_message`, `team_member_joined`). Distinguishes
    /// `pr_state_changed` with `attrs.to == "merged"` as the merged row.
    public init?(channelEventType type: String, attrs: [String: String]) {
        switch type {
        case ChannelEventType.prStateChanged:
            if attrs["to"] == "merged" {
                self = .prMerged
            } else {
                self = .prStateChanged
            }
        case ChannelEventType.ciConclusionChanged:
            self = .ciConclusionChanged
        case ChannelEventType.mergeStateChanged:
            self = .mergabilityChanged
        default:
            return nil
        }
    }

    /// The matrix-row `RecipientSet` field this event uses.
    public func recipientSet(in prefs: ChannelRoutingPreferences) -> RecipientSet {
        switch self {
        case .prStateChanged:        return prefs.prStateChanged
        case .prMerged:              return prefs.prMerged
        case .ciConclusionChanged:   return prefs.ciConclusionChanged
        case .mergabilityChanged:    return prefs.mergabilityChanged
        }
    }
}
