import Foundation

public struct Attention: Codable, Sendable, Equatable {
    public let text: String
    public let timestamp: Date
    public let clearAfter: TimeInterval?

    public init(text: String, timestamp: Date, clearAfter: TimeInterval? = nil) {
        self.text = text
        self.timestamp = timestamp
        self.clearAfter = clearAfter
    }

    /// Upper bound for attention text, in `Character` (grapheme cluster)
    /// count. The sidebar capsule is sized for short status pings;
    /// piping `git log` etc. into `espalier notify` blows up layout and
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
        // Match the CLI's ATTN-1.12 guard (widened in cycle 108 from
        // just LF/CR to the full Unicode Cc category) so a raw socket
        // client (`nc -U`, web surface, custom script) can't bypass
        // validation and send text with ANSI escapes, tabs, bells, etc.
        // that the sidebar would render as garbled literal glyphs.
        if text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) { return false }
        // Match CLI's ATTN-1.13 guard: text entirely made of format
        // (Cf) + whitespace scalars renders as invisible. Swift's trim
        // strips ZWSP but not BOM, so this backstop catches the rest.
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
