import Foundation

/// `ATTN-1.20`: tail a scrollback dump to the last `lines` lines.
/// Non-positive `lines` and oversize `lines` both clamp to "everything".
public enum ScrollbackTail {
    public static func tail(_ body: String, lines: Int) -> String {
        guard !body.isEmpty else { return body }
        guard lines > 0 else { return body }

        let trailingNewline = body.hasSuffix("\n")
        let trimmed = trailingNewline ? String(body.dropLast()) : body
        let parts = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines < parts.count else { return body }

        let kept = parts.suffix(lines).joined(separator: "\n")
        return trailingNewline ? kept + "\n" : kept
    }
}
