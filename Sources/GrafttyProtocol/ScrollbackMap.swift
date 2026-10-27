import Foundation

/// @spec CONTEXT-30
/// Where timeline messages appear in an agent terminal's scrollback: one mark per located
/// human input or peer message, by absolute screen row (0 is the oldest row, as `scroll_to_row`
/// counts), plus the scrollback's total row count.
public struct ScrollbackMap: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case input, peer }

    /// A timeline message to look for, in chronological order.
    public struct Message: Sendable, Equatable {
        public let eventID: String
        public let kind: Kind
        public let text: String
        public init(eventID: String, kind: Kind, text: String) {
            self.eventID = eventID; self.kind = kind; self.text = text
        }
    }

    public struct Mark: Sendable, Equatable, Identifiable {
        public var id: String { eventID }
        public let row: Int
        public let kind: Kind
        public let eventID: String
        public init(row: Int, kind: Kind, eventID: String) {
            self.row = row; self.kind = kind; self.eventID = eventID
        }
    }

    public let totalRows: Int
    /// Ascending by row, which is also chronological order.
    public let marks: [Mark]

    public init(totalRows: Int, marks: [Mark]) {
        self.totalRows = totalRows
        self.marks = marks.sorted { $0.row < $1.row }
    }

    public func row(for eventID: String) -> Int? {
        marks.first { $0.eventID == eventID }?.row
    }

    /// The mark closest to `row`, for a scrubber's live label.
    public func nearestMark(toRow row: Int) -> Mark? {
        marks.min { abs($0.row - row) < abs($1.row - row) }
    }

    /// The human input and peer messages of a timeline, oldest first.
    public static func messages(in timeline: WorktreeTimeline) -> [Message] {
        timeline.events.compactMap { event in
            switch event.kind {
            case .user: Message(eventID: event.id, kind: .input, text: event.completed)
            case .agentMessage: Message(eventID: event.id, kind: .peer, text: event.completed)
            case .creation, .checkpoint: nil
            }
        }
    }

    /// Needles longer than this are cut so one stays well inside a terminal row.
    static let needleLength = 32
    /// Shorter needles are not distinctive, so they must fill a whole row.
    static let distinctiveLength = 12

    /// Locates `messages` in `rows`, where `rows[0]` is absolute row `firstRow`.
    ///
    /// Searching backward from the newest message picks each message's latest
    /// occurrence below the next message's row. A resize redraw repeats the
    /// transcript, so this lands every message in the newest complete copy, and the
    /// rows stay in chronological order.
    public static func locate(_ messages: [Message], rows: [String], firstRow: Int = 0, totalRows: Int? = nil) -> ScrollbackMap {
        var text: [UInt8] = []
        var rowStarts: [Int] = []
        var canonicalRows: [[UInt8]] = []
        for row in rows {
            let canonical = Array(canonicalize(row).utf8)
            rowStarts.append(text.count)
            canonicalRows.append(canonical)
            text += canonical
        }
        var marks: [Mark] = []
        var limit = rows.count  // Rows at or after this index belong to later messages.
        for message in messages.reversed() {
            guard let needle = needle(for: message.text) else { continue }
            let found: Int?
            if needle.count < distinctiveLength {
                found = (0..<limit).last { canonicalRows[$0] == needle }
            } else {
                found = lastMatch(of: needle, in: text, before: limit < rowStarts.count ? rowStarts[limit] : text.count)
                    .map { offset in row(containing: offset, rowStarts: rowStarts) }
            }
            guard let index = found else { continue }
            marks.append(Mark(row: firstRow + index, kind: message.kind, eventID: message.eventID))
            limit = index
        }
        return ScrollbackMap(totalRows: totalRows ?? firstRow + rows.count, marks: marks)
    }

    static func needle(for text: String) -> [UInt8]? {
        let line = text.split(whereSeparator: \.isNewline).lazy.map { canonicalize(String($0)) }.first { !$0.isEmpty }
        guard let line else { return nil }
        return Array(String(line.prefix(needleLength)).utf8)
    }

    private static let leadingGlyphs: Set<Character> = [">", "›", "❯", "»", "│", "┃", "▌", "⏺", "●", "⎿"]
    private static let trailingGlyphs: Set<Character> = ["│", "┃"]

    /// Strips prompt and border glyphs at either end, then removes all whitespace so
    /// soft wraps, word wraps, and indentation compare equal.
    static func canonicalize(_ row: String) -> String {
        var characters = Substring(row)
        while let first = characters.first, first.isWhitespace || leadingGlyphs.contains(first) { characters.removeFirst() }
        while let last = characters.last, last.isWhitespace || trailingGlyphs.contains(last) { characters.removeLast() }
        return String(characters.filter { !$0.isWhitespace })
    }

    /// The last row starting at or before `offset`. Empty rows share the next row's
    /// start, so this is the non-empty row that holds the offset.
    private static func row(containing offset: Int, rowStarts: [Int]) -> Int {
        var low = 0, high = rowStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if rowStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// The start offset of the last occurrence of `needle` that starts before `end`.
    private static func lastMatch(of needle: [UInt8], in text: [UInt8], before end: Int) -> Int? {
        guard !needle.isEmpty, text.count >= needle.count else { return nil }
        var start = min(end - 1, text.count - needle.count)
        while start >= 0 {
            if text[start] == needle[0], text[start..<(start + needle.count)].elementsEqual(needle) { return start }
            start -= 1
        }
        return nil
    }
}

/// Text rows read from the tail of a terminal's scrollback, by absolute screen row.
public struct ScrollbackRows: Sendable, Equatable {
    /// One string per physical row; soft-wrapped continuations stay separate.
    public let rows: [String]
    /// The absolute row of `rows[0]`; nonzero when older rows were not read.
    public let firstRow: Int
    public let totalRows: Int
    public init(rows: [String], firstRow: Int, totalRows: Int) {
        self.rows = rows; self.firstRow = firstRow; self.totalRows = totalRows
    }
}

extension ScrollbackMap {
    /// The most rows an adapter reads, newest first, so a long session stays cheap to scan.
    public static let readLimit = 20_000

    public static func locate(_ messages: [Message], in snapshot: ScrollbackRows) -> ScrollbackMap {
        locate(messages, rows: snapshot.rows, firstRow: snapshot.firstRow, totalRows: snapshot.totalRows)
    }
}
