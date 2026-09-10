#if canImport(UIKit)
import GhosttyTerminal
import UIKit

/// Scrolls a width-fitted checkpoint without resizing its native terminal grid.
/// The content includes loaded history followed by the full authoritative screen.
/// Only one native screen is rendered, positioned at its absolute history row.
@MainActor
final class TerminalSnapshotScrollView: UIScrollView, UIScrollViewDelegate {
    let terminalView: UITerminalView
    private var canvas: TerminalSnapshotCanvas.Layout?
    private var rowHeight: CGFloat = 0
    private var scrollbar: TerminalScrollbar?
    private var nativeRow: UInt64 = 0
    private var adjusting = false
    private var viewportHeight: CGFloat = 0

    init(terminalView: UITerminalView) {
        self.terminalView = terminalView
        super.init(frame: .zero)
        delegate = self
        contentInsetAdjustmentBehavior = .never
        bounces = false
        scrollsToTop = false
        delaysContentTouches = false
        showsHorizontalScrollIndicator = false
        panGestureRecognizer.allowedScrollTypesMask = [.continuous, .discrete]
        isScrollEnabled = false
        addSubview(terminalView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var historyRows: UInt64 {
        guard let scrollbar else { return 0 }
        return scrollbar.total - min(scrollbar.total, scrollbar.len)
    }

    func configure(canvas: TerminalSnapshotCanvas.Layout?, rowHeight: CGFloat) {
        let wasAtBottom = contentOffset.y >= contentSize.height - viewportHeight - 0.5
        let withinCanvas = self.rowHeight > 0
            ? (contentOffset.y / self.rowHeight - CGFloat(nativeRow)) * rowHeight : 0
        viewportHeight = bounds.height
        self.canvas = canvas
        self.rowHeight = rowHeight
        isScrollEnabled = canvas != nil
        reconcile(wasAtBottom: wasAtBottom, withinCanvas: withinCanvas)
    }

    func updateScrollbar(_ value: TerminalScrollbar) {
        guard value != scrollbar else { return }
        let wasAtBottom = contentOffset.y >= contentSize.height - bounds.height - 0.5
        let withinCanvas = contentOffset.y - CGFloat(nativeRow) * rowHeight
        let replacedHistory = value.total < (scrollbar?.total ?? 0)
        scrollbar = value
        nativeRow = min(value.offset, historyRows)
        guard canvas != nil else { return }
        reconcile(wasAtBottom: wasAtBottom || replacedHistory, withinCanvas: withinCanvas)
    }

    private func reconcile(wasAtBottom: Bool, withinCanvas: CGFloat) {
        adjusting = true
        defer { adjusting = false }
        guard let canvas, rowHeight > 0 else {
            contentSize = bounds.size
            contentOffset = .zero
            terminalView.transform = .identity
            terminalView.frame = CGRect(origin: .zero, size: bounds.size)
            return
        }
        let screenHeight = canvas.size.height * canvas.scale
        let overflow = max(0, screenHeight - bounds.height)
        contentSize = CGSize(
            width: bounds.width,
            height: CGFloat(historyRows) * rowHeight + max(bounds.height, screenHeight)
        )
        let offset = CGFloat(nativeRow) * rowHeight
            + (wasAtBottom && nativeRow == historyRows ? overflow : max(0, withinCanvas))
        contentOffset = CGPoint(x: 0, y: min(offset, max(0, contentSize.height - bounds.height)))
        positionCanvas(canvas)
    }

    private func positionCanvas(_ canvas: TerminalSnapshotCanvas.Layout) {
        terminalView.bounds = CGRect(origin: .zero, size: canvas.size)
        terminalView.center = CGPoint(
            x: bounds.width / 2,
            y: CGFloat(nativeRow) * rowHeight + max(bounds.height, canvas.size.height * canvas.scale) / 2
        )
        terminalView.transform = CGAffineTransform(scaleX: canvas.scale, y: canvas.scale)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !adjusting, let canvas, rowHeight > 0 else { return }
        // UIScrollView quantizes offsets to display pixels. Treat its rounded
        // bottom as the final row instead of occasionally stopping one row up.
        let atBottom = contentOffset.y >= contentSize.height - bounds.height - 0.5
        let row = atBottom ? historyRows
            : UInt64(min(CGFloat(historyRows), max(0, floor(contentOffset.y / rowHeight))))
        if row != nativeRow {
            nativeRow = row
            terminalView.surface?.scrollToRow(UInt(row))
        }
        positionCanvas(canvas)
    }
}
#endif
