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
public enum NotifyInputValidation: Equatable {
    case valid
    case missingTextAndClear
    case bothTextAndClear
    case emptyText
    case clearAfterTooLarge(max: Int)
    case clearAfterWithClearFlag
    case textTooLong(max: Int)
    case controlCharactersInText
    case bidiControlInText

    /// Upper bound for notify text. Proxies to `Attention.textMaxLength`
    /// so the CLI's ATTN-1.10 check and the server's STATE-2.10 backstop
    /// share one source of truth — changing the cap is one edit in
    /// `Attention.swift`.
    public static var textMaxLength: Int { Attention.textMaxLength }

    /// Upper bound for `--clear-after`, in seconds. 24h covers any
    /// plausible "ping me after this long build finishes" case without
    /// allowing ridiculous values (`--clear-after 999999999`) that
    /// would park a Dispatch timer on the main queue for decades and
    /// leak per-session scheduler state.
    public static let clearAfterMaxSeconds = 86_400

    public static func validate(
        text: String?,
        clear: Bool,
        clearAfter: Int? = nil
    ) -> NotifyInputValidation {
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
            // Swift's whitespace trim strips some Cf scalars (ZWSP
            // U+200B) but not others (BOM U+FEFF). Without this extra
            // check, `\u{FEFF}` or `\u{200B}\u{FEFF}` passes validation
            // and renders as a zero-width / invisible badge — same UX
            // as an empty string. Reject when every scalar is either
            // whitespace or Unicode Format-category (Cf).
            if text!.unicodeScalars.allSatisfy({
                $0.properties.isWhitespace || $0.properties.generalCategory == .format
            }) {
                return .emptyText
            }
            if text!.count > textMaxLength {
                return .textTooLong(max: textMaxLength)
            }
            // ATTN-1.12: the sidebar capsule renders `Text` with
            // `.lineLimit(1)`, so any control character (LF/CR clip the
            // render, TAB renders as ?-width, ESC-based ANSI codes land
            // as literal `[31m` glyphs in SwiftUI Text). Reject the
            // whole Unicode Cc general category so the user gets clear
            // feedback instead of a truncated or garbled badge.
            if text!.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
                return .controlCharactersInText
            }
            // ATTN-1.14: reject BIDI-override scalars even when mixed
            // with visible content. They're Unicode Cf (not Cc) so the
            // check above doesn't catch them, and the all-Cf-invisible
            // check above that only rejects when EVERY scalar is Cf.
            // Mixed `\u{202E}evil` renders RTL-reversed — "Trojan
            // Source"-style visual deception (CVE-2021-42574).
            if text!.unicodeScalars.contains(where: Self.isBidiOverride) {
                return .bidiControlInText
            }
            // Negative / zero clearAfter is handled server-side per
            // STATE-2.8 (treated as no auto-clear). Only the upper
            // bound is a CLI-side rejection — the user probably typed
            // a wrong unit (milliseconds → seconds etc.) and deserves
            // feedback, not a silent multi-year timer.
            if let clearAfter, clearAfter > clearAfterMaxSeconds {
                return .clearAfterTooLarge(max: clearAfterMaxSeconds)
            }
            return .valid
        case (false, true):
            // `--clear-after` only applies to notify messages. A user
            // writing both is ambiguous (schedule-a-clear? clear now?);
            // the server-side `.clear` path ignores clearAfter, so
            // before this check the CLI silently dropped it. Reject
            // rather than guess.
            if clearAfter != nil {
                return .clearAfterWithClearFlag
            }
            return .valid
        }
    }

    /// Human-facing message surfaced via `Error` in the CLI.
    public var message: String? {
        switch self {
        case .valid: return nil
        case .missingTextAndClear: return "Provide notification text or use --clear"
        case .bothTextAndClear: return "Cannot combine notification text with --clear; use one or the other"
        case .emptyText: return "Notification text cannot be empty or whitespace-only"
        case .clearAfterTooLarge(let max):
            return "--clear-after exceeds the \(max)-second (\(max / 3600)-hour) limit"
        case .clearAfterWithClearFlag:
            return "Cannot use --clear-after with --clear; --clear-after applies only to notify messages"
        case .textTooLong(let max):
            return "Notification text exceeds the \(max)-character limit"
        case .controlCharactersInText:
            return "Notification text cannot contain control characters (newlines, tabs, ANSI escapes, or other non-printable characters)"
        case .bidiControlInText:
            return "Notification text cannot contain bidirectional-override characters (U+202A-U+202E, U+2066-U+2069) — they visually reverse the text in the sidebar"
        }
    }

    /// The Unicode scalars that change the display direction of
    /// surrounding text: the "embedding" family (U+202A-U+202C), the
    /// "override" family (U+202D-U+202E, the Trojan-Source flavor),
    /// and the "isolate" family (U+2066-U+2069) Unicode 6.3+ uses as
    /// the modern replacement. All are Format-category so they slip
    /// past both the Cc-control gate and the all-invisible gate when
    /// mixed with visible content.
    static func isBidiOverride(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x202A...0x202E, 0x2066...0x2069: return true
        default: return false
        }
    }

    /// Drop every BIDI-override scalar from the input. Used at the
    /// PR-title intake boundary (`PR-5.5`) where the author is
    /// explicitly not trusted and rejecting the whole PR would hide
    /// a legit PR behind a single poisoned title. Rejection (the
    /// self-owned-surface policy at `ATTN-1.14` and `LAYOUT-2.18`)
    /// assumes the text has an owner who can fix it; for external
    /// data, stripping degrades the display gracefully.
    public static func strippingBidiOverrides(_ s: String) -> String {
        let safe = s.unicodeScalars.filter { !isBidiOverride($0) }
        return String(String.UnicodeScalarView(safe))
    }
}
