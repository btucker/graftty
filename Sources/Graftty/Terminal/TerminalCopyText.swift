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
        let withoutChrome = withoutTranscriptChrome(text)
        let lines = withoutChrome.components(separatedBy: "\n")
        guard lines.count > 1 else { return withoutChrome }

        var result = lines[0]
        var previous = lines[0]
        var previousWasJoined = false
        for line in lines.dropFirst() {
            let indentation = line.prefix(while: { $0 == " " }).count
            let continuation = line.trimmingCharacters(in: .whitespaces)
            let previousContent = previous.trimmingCharacters(in: .whitespaces)
            let previousIndentation = previous.prefix(while: { $0 == " " }).count
            let nextWordWidth = cellWidth(continuation.prefix(while: { !$0.isWhitespace }))
            let joinsWrappedLine = columns > 0
                && indentation >= 2
                && !previousContent.isEmpty
                && !continuation.isEmpty
                && !isListItem(continuation)
                && !continuation.hasPrefix(".")
                && numberedDiagnostic(in: continuation) == nil
                && !previousContent.hasSuffix(":")
                && (previousIndentation < 4 || previousWasJoined || numberedDiagnostic(in: previousContent) != nil)
                && cellWidth(previous) + 1 + nextWordWidth > columns
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
        guard let hint = lines.last, isTranscriptExpansionHint(hint),
              let first = lines.first?.trimmingCharacters(in: .whitespaces),
              first.hasPrefix("└ "), numberedDiagnostic(in: first) != nil else { return text }
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

    /// Approximate the cells used by a grapheme on Ghostty's grid. Keeping
    /// joined emoji to two cells also covers zero-width-joiner sequences.
    private static func cellWidth(_ text: some StringProtocol) -> Int {
        text.reduce(0) { total, character in
            let scalarWidth = character.unicodeScalars.reduce(0) { width, scalar in
                let value = scalar.value
                if scalar.properties.generalCategory == .nonspacingMark
                    || scalar.properties.generalCategory == .enclosingMark
                    || value == 0x200D { return width }
                let wide = scalar.properties.isEmojiPresentation
                    || (0x1100...0x115F).contains(value)
                    || (0x2329...0x232A).contains(value)
                    || (0x2E80...0xA4CF).contains(value)
                    || (0xAC00...0xD7A3).contains(value)
                    || (0xF900...0xFAFF).contains(value)
                    || (0xFE10...0xFE6F).contains(value)
                    || (0xFF00...0xFF60).contains(value)
                    || (0xFFE0...0xFFE6).contains(value)
                    || (0x20000...0x3FFFD).contains(value)
                return width + (wide ? 2 : 1)
            }
            return total + min(2, max(1, scalarWidth))
        }
    }
}
