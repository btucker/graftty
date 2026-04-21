import Foundation

/// Unicode scalars that change the display direction of surrounding text:
/// the "embedding" family (U+202A-U+202C), the "override" family
/// (U+202D-U+202E, the Trojan-Source flavor), and the "isolate" family
/// (U+2066-U+2069) used by Unicode 6.3+ as the modern replacement.
/// All are Format-category so they slip past both Cc-control gates and
/// all-invisible gates when mixed with visible content
/// (CVE-2021-42574).
public enum BidiOverrides {
    public static func contains(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x202A...0x202E, 0x2066...0x2069: return true
        default: return false
        }
    }

    public static func containsAny(_ s: String) -> Bool {
        s.unicodeScalars.contains(where: contains)
    }

    /// Drop every BIDI-override scalar from the input. Used at intake
    /// boundaries where the source is explicitly not trusted and
    /// rejecting the whole value would hide legitimate content behind a
    /// single poisoned scalar (e.g. PR titles at `PR-5.5`). Rejection
    /// is the self-owned-surface policy (`ATTN-1.14`, `LAYOUT-2.18`);
    /// stripping is for external data.
    public static func stripping(_ s: String) -> String {
        let safe = s.unicodeScalars.filter { !contains($0) }
        return String(String.UnicodeScalarView(safe))
    }
}
