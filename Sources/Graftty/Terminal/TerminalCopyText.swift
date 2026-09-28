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
        let columns = Int(ghostty_surface_size(surface).columns)
        // Ghostty flattens viewport cells as row * columns + column.
        // An offscreen selection start falls back to offset zero.
        let startColumn = columns > 0 ? Int(selection.offset_start) % columns : 0
        return clean(text, columns: columns, startColumn: startColumn)
    }

    static func clean(_ text: String, columns: Int, startColumn: Int = 0) -> String {
        if let codeSelection = cleanCodeLineNumberGutter(text) { return codeSelection }
        let withoutChrome = withoutTranscriptChrome(text)
        let lines = withoutChrome.components(separatedBy: "\n")
        guard lines.count > 1 else { return withoutChrome }

        var result = lines[0]
        var previous = lines[0]
        var previousWasJoined = false
        var previousStartColumn = startColumn
        for line in lines.dropFirst() {
            let indentation = line.prefix(while: { $0 == " " }).count
            let continuation = line.trimmingCharacters(in: .whitespaces)
            let previousContent = previous.trimmingCharacters(in: .whitespaces)
            let previousIndentation = previous.prefix(while: { $0 == " " }).count
            let nextWordWidth = cellWidth(continuation.prefix(while: { !$0.isWhitespace }))
            let diagnosticContinuation = previousWasJoined || numberedDiagnostic(in: previousContent) != nil
            let joinsWrappedLine = columns > 0
                && indentation >= 2
                && !previousContent.isEmpty
                && !continuation.isEmpty
                && !isListItem(continuation)
                && !continuation.hasPrefix(".")
                && numberedDiagnostic(in: continuation) == nil
                && !previousContent.hasSuffix(":")
                && (diagnosticContinuation || (!isStructuredLine(previousContent) && !isStructuredLine(continuation)))
                && (previousIndentation < 4 || previousWasJoined || numberedDiagnostic(in: previousContent) != nil)
                && previousStartColumn + cellWidth(previous) + 1 + nextWordWidth > columns
            if joinsWrappedLine {
                while result.last == " " { result.removeLast() }
                result += " " + continuation
            } else {
                result += "\n" + line
            }
            previousWasJoined = joinsWrappedLine
            previous = line
            // Only the first copied row can omit cells before the selection.
            previousStartColumn = 0
        }
        return result
    }

    private struct NumberedCodeRow {
        let number: Int
        let gutterIndent: Int
        let spacingAfterNumber: Int
        let content: String

        var hasDiffMarker: Bool { content.hasPrefix("+") || content.hasPrefix("-") }
    }

    /// A linear selection begun inside the code column includes the full
    /// number gutter on later rows. Require repeated, ordered code rows so
    /// ordinary numbered output keeps its original text.
    private static func cleanCodeLineNumberGutter(_ text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        let numbered = lines.enumerated().compactMap { index, line in
            numberedCodeRow(line).map { (index, $0) }
        }
        guard numbered.count >= 2,
              numbered.indices.dropFirst().allSatisfy({ numbered[$0].1.number >= numbered[$0 - 1].1.number }) else {
            return nil
        }
        let hasDiff = numbered.contains(where: { $0.1.hasDiffMarker })
        let plainCodeGutter = numbered.allSatisfy { $0.1.content.isEmpty || $0.1.spacingAfterNumber >= 2 }
            && numbered.indices.dropFirst().allSatisfy({ numbered[$0].1.number == numbered[$0 - 1].1.number + 1 })
        guard hasDiff || plainCodeGutter else { return nil }
        // A selection that begins in the gutter intentionally includes the
        // numbers, including those on later lines.
        if numbered[0].0 == 0 { return text }
        let firstLooksLikeCode = isStrongCodeLine(lines[0]) || (
            isStructuredLine(lines[0]) && numbered.contains { _, row in
                let code = row.hasDiffMarker ? String(row.content.dropFirst()) : row.content
                return isStrongCodeLine(code)
            }
        )
        guard numbered[0].0 == 1,
              firstLooksLikeCode,
              numbered.allSatisfy({ $0.1.gutterIndent == numbered[0].1.gutterIndent }) else {
            return nil
        }
        return lines.enumerated().map { index, line in
            index == 0 ? line : (numberedCodeRow(line)?.content ?? line)
        }.joined(separator: "\n")
    }

    private static func numberedCodeRow(_ line: String) -> NumberedCodeRow? {
        let indent = line.prefix(while: { $0 == " " }).count
        let row = line.dropFirst(indent)
        let digits = row.prefix(while: { ("0"..."9").contains($0) })
        guard !digits.isEmpty, digits.count <= 7, let number = Int(digits) else { return nil }
        let rest = row.dropFirst(digits.count)
        let spaces = rest.prefix(while: { $0 == " " }).count
        guard rest.isEmpty || spaces > 0 else { return nil }
        return NumberedCodeRow(
            number: number, gutterIndent: indent, spacingAfterNumber: spaces,
            content: rest.isEmpty ? "" : String(rest.dropFirst())
        )
    }

    private static func isStructuredLine(_ line: String) -> Bool {
        let content = line.trimmingCharacters(in: .whitespaces)
        if content.hasPrefix("at ") && content.contains(":") { return true }
        return isStrongCodeLine(content) || content.contains("(") || content.contains("{")
    }

    private static func isStrongCodeLine(_ line: String) -> Bool {
        let content = line.trimmingCharacters(in: .whitespaces)
        if content.hasPrefix("@") || content.hasPrefix("#") { return true }
        let keywords = ["let ", "var ", "func ", "return ", "throw ", "if ", "guard ",
                        "class ", "struct ", "enum ", "import "]
        if keywords.contains(where: content.hasPrefix) { return true }
        return content.contains(" = ") || content.contains("{") || content.contains("}")
    }

    private static func withoutTranscriptChrome(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        while lines.last == "" { lines.removeLast() }
        guard let hint = lines.last, isTranscriptExpansionHint(hint),
              let first = lines.first?.trimmingCharacters(in: .whitespaces),
              hasTranscriptMarker(first), numberedDiagnostic(in: first) != nil else { return text }
        lines.removeLast()
        return lines.map { line in
            numberedDiagnostic(in: line.trimmingCharacters(in: .whitespaces)) ?? line
        }.joined(separator: "\n")
    }

    private static func numberedDiagnostic(in content: String) -> String? {
        let entry = hasTranscriptMarker(content) ? String(content.dropFirst(2)) : content
        guard let colon = entry.firstIndex(of: ":"), colon != entry.startIndex,
              entry[..<colon].allSatisfy(\.isNumber) else { return nil }
        return entry
    }

    private static func hasTranscriptMarker(_ content: String) -> Bool {
        content.hasPrefix("└ ") || content.hasPrefix("⎿ ")
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
