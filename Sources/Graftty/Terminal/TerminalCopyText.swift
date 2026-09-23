import Foundation
import GhosttyKit

/// Removes line breaks added by agent TUIs when they draw prose into the
/// terminal grid. Only run this on a confirmed selection copy; OSC 52 and
/// other programmatic clipboard writes must keep their original bytes.
enum TerminalCopyText {
    static func cleanSelectionCopy(_ text: String, surface: ghostty_surface_t) -> String {
        var selection = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &selection) else { return text }
        defer { ghostty_surface_free_text(surface, &selection) }
        guard let pointer = selection.text,
              selection.text_len == text.utf8.count,
              selection.text_len <= 1_048_576 else { return text }
        let bytes = UnsafeBufferPointer(
            start: UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self),
            count: Int(selection.text_len)
        )
        guard String(decoding: bytes, as: UTF8.self) == text else { return text }
        return clean(text, columns: Int(ghostty_surface_size(surface).columns))
    }

    static func clean(_ text: String, columns: Int) -> String {
        let lines = text.components(separatedBy: "\n")
        guard lines.count > 1 else { return text }

        var result = lines[0]
        var previous = lines[0]
        for line in lines.dropFirst() {
            let startsWithTwoSpaces = line.hasPrefix("  ") && !line.hasPrefix("   ")
            let continuation = String(line.dropFirst(startsWithTwoSpaces ? 2 : 0))
            let joinsWrappedProse = startsWithTwoSpaces
                && columns > 0
                && previous.count >= max(15, columns - 16)
                && looksLikeProse(previous)
                && looksLikeProse(continuation)
                && !isListItem(continuation)
            if joinsWrappedProse {
                while result.last == " " { result.removeLast() }
                result += " " + continuation
            } else {
                result += "\n" + line
            }
            previous = line
        }
        return result
    }

    private static func isListItem(_ line: String) -> Bool {
        line.hasPrefix("• ") || line.hasPrefix("- ") || line.hasPrefix("* ")
    }

    private static func looksLikeProse(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains(" "),
              trimmed.count >= 12,
              !trimmed.hasPrefix("```") else { return false }
        return true
    }
}
