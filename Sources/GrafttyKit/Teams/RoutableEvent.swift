import Foundation

/// One of the four event types the team-event routing matrix governs.
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
        case TeamChannelEvents.WireType.prStateChanged:
            if attrs["to"] == "merged" {
                self = .prMerged
            } else {
                self = .prStateChanged
            }
        case TeamChannelEvents.WireType.ciConclusionChanged:
            self = .ciConclusionChanged
        case TeamChannelEvents.WireType.mergeStateChanged:
            self = .mergabilityChanged
        default:
            return nil
        }
    }

    /// The matrix-row `RecipientSet` field this event uses.
    public func recipientSet(in prefs: TeamEventRoutingPreferences) -> RecipientSet {
        switch self {
        case .prStateChanged:        return prefs.prStateChanged
        case .prMerged:              return prefs.prMerged
        case .ciConclusionChanged:   return prefs.ciConclusionChanged
        case .mergabilityChanged:    return prefs.mergabilityChanged
        }
    }

    /// The wire-format `TeamChannelEvents.WireType` string for this routable
    /// event. `prStateChanged` and `prMerged` collapse to the same wire type
    /// (`pr_state_changed`); the matrix distinguishes them via `attrs.to`.
    public var wireType: String {
        switch self {
        case .prStateChanged, .prMerged:
            return TeamChannelEvents.WireType.prStateChanged
        case .ciConclusionChanged:
            return TeamChannelEvents.WireType.ciConclusionChanged
        case .mergabilityChanged:
            return TeamChannelEvents.WireType.mergeStateChanged
        }
    }

    /// Default English body text the legacy channel path produced, given
    /// the same `attrs` map. Kept here so `PRStatusStore` callers don't
    /// duplicate the format strings — the dispatcher is the only consumer
    /// today, but a future producer that wants to fire a synthetic
    /// transition (e.g. a unit test or a "dry-run" CLI) gets the same
    /// wording for free.
    public func defaultBody(attrs: [String: String]) -> String {
        let prNum = attrs["pr_number"] ?? "?"
        let from = attrs["from"] ?? "?"
        let to = attrs["to"] ?? "?"
        switch self {
        case .prStateChanged, .prMerged:
            return "PR #\(prNum) state changed: \(from) → \(to)"
        case .ciConclusionChanged:
            return "CI on PR #\(prNum): \(from) → \(to)"
        case .mergabilityChanged:
            // No producer fires `mergabilityChanged` yet; merge-state polling
            // lands as a follow-up. Format is speculative; revisit when the
            // first producer is wired.
            return "PR #\(prNum) mergability: \(from) → \(to)"
        }
    }
}
