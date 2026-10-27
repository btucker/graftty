#if canImport(UIKit)
import GhosttyTerminal
import GrafttyCommandUI
import GrafttyProtocol
import UIKit

/// The published terminal package reads only viewport rows, so this pages the native
/// viewport through the loaded scrollback in one main-actor turn and restores it.
extension TerminalInputContainerView: TerminalScrollback {
    public func scrollbackRows(limit: Int) -> ScrollbackRows? {
        guard let session = scrollbackSession, let surface = terminalView.surface,
              let scrollbar = snapshotScrollView.scrollbar, scrollbar.total > 0, scrollbar.len > 0 else { return nil }
        let total = Int(clamping: scrollbar.total), page = Int(clamping: scrollbar.len)
        let first = max(0, total - max(0, limit))
        var rows = [String](repeating: "", count: total - first)
        var top = first
        while top < total {
            // scroll_to_row clamps the final page so it ends at the last row.
            let pageTop = max(0, min(top, total - page))
            surface.scrollToRow(UInt(pageTop))
            guard let text = session.readViewportRowsText() else { break }
            for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let row = pageTop + offset
                if row >= first, row < total { rows[row - first] = String(line) }
            }
            top = pageTop + page
        }
        surface.scrollToRow(UInt(clamping: scrollbar.offset))
        return ScrollbackRows(rows: rows, firstRow: first, totalRows: total)
    }

    /// Reads the viewport in place when it already shows row 0; otherwise pages to
    /// the top for one read and restores the offset in the same main-actor turn.
    public func firstRowText() -> String? {
        guard let session = scrollbackSession, let surface = terminalView.surface,
              let scrollbar = snapshotScrollView.scrollbar, scrollbar.total > 0 else { return nil }
        let atTop = scrollbar.offset == 0
        if !atTop { surface.scrollToRow(0) }
        let text = session.readViewportRowsText()
        if !atTop { surface.scrollToRow(UInt(clamping: scrollbar.offset)) }
        return text.map { String($0.prefix { $0 != "\n" }) }
    }

    public func scroll(toRow row: Int) {
        snapshotScrollView.reveal(row: UInt64(max(0, row)))
    }
}

/// Live terminal containers by session name, so Context can scroll the agent pane.
@MainActor
final class MobileTerminalRegistry {
    static let shared = MobileTerminalRegistry()
    private final class WeakContainer { weak var view: TerminalInputContainerView? ; init(_ view: TerminalInputContainerView) { self.view = view } }
    private var containers: [String: WeakContainer] = [:]

    func register(_ view: TerminalInputContainerView, sessionName: String) {
        containers = containers.filter { $0.value.view != nil }
        containers[sessionName] = WeakContainer(view)
    }

    func container(for sessionName: String) -> TerminalInputContainerView? {
        containers[sessionName]?.view
    }
}
#endif
