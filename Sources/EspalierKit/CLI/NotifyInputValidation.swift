import Foundation

/// Pure validation for the arguments `espalier notify` accepts. Lives in
/// EspalierKit so it's reachable from EspalierKitTests — the CLI target
/// imports it and plumbs a failing result into `ValidationError`.
///
/// Rules:
/// - Exactly one of (text, `--clear`) must be provided. Neither is a
///   usage error; both is a conflict (the CLI previously accepted the
///   combination silently, dropping the text and acting as a bare
///   `--clear`, which masks typos like `espalier notify "done" --clear`
///   where Andy meant just `notify "done"` but had stale shell history).
public enum NotifyInputValidation {
    case valid
    case missingTextAndClear
    case bothTextAndClear
    case emptyText

    public static func validate(text: String?, clear: Bool) -> NotifyInputValidation {
        let hasText = text != nil
        // The clear-conflict check runs first: when the user passes both
        // a text and `--clear`, the ambiguity is what matters to surface
        // (they clearly typed something; flag that, not the shape of
        // what they typed). Empty-text is only interesting when it
        // stands alone.
        switch (hasText, clear) {
        case (false, false): return .missingTextAndClear
        case (true, true): return .bothTextAndClear
        case (true, false):
            if text!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .emptyText
            }
            return .valid
        case (false, true): return .valid
        }
    }

    /// Human-facing message surfaced via `Error` in the CLI.
    public var message: String? {
        switch self {
        case .valid: return nil
        case .missingTextAndClear: return "Provide notification text or use --clear"
        case .bothTextAndClear: return "Cannot combine notification text with --clear; use one or the other"
        case .emptyText: return "Notification text cannot be empty or whitespace-only"
        }
    }
}
