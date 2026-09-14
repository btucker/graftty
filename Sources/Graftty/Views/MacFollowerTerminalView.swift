import AppKit
import GhosttyKit
import GrafttyCommandUI
import GrafttyProtocol

private final class FollowerDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// Fits the authoritative native grid independently from the Mac pane's size.
final class MacFollowerTerminalView: NSView {
    let terminalView: SurfaceNSView
    let scrollView = NSScrollView()
    let scaledView = NSView()
    private let document = FollowerDocumentView()
    private let metrics: () -> ghostty_surface_size_s
    private var scrollbar = ghostty_action_scrollbar_s()
    private var rowHeight: CGFloat = 0
    private var nativeRow: UInt64 = 0
    private var adjusting = false
    private var boundsObserver: NSObjectProtocol?
    private let makeHistorySurface: ((NSView, CGFloat) -> ghostty_surface_t?)?
    private let historyScaledView = NSView()
    private var historyView: NSView?
    private var historySurface: ghostty_surface_t?
    var historySurfaceForTesting: ghostty_surface_t? { historySurface }
    private var lastHistory: Data?
    private var historyCellSize: CGSize?
    private var lastHistoryGrid: CGSize?
    private var historyTimer: Timer?
    var followerGrid: DisplayGrid? {
        didSet {
            guard followerGrid != oldValue else { return }
            needsLayout = true
            updateHistoryTimer()
        }
    }

