import Foundation

/// Where an attention overlay came from. Lets clear logic be precise — the
/// resume rule (AGENT-3.4) clears only `.agentStop` pings, leaving a
/// deliberate `.userNotify` ping or a transient `.commandFinished` marker.
public enum AttentionSource: String, Codable, Sendable {
    case agentStop        // "<Agent> needs input" from a Stop hook
    case userNotify       // `graftty notify` — a deliberate user ping
    case commandFinished  // ✓ / ! shell-integration COMMAND_FINISHED
}

public struct Attention: Codable, Sendable, Equatable {
    public let text: String
    public let timestamp: Date
    public let clearAfter: TimeInterval?
    public let source: AttentionSource

    public init(
        text: String,
        timestamp: Date,
        clearAfter: TimeInterval? = nil,
        source: AttentionSource = .userNotify
    ) {
        self.text = text
        self.timestamp = timestamp
        self.clearAfter = clearAfter
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case text, timestamp, clearAfter, source
    }

    // Custom decode so a persisted payload from before `source` existed
    // still decodes (→ `.userNotify`, the conservative default that the
    // resume rule won't auto-clear). `encode(to:)` stays synthesized.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        clearAfter = try c.decodeIfPresent(TimeInterval.self, forKey: .clearAfter)
        source = try c.decodeIfPresent(AttentionSource.self, forKey: .source) ?? .userNotify
    }

    /// Upper bound for attention text, in `Character` (grapheme cluster)
    /// count. The sidebar capsule is sized for short status pings;
    /// piping `git log` etc. into `graftty notify` blows up layout and
    /// state.json. Shared with `NotifyInputValidation.textMaxLength`
    /// via proxy so CLI + server can't drift.
    public static let textMaxLength = 200

    /// Whether `text` is acceptable as the body of an attention overlay.
    /// Two failure modes (mirroring CLI-side `NotifyInputValidation`):
    ///   - empty or whitespace-only (ATTN-1.7 / ATTN-2.6)
    ///   - longer than `textMaxLength` characters (ATTN-1.10 / STATE-2.10)
    /// Used by the server to refuse ill-formed notify messages that
    /// slip past the CLI front door (raw `nc -U`, web surface, custom
    /// scripts).
    public static func isValidText(_ text: String) -> Bool {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if text.count > textMaxLength { return false }
        // Match CLI's ATTN-1.12: reject Cc-category scalars so a raw
        // socket client (`nc -U`, web surface) can't ship ANSI escapes,
        // tabs, or bells the sidebar would render as garbled glyphs.
        if text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) { return false }
        // ATTN-1.14 / STATE-2.13: BIDI-override scalars are Cf, not Cc
        // — the control gate above misses them. Reject so raw clients
        // can't land a Trojan-Source ping past the front door.
        if BidiOverrides.containsAny(text) { return false }
        // ATTN-1.13: text made entirely of format (Cf) + whitespace
        // renders as invisible. Swift's trim strips ZWSP but not BOM,
        // so this backstop catches the rest.
        if text.unicodeScalars.allSatisfy({
            $0.properties.isWhitespace || $0.properties.generalCategory == .format
        }) { return false }
        return true
    }

    /// Upper bound for `clearAfter` on the server side. Mirrors
    /// `NotifyInputValidation.clearAfterMaxSeconds` (Int). Expressed as
    /// `TimeInterval` for ergonomics at the DispatchQueue site.
    public static let clearAfterMaxSeconds: TimeInterval = 86_400

    /// Normalizes a requested `clearAfter` to what the server actually
    /// schedules:
    /// - nil or ≤0 → nil (STATE-2.8: no auto-clear timer)
    /// - in (0, max] → pass through unchanged
    /// - > max → clamped to `clearAfterMaxSeconds` (STATE-2.9): a
    ///   runaway value from a non-CLI socket client can't leak a
    ///   multi-year Dispatch work item into the main queue.
    public static func effectiveClearAfter(_ clearAfter: TimeInterval?) -> TimeInterval? {
        guard let c = clearAfter, c > 0 else { return nil }
        return min(c, clearAfterMaxSeconds)
    }
}
