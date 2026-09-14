#if canImport(UIKit)
import GhosttyTerminal
import UIKit

/// Scrolls a width-fitted checkpoint without resizing its native terminal grid.
/// The content includes loaded history followed by the full authoritative screen.
/// The live screen keeps its native grid; a separate display fills spare height with history.
@MainActor
final class TerminalSnapshotScrollView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    let terminalView: UITerminalView
    private var canvas: TerminalSnapshotCanvas.Layout?
    private var followerZoomScale: CGFloat = 1
    private var baseRowHeight: CGFloat = 0
    private var pinchStartScale: CGFloat = 1
    private var presentationScale: CGFloat { (canvas?.scale ?? 1) * followerZoomScale }
    lazy var followerPinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(pinchFollower(_:)))

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === followerPinchGesture && otherGestureRecognizer === panGestureRecognizer
    }

    @objc private func pinchFollower(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchStartScale = followerZoomScale
        case .changed:
            let location = gesture.location(in: self)
            setFollowerZoomScale(pinchStartScale * gesture.scale,
                                 around: CGPoint(x: location.x - bounds.minX, y: location.y - bounds.minY))
        default:
            break
        }
    }

    /// Zoom the presentation around a point in the visible viewport. The
    /// terminal bounds and its native font and grid are unchanged.
    func setFollowerZoomScale(_ scale: CGFloat, around point: CGPoint) {
        guard let canvas, scale.isFinite else { return }
        let next = min(4, max(1, scale))
        guard next != followerZoomScale else { return }
        let ratio = next / followerZoomScale
        let anchor = CGPoint(x: contentOffset.x + point.x,
                             y: contentOffset.y + point.y - terminalView.frame.minY)
        followerZoomScale = next
        configure(canvas: canvas, rowHeight: baseRowHeight, columns: columns)
        adjusting = true
        contentOffset = CGPoint(
            x: min(max(0, anchor.x * ratio - point.x), max(0, contentSize.width - bounds.width)),
            y: min(max(0, terminalView.frame.minY + anchor.y * ratio - point.y),
                   max(0, contentSize.height - bounds.height))
        )
        adjusting = false
        scrollViewDidScroll(self)
    }

    private var rowHeight: CGFloat = 0
    private var scrollbar: TerminalScrollbar?
    private var nativeRow: UInt64 = 0
    private var adjusting = false
    private var viewportHeight: CGFloat = 0
    var showsAdditionalHistory = false {
        didSet {
            guard showsAdditionalHistory != oldValue else { return }
            #if GRAFTTY_PAGED_HISTORY
            updateHistoryTimer()
            #endif
        }
    }
    private var includesAdditionalHistory: Bool {
        #if GRAFTTY_PAGED_HISTORY
        showsAdditionalHistory
        #else
        false
        #endif
    }
    private var columns: UInt16 = 0
    #if GRAFTTY_PAGED_HISTORY
    private var historyView: UITerminalView?
    private var historyController: TerminalController?
    private var historyConfig: String?
    private let historySession = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
    private var lastHistory: TerminalHistorySlice?
    private var lastHistoryFittedPixels: CGSize?
    private var historyTimer: Timer?
    #endif

    init(terminalView: UITerminalView) {
        self.terminalView = terminalView
        super.init(frame: .zero)
        delegate = self
        contentInsetAdjustmentBehavior = .never
        bounces = false
        scrollsToTop = false
        delaysContentTouches = false
        showsHorizontalScrollIndicator = true
        followerPinchGesture.isEnabled = false
        followerPinchGesture.delegate = self
        addGestureRecognizer(followerPinchGesture)
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

    /// Rows visible above the live grid, including rows not fetched yet.
    var additionalHistoryRowCapacity: UInt32 {
        guard window != nil, includesAdditionalHistory, let canvas else { return 0 }
        return TerminalSnapshotCanvas.additionalHistoryRows(
            containerHeight: bounds.height, screenHeight: canvas.size.height * presentationScale,
            rowHeight: rowHeight, columns: columns, precedingRows: .max
        )
    }

    func configure(canvas: TerminalSnapshotCanvas.Layout?, rowHeight: CGFloat, columns: UInt16 = 0) {
        if canvas == nil { followerZoomScale = 1 }
        baseRowHeight = rowHeight
        let rowHeight = rowHeight * followerZoomScale
        let wasAtBottom = contentOffset.y >= contentSize.height - viewportHeight - 1
        let withinCanvas = self.rowHeight > 0
            ? (contentOffset.y / self.rowHeight - CGFloat(nativeRow)) * rowHeight : 0
        viewportHeight = bounds.height
        self.canvas = canvas
        self.rowHeight = rowHeight
        self.columns = columns
        isScrollEnabled = canvas != nil
        reconcile(wasAtBottom: wasAtBottom, withinCanvas: withinCanvas)
    }

    func updateScrollbar(_ value: TerminalScrollbar) {
        guard value != scrollbar else { return }
        let wasAtBottom = contentOffset.y >= contentSize.height - bounds.height - 1
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
            #if GRAFTTY_PAGED_HISTORY
            removeHistoryView()
            #endif
            return
        }
        let screenHeight = canvas.size.height * presentationScale
        let overflow = max(0, screenHeight - bounds.height)
        contentSize = CGSize(
            width: max(bounds.width, canvas.size.width * presentationScale),
            height: CGFloat(historyRows) * rowHeight + max(bounds.height, screenHeight)
        )
        let offset = CGFloat(nativeRow) * rowHeight
            + (wasAtBottom && nativeRow == historyRows ? overflow : max(0, withinCanvas))
        contentOffset = CGPoint(x: min(contentOffset.x, max(0, contentSize.width - bounds.width)),
                                y: min(offset, max(0, contentSize.height - bounds.height)))
        positionCanvas(canvas)
    }

    private func positionCanvas(_ canvas: TerminalSnapshotCanvas.Layout) {
        terminalView.bounds = CGRect(origin: .zero, size: canvas.size)
        terminalView.center = CGPoint(
            x: contentSize.width / 2,
            y: CGFloat(nativeRow) * rowHeight
                + (includesAdditionalHistory ? max(bounds.height, canvas.size.height * presentationScale)
                    - canvas.size.height * presentationScale / 2
                    : max(bounds.height, canvas.size.height * presentationScale) / 2)
        )
        terminalView.transform = CGAffineTransform(scaleX: presentationScale, y: presentationScale)
        #if GRAFTTY_PAGED_HISTORY
        refreshAdditionalHistory()
        #endif
    }

    #if GRAFTTY_PAGED_HISTORY
    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateHistoryTimer()
    }

    private func updateHistoryTimer() {
        historyTimer?.invalidate()
        historyTimer = nil
        if window != nil && showsAdditionalHistory {
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshAdditionalHistory() }
            }
            RunLoop.main.add(timer, forMode: .common)
            historyTimer = timer
        }
    }

    private func removeHistoryView() {
        historyView?.removeFromSuperview()
        historyView = nil
        historyController = nil
        historyConfig = nil
        lastHistory = nil
        lastHistoryFittedPixels = nil
    }

    func refreshAdditionalHistory() {
        guard showsAdditionalHistory, let canvas, rowHeight > 0,
              let sourceController = terminalView.controller else {
            removeHistoryView()
            return
        }
        let rows = TerminalSnapshotCanvas.additionalHistoryRows(
            containerHeight: bounds.height, screenHeight: canvas.size.height * presentationScale,
            rowHeight: rowHeight, columns: columns, precedingRows: nativeRow
        )
        guard rows > 0, let source = terminalView.surface,
              let history = source.readHistory(beforeRow: nativeRow, rows: rows) else {
            removeHistoryView()
            return
        }
        guard let fontSize = source.currentFontSize else { return }
        let config = sourceController.renderedConfig
            + "\nwindow-padding-y = 0\nfont-size = \(fontSize)\n"
        if historyConfig != config {
            historyController = MobileTerminalControllerFactory.make(configText: config)
            historyConfig = config
            lastHistory = nil
            lastHistoryFittedPixels = nil
        }
        let view: UITerminalView
        if let historyView { view = historyView } else {
            view = UITerminalView(frame: .zero)
            view.isUserInteractionEnabled = false
            view.configuration = .init(backend: .inMemory(historySession))
            historyView = view
            insertSubview(view, belowSubview: terminalView)
        }
        view.controller = historyController
        view.overrideUserInterfaceStyle = terminalView.overrideUserInterfaceStyle
        // Native sizing floors pixels. Leave half a pixel below the final row
        // so floating-point roundoff cannot remove a row from this display.
        let pixelScale = terminalView.contentScaleFactor
        let pixels = (CGFloat(history.rows) * rowHeight / presentationScale * pixelScale).rounded()
        let nativeHeight = (pixels + 0.5) / pixelScale
        let height = nativeHeight * presentationScale
        view.bounds = CGRect(x: 0, y: 0, width: canvas.size.width, height: nativeHeight)
        view.center = CGPoint(x: contentSize.width / 2, y: terminalView.frame.minY - height / 2)
        view.transform = CGAffineTransform(scaleX: presentationScale, y: presentationScale)
        let fittedPixels = CGSize(
            width: floor(view.bounds.width * view.contentScaleFactor),
            height: floor(view.bounds.height * view.contentScaleFactor)
        )
        // Fitting requests a native redraw. Poll grid readiness below without
        // waking the renderer again when the display dimensions are unchanged.
        if fittedPixels != lastHistoryFittedPixels {
            view.fitToSize()
            lastHistoryFittedPixels = fittedPixels
        }
        guard historySession.gridMatches(columns: columns, rows: UInt16(history.rows)), history != lastHistory else { return }
        // Repaint only this detached history display. Its VT parser never
        // receives live host commands, and its replies never reach the host.
        var repaint = Data("\u{18}\u{1b}[0m\u{1b}[2J\u{1b}[H\u{1b}[?25l".utf8)
        repaint.append(history.bytes)
        historySession.receive(repaint)
        lastHistory = history
    }

    var additionalHistoryTextForTesting: String? { historySession.readViewportText() }
    var additionalHistoryFrameForTesting: CGRect? { historyView?.frame }
    #else
    func refreshAdditionalHistory() {}
    var additionalHistoryTextForTesting: String? { nil }
    var additionalHistoryFrameForTesting: CGRect? { nil }
    #endif

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !adjusting, let canvas, rowHeight > 0 else { return }
        // UIScrollView quantizes offsets to display pixels. Treat its rounded
        // bottom as the final row instead of occasionally stopping one row up.
        // Allow one point for a near-bottom offset plus display-pixel rounding.
        let atBottom = contentOffset.y >= contentSize.height - bounds.height - 1
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
