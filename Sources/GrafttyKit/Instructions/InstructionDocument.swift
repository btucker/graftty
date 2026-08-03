import Foundation

/// One parsed `.graftty/` instruction file.
///
/// @spec INSTR-4.1
/// The first heading whose text is exactly `Private` (case-insensitive)
/// splits the file. Text above is shared with every agent in the repo; text
/// below reaches only the worktrees the file applies to. A file with no such
/// heading is entirely shared — the failure mode is a longer prompt, which is
/// easy to notice, rather than instructions that silently never appear.
public struct InstructionDocument: Equatable, Sendable {
    public let shared: String
    public let privateText: String

    public init(shared: String, privateText: String) {
        self.shared = shared
        self.privateText = privateText
    }

    public static func parse(_ raw: String) -> InstructionDocument {
        let lines = raw.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() where isPrivateMarker(line) {
            return InstructionDocument(
                shared: trimmed(lines[..<index].joined(separator: "\n")),
                privateText: trimmed(lines[(index + 1)...].joined(separator: "\n"))
            )
        }
        return InstructionDocument(shared: trimmed(raw), privateText: "")
    }

    /// A marker is 1–6 leading `#`, whitespace, then exactly `private`.
    /// Requiring the whitespace keeps `#Private` (a valid word, not a
    /// heading in CommonMark) out of the match.
    static func isPrivateMarker(_ line: String) -> Bool {
        let line = line.trimmingCharacters(in: .whitespaces)
        let hashes = line.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return false }
        let rest = line.dropFirst(hashes.count)
        guard let first = rest.first, first.isWhitespace else { return false }
        return rest.trimmingCharacters(in: .whitespaces).lowercased() == "private"
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
