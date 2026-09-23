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
        let lines = withoutTranscriptChrome(text).components(separatedBy: "\n")
        guard lines.count > 1 else { return text }

        // The pane may have grown since these rows were drawn. Use the
        // longest selected row as a lower estimate of its former width.
        let observedWidth = lines.map(\.count).max() ?? columns
        let wrapWidth = min(columns, max(min(columns, 40), observedWidth))
        var result = lines[0]
        var previous = lines[0]
        var previousWasJoined = false
        for line in lines.dropFirst() {
            let indentation = line.prefix(while: { $0 == " " }).count
            let continuation = line.trimmingCharacters(in: .whitespaces)
            let previousContent = previous.trimmingCharacters(in: .whitespaces)
            let previousIndentation = previous.prefix(while: { $0 == " " }).count
            let nextWordWidth = continuation.prefix(while: { !$0.isWhitespace }).count
            let joinsWrappedLine = columns > 0
                && indentation >= 2
                && !previousContent.isEmpty
                && !continuation.isEmpty
                && !isListItem(continuation)
                && numberedDiagnostic(in: continuation) == nil
                && !previousContent.hasSuffix(":")
                && (previousIndentation < 4 || previousWasJoined || numberedDiagnostic(in: previousContent) != nil)
                && previous.count + 1 + nextWordWidth > wrapWidth
            if joinsWrappedLine {
                while result.last == " " { result.removeLast() }
                result += " " + continuation
            } else {
                result += "\n" + line
            }
            previousWasJoined = joinsWrappedLine
            previous = line
        }
        return result
    }

    private static func withoutTranscriptChrome(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        while lines.last == "" { lines.removeLast() }
        guard let hint = lines.last, isTranscriptExpansionHint(hint) else { return text }
        lines.removeLast()
        return lines.map { line in
            numberedDiagnostic(in: line.trimmingCharacters(in: .whitespaces)) ?? line
        }.joined(separator: "\n")
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
        if line.hasPrefix("• ") || line.hasPrefix("- ") || line.hasPrefix("* ") { return true }
        guard let marker = line.firstIndex(where: { $0 == "." || $0 == ")" }),
              marker != line.startIndex,
              line[..<marker].allSatisfy(\.isNumber) else { return false }
        let afterMarker = line.index(after: marker)
        return afterMarker < line.endIndex && line[afterMarker] == " "
    }
}
