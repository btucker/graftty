import GhosttyKit
import GrafttyCommandUI
import GrafttyProtocol

/// Native scrollback access for the timeline's jump to terminal and the scrollback map.
@MainActor
extension SurfaceHandle: TerminalScrollback {
    /// One read per physical row: a multi-row read joins soft-wrapped rows, which
    /// would shift every later row index.
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
        let columns = ghostty_surface_size(surface).columns
        guard total > 0, columns > 0 else { return nil }
        let first = max(0, total - max(0, limit))
        let rows = (first..<total).map { Self.screenRow(surface, y: UInt32(clamping: $0), columns: UInt32(columns)) }
        return ScrollbackRows(rows: rows, firstRow: first, totalRows: total)
    }

    static func scroll(_ surface: ghostty_surface_t, toRow row: Int) {
        let action = "scroll_to_row:\(max(0, row))"
        _ = action.withCString { ghostty_surface_binding_action(surface, $0, UInt(action.utf8.count)) }
    }

    private static func screenRow(_ surface: ghostty_surface_t, y: UInt32, columns: UInt32) -> String {
        let selection = ghostty_selection_s(
            top_left: .init(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: y),
            bottom_right: .init(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_EXACT, x: columns - 1, y: y),
            rectangle: false)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let bytes = text.text else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: bytes, count: Int(text.text_len)), as: UTF8.self)
    }
}
