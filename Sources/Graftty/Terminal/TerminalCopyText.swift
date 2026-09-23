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
        if let transcript = cleanTranscriptDiagnostics(text) { return transcript }
        let lines = text.components(separatedBy: "\n")
        guard lines.count > 1 else { return text }

        var result = lines[0]
        var previous = lines[0]
        for line in lines.dropFirst() {
            let startsWithTwoSpaces = line.hasPrefix("  ") && !line.hasPrefix("   ")
            let continuation = String(line.dropFirst(startsWithTwoSpaces ? 2 : 0))
            let joinsWrappedProse = startsWithTwoSpaces
                && columns > 0
                // A copied line may have been drawn before the pane was widened.
                && previous.count >= max(15, min(70, columns - 16))
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

    private static func cleanTranscriptDiagnostics(_ text: String) -> String? {
        var lines = text.components(separatedBy: "\n")
        while lines.last == "" { lines.removeLast() }
        guard let hint = lines.last, isTranscriptExpansionHint(hint) else { return nil }

        var entries: [String] = []
        for line in lines.dropLast() {
            let content = line.trimmingCharacters(in: .whitespaces)
            if let entry = numberedDiagnostic(in: content) {
                entries.append(entry)
            } else if !content.isEmpty, !entries.isEmpty {
                entries[entries.count - 1] += " " + content
            } else {
                return nil
            }
        }
        return entries.count >= 2 ? entries.joined(separator: "\n") : nil
    }

    private static func numberedDiagnostic(in content: String) -> String? {
        let entry = content.hasPrefix("└ ") ? String(content.dropFirst(2)) : content
        guard let colon = entry.firstIndex(of: ":"), colon != entry.startIndex,
              entry[..<colon].allSatisfy(\.isNumber) else { return nil }
        return entry
    }

    private static func isTranscriptExpansionHint(_ line: String) -> Bool {
        let content = line.trimmingCharacters(in: .whitespaces)
        let suffix = " lines (ctrl+t to view transcript)"
        guard content.hasPrefix("+"), content.hasSuffix(suffix) else { return false }
        let count = content.dropFirst().dropLast(suffix.count)
        return !count.isEmpty && count.allSatisfy(\.isNumber)
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
