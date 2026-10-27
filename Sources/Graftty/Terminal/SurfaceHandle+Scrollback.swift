import GhosttyKit
import GrafttyCommandUI
import GrafttyProtocol

/// Native scrollback access for the timeline's jump to terminal and the scrollback map.
@MainActor
extension SurfaceHandle: TerminalScrollback {
    /// One row per physical row: a multi-row text read joins soft-wrapped rows,
    /// which would shift every later row index.
    func scrollbackRows(limit: Int) -> ScrollbackRows? {
        Self.scrollbackRows(surface, total: Int(followerScrollbar.total), limit: limit)
    }

    func firstRowText() -> String? {
        let columns = ghostty_surface_size(surface).columns
        guard followerScrollbar.total > 0, columns > 0 else { return nil }
        return Self.screenRow(surface, y: 0, columns: UInt32(columns))
    }

    func scroll(toRow row: Int) {
        if followerPresentation?.reveal(row: UInt64(max(0, row))) == true { return }
        Self.scroll(surface, toRow: row)
    }

    static func scrollbackRows(_ surface: ghostty_surface_t, total: Int, limit: Int) -> ScrollbackRows? {
        let size = ghostty_surface_size(surface)
        let columns = UInt32(size.columns)
        guard total > 0, columns > 0 else { return nil }
        let first = max(0, total - max(0, limit))
        #if GRAFTTY_PAGED_HISTORY
        // This renderer clamps every exact point to the active area's height, so a
        // SCREEN row below it reads the active area's last row. Rows above the
        // active area come from history; the active area is read by ACTIVE row.
        let activeStart = max(0, total - Int(size.rows))
        let historyEnd = max(first, activeStart)
        let rows = historyRows(surface, from: first, to: historyEnd) + (historyEnd..<total).map {
            Self.row(surface, tag: GHOSTTY_POINT_ACTIVE, y: UInt32(clamping: $0 - activeStart), columns: columns)
        }
        #else
        let rows = (first..<total).map { Self.screenRow(surface, y: UInt32(clamping: $0), columns: columns) }
        #endif
        return ScrollbackRows(rows: rows, firstRow: first, totalRows: total)
    }

    static func scroll(_ surface: ghostty_surface_t, toRow row: Int) {
        let action = "scroll_to_row:\(max(0, row))"
        _ = action.withCString { ghostty_surface_binding_action(surface, $0, UInt(action.utf8.count)) }
    }

    private static func screenRow(_ surface: ghostty_surface_t, y: UInt32, columns: UInt32) -> String {
        row(surface, tag: GHOSTTY_POINT_SCREEN, y: y, columns: columns)
    }

    private static func row(_ surface: ghostty_surface_t, tag: ghostty_point_tag_e, y: UInt32, columns: UInt32) -> String {
        let selection = ghostty_selection_s(
            top_left: .init(tag: tag, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: y),
            bottom_right: .init(tag: tag, coord: GHOSTTY_POINT_COORD_EXACT, x: columns - 1, y: y),
            rectangle: false)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let bytes = text.text else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: bytes, count: Int(text.text_len)), as: UTF8.self)
    }

    #if GRAFTTY_PAGED_HISTORY
    /// Plain text of history rows `start..<end`, one per physical row, read in the
    /// bounded chunks `ghostty_surface_read_history` returns, newest chunk first.
    private static func historyRows(_ surface: ghostty_surface_t, from start: Int, to end: Int) -> [String] {
        var chunks: [[String]] = []
        var before = end
        while before > start {
            var text = ghostty_text_s()
            guard ghostty_surface_read_history(surface, UInt64(before), UInt32(clamping: before - start), &text) else { break }
            defer { ghostty_surface_free_text(surface, &text) }
            let count = min(Int(text.offset_len), before - start)
            guard count > 0 else { break }
            let bytes = text.text.map { UnsafeRawBufferPointer(start: $0, count: Int(text.text_len)) }
            chunks.append(plainRows(bytes.map { String(decoding: $0, as: UTF8.self) } ?? "", count: count))
            before -= count
        }
        // A failed read leaves the oldest rows blank rather than shifting later rows.
        return Array(repeating: "", count: before - start) + chunks.reversed().joined()
    }

    /// The history formatter emits VT: strips its escape sequences and splits rows,
    /// restoring the trailing blank rows it omits.
    private static func plainRows(_ vt: String, count: Int) -> [String] {
        var plain = ""
        var scalars = vt.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            guard scalar == "\u{1B}" else { plain.unicodeScalars.append(scalar); continue }
            switch scalars.next() {
            case "["?:
                while let next = scalars.next(), !(0x40...0x7E).contains(next.value) {}
            case "]"?, "P"?, "_"?, "^"?, "X"?:
                // String sequences end at BEL or ST (ESC \).
                while let next = scalars.next(), next != "\u{07}" {
                    if next == "\u{1B}" { _ = scalars.next(); break }
                }
            default:
                break
            }
        }
        let rows = plain.split(separator: "\r\n", omittingEmptySubsequences: false).prefix(count).map(String.init)
        return rows + Array(repeating: "", count: count - rows.count)
    }
    #endif
}