    init(terminalView: SurfaceNSView, metrics: @escaping () -> ghostty_surface_size_s,
         makeHistorySurface: ((NSView, CGFloat) -> ghostty_surface_t?)? = nil) {
        self.terminalView = terminalView
        self.metrics = metrics
        self.makeHistorySurface = makeHistorySurface
        super.init(frame: .zero)
        wantsLayer = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        addSubview(scrollView)
        scrollView.documentView = document
        document.addSubview(historyScaledView)
        document.addSubview(scaledView)
        scaledView.addSubview(terminalView)
        terminalView.followerScrollHandler = { [weak self] event in
            guard let self, self.followerGrid != nil else { return false }
            self.scrollView.scrollWheel(with: event)
            return true
        }
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.didScroll() }
        }
    }

    deinit {
        historyTimer?.invalidate()
        historyView?.removeFromSuperview()
        if let historySurface { ghostty_surface_free(historySurface) }
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var historyRows: UInt64 { scrollbar.total - min(scrollbar.total, scrollbar.len) }
    private var atBottom: Bool { scrollView.contentView.bounds.maxY >= document.bounds.height - 1 }

    func updateScrollbar(_ value: ghostty_action_scrollbar_s) {
        guard value.total != scrollbar.total || value.offset != scrollbar.offset || value.len != scrollbar.len else { return }
        let bottom = atBottom
        let within = scrollView.contentView.bounds.minY - CGFloat(nativeRow) * rowHeight
        scrollbar = value
        nativeRow = min(value.offset, historyRows)
        reconcile(wasAtBottom: bottom, withinCanvas: within)
    }

    override func layout() {
        super.layout()
        let bottom = atBottom
        let within = scrollView.contentView.bounds.minY - CGFloat(nativeRow) * rowHeight
        scrollView.frame = bounds
        reconcile(wasAtBottom: bottom, withinCanvas: within)
    }

    private func reconcile(wasAtBottom: Bool, withinCanvas: CGFloat) {
        guard !adjusting else { return }
        adjusting = true
        defer { adjusting = false }
        let viewport = scrollView.contentSize
        let size = metrics()
        let pixelScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        guard let grid = followerGrid,
              let canvas = FollowerTerminalLayout.layout(
                grid: CGSize(width: Int(grid.cols), height: Int(grid.rows)),
                measuredGrid: CGSize(width: Int(size.columns), height: Int(size.rows)),
                measuredPixels: CGSize(width: Int(size.width_px), height: Int(size.height_px)),
                cellPixels: CGSize(width: Int(size.cell_width_px), height: Int(size.cell_height_px)),
                displayScale: pixelScale, container: viewport
              ) else {
            removeHistory()
            scrollView.hasVerticalScroller = false
            document.frame = CGRect(origin: .zero, size: viewport)
            scaledView.frame = document.bounds
            scaledView.bounds = CGRect(origin: .zero, size: viewport)
            terminalView.followerPixelSize = nil
            terminalView.setFrameOrigin(.zero)
            terminalView.setFrameSize(viewport)
            scrollView.contentView.scroll(to: .zero)
            return
        }
        scrollView.hasVerticalScroller = true
        let scale = min(1, canvas.scale)
        rowHeight = CGFloat(size.cell_height_px) / pixelScale * scale
        let screenHeight = canvas.size.height * scale
        document.frame = CGRect(x: 0, y: 0, width: viewport.width,
                                height: CGFloat(historyRows) * rowHeight + max(viewport.height, screenHeight))
        positionCanvas(canvas)
        terminalView.followerPixelSize = CGSize(
            width: (canvas.size.width * pixelScale).rounded(),
            height: (canvas.size.height * pixelScale).rounded()
        )
        terminalView.setFrameOrigin(.zero)
        terminalView.setFrameSize(canvas.size)
        let offset = wasAtBottom && nativeRow == historyRows
            ? document.bounds.height - viewport.height
            : CGFloat(nativeRow) * rowHeight + max(0, withinCanvas)
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: min(max(0, offset), max(0, document.bounds.height - viewport.height))))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        refreshHistory()
    }

    private func positionCanvas(_ canvas: FollowerTerminalLayout.Layout) {
        let scale = min(1, canvas.scale)
        let screenHeight = canvas.size.height * scale
        scaledView.frame = CGRect(x: 0,
                                  y: CGFloat(nativeRow) * rowHeight + max(0, scrollView.contentSize.height - screenHeight),
                                  width: canvas.size.width * scale, height: screenHeight)
        scaledView.bounds = CGRect(origin: .zero, size: canvas.size)
    }

    private func didScroll() {
        guard !adjusting, followerGrid != nil, rowHeight > 0 else { return }
        let row = atBottom ? historyRows : UInt64(min(CGFloat(historyRows), max(0, floor(scrollView.contentView.bounds.minY / rowHeight))))
        if row != nativeRow, let surface = terminalView.surface {
            nativeRow = row
            let action = "scroll_to_row:\(row)"
            action.withCString { _ = ghostty_surface_binding_action(surface, $0, UInt(action.utf8.count)) }
        }
        let height = scaledView.frame.height
        scaledView.setFrameOrigin(CGPoint(x: 0, y: CGFloat(nativeRow) * rowHeight + max(0, scrollView.contentSize.height - height)))
        refreshHistory()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateHistoryTimer()
    }

    private func updateHistoryTimer() {
        historyTimer?.invalidate()
        historyTimer = nil
        guard window != nil, followerGrid != nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.refreshHistory()
        }
        RunLoop.main.add(timer, forMode: .common)
        historyTimer = timer
    }

    private func removeHistory() {
        historyView?.removeFromSuperview()
        historyView = nil
        if let historySurface { ghostty_surface_free(historySurface) }
        historySurface = nil
        lastHistory = nil
        historyCellSize = nil
        lastHistoryGrid = nil
    }

    private func refreshHistory() {
        #if GRAFTTY_PAGED_HISTORY
        guard let grid = followerGrid, rowHeight > 0,
              window?.isVisible == true, let source = terminalView.surface,
              let makeHistorySurface else { return }
        let size = metrics()
        guard size.columns == grid.cols, size.rows == grid.rows else { needsLayout = true; return }
        let cells = CGSize(width: Int(size.cell_width_px), height: Int(size.cell_height_px))
        if historyCellSize != cells { removeHistory(); historyCellSize = cells }
        let pixelScale = window?.backingScaleFactor ?? 2
        let scale = scaledView.frame.width / max(1, scaledView.bounds.width)
        let padding = max(0, CGFloat(size.height_px) - CGFloat(size.rows) * CGFloat(size.cell_height_px))
        let rows = FollowerTerminalLayout.additionalHistoryRows(
            containerHeight: scrollView.contentSize.height - padding / pixelScale * scale,
            screenHeight: scaledView.frame.height, rowHeight: rowHeight,
            columns: grid.cols, precedingRows: nativeRow
        )
        var text = ghostty_text_s()
        guard rows > 0, ghostty_surface_read_history(source, nativeRow, rows, &text) else {
            removeHistory()
            return
        }
        defer { ghostty_surface_free_text(source, &text) }
        guard let bytes = text.text else { return }
        let data = Data(bytes: bytes, count: Int(text.text_len))
        let pixelHeight = CGFloat(text.offset_len) * CGFloat(size.cell_height_px) + padding
        let nativeSize = CGSize(width: scaledView.bounds.width, height: (pixelHeight + 0.5) / pixelScale)
        let height = nativeSize.height * scale
        historyScaledView.frame = CGRect(x: 0, y: scaledView.frame.minY - height,
                                         width: scaledView.frame.width, height: height)
        historyScaledView.bounds = CGRect(origin: .zero, size: nativeSize)
        if historyView == nil {
            let view = FollowerHistoryContentView(frame: CGRect(origin: .zero, size: nativeSize))
            view.wantsLayer = true
            historyScaledView.addSubview(view)
            guard let surface = makeHistorySurface(view, pixelScale) else { view.removeFromSuperview(); return }
            historyView = view
            historySurface = surface
        }
        guard let historySurface else { return }
        historyView?.frame = CGRect(origin: .zero, size: nativeSize)
        ghostty_surface_set_size(historySurface, size.width_px, UInt32(pixelHeight.rounded()))
        guard ghostty_surface_grid_matches(historySurface, grid.cols, UInt16(text.offset_len)) else { return }
        let historyGrid = CGSize(width: Int(grid.cols), height: Int(text.offset_len))
        guard data != lastHistory || lastHistoryGrid != historyGrid else { return }
        var repaint = Data("\u{18}\u{1b}[0m\u{1b}[2J\u{1b}[H\u{1b}[?25l".utf8)
        repaint.append(data)
        repaint.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            ghostty_surface_write_buffer(historySurface, base.assumingMemoryBound(to: UInt8.self), UInt(raw.count))
        }
        ghostty_surface_refresh(historySurface)
        lastHistory = data
        lastHistoryGrid = historyGrid
        #endif
    }
}

private final class FollowerHistoryContentView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
