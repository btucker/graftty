import CoreGraphics
import Testing
@testable import GrafttyMobileKit

@Suite("@spec TERM-12.13: While a mobile terminal displays a paged checkpoint, the application shall preserve its authoritative columns and rows in a canvas fitted to the pane width, allow vertical scrolling through overflow and history, and map touch and selection coordinates through that canvas.")
struct TerminalSnapshotCanvasTests {
    @Test("@spec TERM-12.18: While a follower has unused vertical space above its width-fitted live grid and earlier rows are loaded, the application shall fill that space with whole scrollback rows without changing the leader's grid, cursor, or selection, bounded to 262144 additional cells.")
    func spareHeightShowsOnlyAvailableWholeHistoryRows() {
        #expect(TerminalSnapshotCanvas.additionalHistoryRows(
            containerHeight: 701, screenHeight: 200, rowHeight: 4,
            columns: 200, precedingRows: 1000
        ) == 125)
        #expect(TerminalSnapshotCanvas.additionalHistoryRows(
            containerHeight: 701, screenHeight: 200, rowHeight: 4,
            columns: 200, precedingRows: 12
        ) == 12)
        #expect(TerminalSnapshotCanvas.additionalHistoryRows(
            containerHeight: 199, screenHeight: 200, rowHeight: 4,
            columns: 200, precedingRows: 1000
        ) == 0)
        #expect(TerminalSnapshotCanvas.additionalHistoryRows(
            containerHeight: 5000, screenHeight: 200, rowHeight: 1,
            columns: 1000, precedingRows: 10000
        ) == 262)
        #expect(TerminalSnapshotCanvas.additionalHistoryRows(
            containerHeight: 300000, screenHeight: 1, rowHeight: 1,
            columns: 1, precedingRows: 300000
        ) == UInt16.max)
    }

    @Test func usesMeasuredCellsAndPreservesPixelRemainders() throws {
        let layout = try #require(TerminalSnapshotCanvas.layout(
            grid: CGSize(width: 80, height: 24),
            measuredGrid: CGSize(width: 60, height: 30),
            measuredPixels: CGSize(width: 607, height: 607),
            cellPixels: CGSize(width: 10, height: 20),
            displayScale: 2,
            container: CGSize(width: 320, height: 240)
        ))
        #expect(layout.size == CGSize(width: 403.5, height: 243.5))
        #expect(abs(layout.size.width * layout.scale - 320) < 0.001)
        #expect(layout.size.height * layout.scale <= 240)
    }

    @Test func rotationChangesPresentationWithoutChangingTerminalGrid() throws {
        func layout(_ container: CGSize) -> TerminalSnapshotCanvas.Layout? {
            TerminalSnapshotCanvas.layout(
                grid: CGSize(width: 80, height: 24),
                measuredGrid: CGSize(width: 80, height: 24),
                measuredPixels: CGSize(width: 807, height: 487),
                cellPixels: CGSize(width: 10, height: 20),
                displayScale: 2, container: container
            )
        }
        let portrait = try #require(layout(CGSize(width: 320, height: 600)))
        let landscape = try #require(layout(CGSize(width: 600, height: 160)))
        #expect(portrait.size == landscape.size)
        #expect(abs(landscape.size.width * landscape.scale - 600) < 0.001)
        #expect(landscape.size.height * landscape.scale > 160)
    }

    @Test func tallHostScreenFillsIPadWidthWithoutChangingItsGrid() throws {
        let layout = try #require(TerminalSnapshotCanvas.layout(
            grid: CGSize(width: 116, height: 95),
            measuredGrid: CGSize(width: 116, height: 95),
            measuredPixels: CGSize(width: 1167, height: 1907),
            cellPixels: CGSize(width: 10, height: 20),
            displayScale: 2, container: CGSize(width: 900, height: 600)
        ))
        #expect(layout.size == CGSize(width: 583.5, height: 953.5))
        #expect(abs(layout.size.width * layout.scale - 900) < 0.001)
        #expect(layout.size.height * layout.scale > 600)
    }

    @Test func waitsForValidNativeCellMetrics() {
        #expect(TerminalSnapshotCanvas.layout(
            grid: CGSize(width: 80, height: 24),
            measuredGrid: .zero, measuredPixels: .zero, cellPixels: .zero,
            displayScale: 2, container: CGSize(width: 320, height: 240)
        ) == nil)
    }
}

#if canImport(UIKit)
import GhosttyTerminal
import GrafttyProtocol
import UIKit

@MainActor
struct MountedTerminalSnapshotCanvasTests {
    @Test("@spec TERM-12.14: While an authoritative canvas is active, the application shall disable native font pinch through selection transitions and restore its prior state when the canvas is released.")
    func canvasAndSelectionPreserveGestureEnablement() throws {
        let container = TerminalInputContainerView(frame: .zero)
        let pinch = try #require(container.terminalView.gestureRecognizers?.compactMap { $0 as? UIPinchGestureRecognizer }.first)
        #expect(pinch.isEnabled)
        container.authoritativeGrid = .init(cols: 80, rows: 24)
        #expect(!pinch.isEnabled)
        #expect(container.snapshotScrollView.followerPinchGesture.isEnabled)
        let pans = container.terminalView.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer } ?? []
        #expect(pans.allSatisfy { !$0.isEnabled })
        let canvasPan = container.snapshotScrollView.panGestureRecognizer
        let canvasPinch = container.snapshotScrollView.followerPinchGesture
        #expect(canvasPinch.delegate?.gestureRecognizer?(canvasPinch, shouldRecognizeSimultaneouslyWith: canvasPan) == true)
        let savedTouchTypes = canvasPan.allowedTouchTypes
        container.enterSelectionModeForTesting()
        #expect(canvasPan.allowedTouchTypes == TerminalInputContainerView.indirectPointerOnlyTouchTypes)
        #expect(!container.snapshotScrollView.followerPinchGesture.isEnabled)
        container.exitSelectionModeForTesting()
        #expect(canvasPan.allowedTouchTypes == savedTouchTypes)
        #expect(container.snapshotScrollView.followerPinchGesture.isEnabled)
        #expect(!pinch.isEnabled)
        container.authoritativeGrid = nil
        #expect(pans.allSatisfy { $0.isEnabled })
        #expect(!container.snapshotScrollView.followerPinchGesture.isEnabled)
        #expect(pinch.isEnabled)

        container.enterSelectionModeForTesting()
        container.authoritativeGrid = .init(cols: 80, rows: 24)
        container.authoritativeGrid = nil
        #expect(!pinch.isEnabled)
        container.exitSelectionModeForTesting()
        #expect(pinch.isEnabled)

        pinch.isEnabled = false
        container.authoritativeGrid = .init(cols: 80, rows: 24)
        container.enterSelectionModeForTesting()
        container.authoritativeGrid = nil
        container.exitSelectionModeForTesting()
        #expect(!pinch.isEnabled)
    }

    @Test("@spec IOS-4.32: When a follower takes control without typing, the application shall lay out and confirm its physical viewport before sending the owner resize, including while rendering is reduced.")
    func releasingFollowerCanvasConfirmsPhysicalViewportWithoutInput() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        let container = TerminalInputContainerView(frame: window.bounds)
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        container.terminalView.controller = MobileTerminalControllerFactory.make(configText: "font-size = 14")
        container.terminalView.configuration = .init(backend: .inMemory(session))
        container.terminalView.delegate = container
        host.view.addSubview(container)
        container.layoutIfNeeded()
        defer { container.removeFromSuperview(); window.isHidden = true }
        let physical = try #require(container.terminalGridMetrics)
        container.authoritativeGrid = .init(cols: 200, rows: 50)
        container.layoutIfNeeded()
        container.terminalView.fitToSize()
        try await Task.sleep(for: .milliseconds(50))
        #expect(container.terminalGridMetrics?.columns == 200)
        var confirmed: InMemoryTerminalViewport?
        container.onPhysicalViewportReady = { confirmed = $0 }
        container.terminalView.renderPace = .reduced(interval: 60)
        container.authoritativeGrid = nil
        let box = TerminalContainerBox()
        box.view = container
        box.fitTerminalToCurrentSize()
        for _ in 0..<20 where confirmed == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(confirmed?.columns == physical.columns)
        #expect(confirmed?.rows == physical.rows)
    }

    @Test func verticalOverflowAndHistoryShareOneScrollableViewport() throws {
        let terminal = UITerminalView(frame: .zero)
        let scroll = TerminalSnapshotScrollView(terminalView: terminal)
        scroll.frame = CGRect(x: 0, y: 0, width: 600, height: 160)
        let canvas = try #require(TerminalSnapshotCanvas.layout(
            grid: CGSize(width: 80, height: 24),
            measuredGrid: CGSize(width: 80, height: 24),
            measuredPixels: CGSize(width: 807, height: 487),
            cellPixels: CGSize(width: 10, height: 20),
            displayScale: 2, container: scroll.bounds.size
        ))
        let rowHeight = 10 * canvas.scale
        scroll.configure(canvas: canvas, rowHeight: rowHeight)
        scroll.updateScrollbar(.init(total: 124, offset: 100, len: 24))
        #expect(abs(terminal.frame.width - 600) < 0.5)
        #expect(abs(scroll.contentOffset.y - (scroll.contentSize.height - 160)) < 0.5)
        #expect(abs(scroll.convert(terminal.bounds, from: terminal).maxY - scroll.bounds.maxY) < 0.5)

        scroll.contentOffset = CGPoint(x: 0, y: 3.5 * rowHeight)
        let visibleOrigin = terminal.frame.minY - scroll.contentOffset.y
        let offset = scroll.contentOffset.y
        // Native history import shifts the row number while preserving the text.
        scroll.updateScrollbar(.init(total: 224, offset: 103, len: 24))
        #expect(abs(scroll.contentOffset.y - offset - 100 * rowHeight) < 0.5)
        #expect(abs(terminal.frame.minY - scroll.contentOffset.y - visibleOrigin) < 0.5)

        scroll.contentOffset = .zero
        #expect(abs(terminal.frame.minY) < 0.5)
        #expect(terminal.bounds.size == canvas.size)
        scroll.configure(canvas: nil, rowHeight: 0)
        #expect(!scroll.isScrollEnabled)
        #expect(terminal.transform == .identity)
        #expect(terminal.frame == CGRect(x: 0, y: 0, width: 600, height: 160))
    }

    @Test("@spec TERM-12.22: While a mobile terminal follows another display, the application shall allow local canvas zoom and horizontal scrolling without changing the native grid or font, and restore the physical viewport when it becomes leader.", arguments: [390, 834])
    func followerZoomPreservesNativeGridAndAllowsHorizontalScrolling(width: Int) async throws {
        let viewportWidth = CGFloat(width)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: viewportWidth, height: 700))
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        let container = TerminalInputContainerView(frame: window.bounds)
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        container.terminalView.controller = MobileTerminalControllerFactory.make(configText: "font-size = 14")
        container.terminalView.configuration = .init(backend: .inMemory(session))
        host.view.addSubview(container)
        container.layoutIfNeeded()
        defer { container.removeFromSuperview(); window.isHidden = true }
        container.authoritativeGrid = .init(cols: 200, rows: 50)
        container.layoutIfNeeded()
        container.terminalView.fitToSize()
        try await Task.sleep(for: .milliseconds(50))
        let original = try #require(container.terminalGridMetrics)
        let nativeBounds = container.terminalView.bounds
        let scroll = container.snapshotScrollView
        scroll.setFollowerZoomScale(2, around: CGPoint(x: viewportWidth / 2, y: 350))
        #expect(abs(scroll.contentSize.width - viewportWidth * 2) < 1)
        #expect(abs(container.terminalView.frame.width - viewportWidth * 2) < 1)
        #expect(container.terminalView.bounds == nativeBounds)
        scroll.contentOffset.x = 250
        container.setNeedsLayout()
        container.layoutIfNeeded()
        #expect(abs(scroll.contentOffset.x - 250) < 1)
        #expect(container.terminalGridMetrics?.columns == 200)
        #expect(container.terminalGridMetrics?.rows == 50)
        #expect(container.terminalGridMetrics?.cellWidthPixels == original.cellWidthPixels)
        #expect(container.terminalGridMetrics?.cellHeightPixels == original.cellHeightPixels)
        scroll.setFollowerZoomScale(0.5, around: .zero)
        #expect(abs(scroll.contentSize.width - viewportWidth) < 1)
        #expect(scroll.contentOffset.x == 0)
        scroll.setFollowerZoomScale(2, around: .zero)
        container.authoritativeGrid = nil
        container.layoutIfNeeded()
        #expect(container.terminalView.transform == .identity)
        #expect(scroll.contentSize == container.bounds.size)
        #expect(scroll.contentOffset == .zero)
    }

    @Test("@spec TERM-12.21: When a mobile terminal with a runtime font adjustment becomes a follower, the application shall render additional history using its current font metrics.", .enabled(if: MobilePagedTerminalRenderer.isSupported))
    func historyPreservesRuntimeFontSize() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        let container = TerminalInputContainerView(frame: window.bounds)
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        container.terminalView.controller = MobileTerminalControllerFactory.make(configText: "font-size = 14")
        container.terminalView.configuration = .init(backend: .inMemory(session))
        host.view.addSubview(container)
        container.layoutIfNeeded()
        defer { container.removeFromSuperview(); window.isHidden = true }
        let renderer = MobilePagedTerminalRenderer(session: session) { cols, rows in
            container.authoritativeGrid = .init(cols: cols, rows: rows)
            container.setNeedsLayout()
            container.layoutIfNeeded()
        }
        try await renderer.install(.init(incarnation: 1, id: 1, cols: 80, rows: 24,
            ready: try #require(Data(base64Encoded: Self.ready)),
            hasPrimaryHistory: true, hasAlternateHistory: false), generation: 1)
        let surface = try #require(container.terminalView.surface)
        #expect(surface.performAction("increase_font_size:4"))
        container.snapshotScrollView.showsAdditionalHistory = true
        for _ in 0..<100 {
            container.setNeedsLayout()
            container.layoutIfNeeded()
            container.snapshotScrollView.refreshAdditionalHistory()
            if container.snapshotScrollView.additionalHistoryTextForTesting?.contains("row-099975") == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(container.snapshotScrollView.additionalHistoryTextForTesting?.contains("row-099975") == true)
        #expect(container.terminalGridMetrics?.columns == 80)
        #expect(container.terminalGridMetrics?.rows == 24)
    }

    @Test("@spec TERM-12.20: While a mounted mobile follower has space for older rows above its live screen, the application shall request history for that visible space without scrolling, and stop prefetching for that space when it is filled or the follower canvas is released.", .enabled(if: MobilePagedTerminalRenderer.isSupported))
    func checkpointInstallsInARealCanvasWhoseContainerHasDifferentDimensions() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        let container = TerminalInputContainerView(frame: window.bounds)
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        container.terminalView.controller = MobileTerminalControllerFactory.make(configText: "font-size = 14")
        container.terminalView.configuration = .init(backend: .inMemory(session))
        host.view.addSubview(container)
        container.setNeedsLayout()
        container.layoutIfNeeded()
        defer {
            container.removeFromSuperview()
            window.isHidden = true
        }
        let physicalGrid = try #require(container.terminalGridMetrics)
        let pinch = try #require(container.terminalView.gestureRecognizers?.compactMap { $0 as? UIPinchGestureRecognizer }.first)
        #expect(pinch.isEnabled)
        #expect(physicalGrid.columns != 80 || physicalGrid.rows != 24)
        let renderer = MobilePagedTerminalRenderer(session: session, additionalHistoryRows: {
            container.snapshotScrollView.additionalHistoryRowCapacity
        }) { cols, rows in
            container.authoritativeGrid = .init(cols: cols, rows: rows)
            container.setNeedsLayout()
            container.layoutIfNeeded()
        }
        let checkpoint = PagedTerminalCheckpoint(
            incarnation: 1, id: 1, cols: 80, rows: 24,
            ready: try #require(Data(base64Encoded: Self.ready)),
            hasPrimaryHistory: true, hasAlternateHistory: false
        )
        try await renderer.install(checkpoint, generation: 1)
        #expect(!pinch.isEnabled)
        #expect(container.terminalGridMetrics?.columns == 80)
        #expect(container.terminalGridMetrics?.rows == 24)
        #expect(session.readViewportText()?.contains("row-099999") == true)
        #expect(session.readViewportText()?.contains("row-000000") == false)
        #expect(abs(container.terminalView.frame.width - container.bounds.width) < 0.1)
        #expect(container.terminalView.frame.height <= container.bounds.height + 0.1)

        #expect(!renderer.isNearHistoryTop(screen: 0, generation: 1))
        container.snapshotScrollView.showsAdditionalHistory = true
        container.frame.size.height = 1600
        container.setNeedsLayout()
        container.layoutIfNeeded()
        #expect(container.snapshotScrollView.additionalHistoryRowCapacity > 64)
        #expect(renderer.isNearHistoryTop(screen: 0, generation: 1))
        #expect(!renderer.isNearHistoryTop(screen: 1, generation: 1))
        container.snapshotScrollView.showsAdditionalHistory = false
        #expect(!renderer.isNearHistoryTop(screen: 0, generation: 1))
        container.frame.size.height = 500
        container.setNeedsLayout()
        container.layoutIfNeeded()

        let sourceSurface = try #require(container.terminalView.surface)
        #expect(sourceSurface.performAction("select_all"))
        let selectionBeforeHistory = try #require(sourceSurface.readSelection())
        let liveBeforeHistory = session.readViewportText()
        let liveGridBeforeHistory = container.terminalGridMetrics
        container.snapshotScrollView.showsAdditionalHistory = true
        container.setNeedsLayout()
        container.layoutIfNeeded()
        for _ in 0..<100 {
            container.snapshotScrollView.refreshAdditionalHistory()
            if container.snapshotScrollView.additionalHistoryTextForTesting?.contains("row-099975") == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let extraText = try #require(container.snapshotScrollView.additionalHistoryTextForTesting)
        #expect(extraText.contains("row-099975"))
        #expect(!extraText.contains("row-099999"))
        #expect(session.readViewportText() == liveBeforeHistory)
        #expect(sourceSurface.readSelection() == selectionBeforeHistory)
        #expect(sourceSurface.performAction("clear_selection"))
        #expect(container.terminalGridMetrics == liveGridBeforeHistory)
        let extraFrame = try #require(container.snapshotScrollView.additionalHistoryFrameForTesting)
        #expect(abs(extraFrame.maxY - container.terminalView.frame.minY) < 0.1)
        #expect(abs(extraFrame.width - container.bounds.width) < 0.1)
        container.snapshotScrollView.showsAdditionalHistory = false
        container.setNeedsLayout()
        container.layoutIfNeeded()

        let canvasSize = container.terminalView.bounds.size
        container.frame.size = CGSize(width: 700, height: 180)
        container.setNeedsLayout()
        container.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        #expect(container.terminalView.bounds.size == canvasSize)
        #expect(container.terminalGridMetrics?.columns == 80)
        #expect(container.terminalGridMetrics?.rows == 24)
        #expect(await renderer.appendHistory(
            try #require(Data(base64Encoded: Self.page)), screen: 0, generation: 1
        ) == .applied)

        container.snapshotScrollView.showsAdditionalHistory = true
        container.frame.size = CGSize(width: 390, height: 1600)
        container.setNeedsLayout()
        container.layoutIfNeeded()
        #expect(!renderer.isNearHistoryTop(screen: 0, generation: 1))
        container.snapshotScrollView.showsAdditionalHistory = false
        container.frame.size = CGSize(width: 700, height: 180)
        container.setNeedsLayout()
        container.layoutIfNeeded()

        // Selection pans are measured in the child; menu anchors are converted
        // back to the container. Verify both ends of the visible canvas.
        let terminalPoint = CGPoint(x: canvasSize.width - 1, y: canvasSize.height - 1)
        let visiblePoint = container.convert(terminalPoint, from: container.terminalView)
        #expect(container.bounds.contains(visiblePoint))
        let roundTrip = container.terminalView.convert(visiblePoint, from: container)
        #expect(abs(roundTrip.x - terminalPoint.x) < 0.001)
        #expect(abs(roundTrip.y - terminalPoint.y) < 0.001)

        // Every host row remains reachable after width fitting, including the
        // top of the oldest loaded page and the bottom of the current screen.
        try await Task.sleep(for: .milliseconds(50))
        let scroll = container.snapshotScrollView
        scroll.contentOffset = .zero
        #expect(session.readViewportText()?.contains("row-099288") == true)
        let top = container.convert(CGPoint.zero, from: container.terminalView)
        #expect(abs(top.y) < 0.1)
        scroll.contentOffset = CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height)
        #expect(session.readViewportText()?.contains("row-099999") == true)
        #expect(container.terminalGridMetrics?.columns == 80)
        #expect(container.terminalGridMetrics?.rows == 24)

        // UIKit rounds offsets to display pixels. Reaching the bottom must
        // still reveal the final row when the screen is shorter than the pane.
        container.frame.size = CGSize(width: 703, height: 900)
        container.setNeedsLayout()
        container.layoutIfNeeded()
        scroll.contentOffset = .zero
        scroll.contentOffset = CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height - 0.4)
        #expect(session.readViewportText()?.contains("row-099999") == true)
        let bottomCanvasY = scroll.contentSize.height - scroll.bounds.height
            + (scroll.bounds.height - container.terminalView.frame.height) / 2
        #expect(abs(container.terminalView.frame.minY - bottomCanvasY) < 0.5,
                "offset=\(scroll.contentOffset) content=\(scroll.contentSize) bounds=\(scroll.bounds) frame=\(container.terminalView.frame) grid=\(String(describing: container.terminalGridMetrics))")


        container.authoritativeGrid = nil
        #expect(pinch.isEnabled)
        container.setNeedsLayout()
        container.layoutIfNeeded()
        #expect(container.terminalView.transform == .identity)
        #expect(container.terminalView.frame == container.bounds)
    }

    // Generated by scripts/ghostty-paging/make-fixture.c from the pinned
    // Ghostty codec: bounded READY and its first independent primary PAGE.
    private static let ready = "R0hPU1RTTlABAAEAmQMAAM3Nvf9QABgAAAAAAAAAAAAAABcAAABPAAAAAAEAOQAAAAEBAQEAAAAACAAEIgBkAAAAAAQiAGQAAAAABCIAZAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAD/////////////////////AAEBAQEBAQEBAR0fIcxmZrW9aPDGdIGivrKUu4q+t8XIxmZmZtVOU7nKSufFR3qm2sOX2HDAserq6gAAAAAAXwAAhwAArwAA1wAA/wBfAABfXwBfhwBfrwBf1wBf/wCHAACHXwCHhwCHrwCH1wCH/wCvAACvXwCvhwCvrwCv1wCv/wDXAADXXwDXhwDXrwDX1wDX/wD/AAD/XwD/hwD/rwD/1wD//18AAF8AX18Ah18Ar18A118A/19fAF9fX19fh19fr19f119f/1+HAF+HX1+Hh1+Hr1+H11+H/1+vAF+vX1+vh1+vr1+v11+v/1/XAF/XX1/Xh1/Xr1/X11/X/1//AF//X1//h1//r1//11///4cAAIcAX4cAh4cAr4cA14cA/4dfAIdfX4dfh4dfr4df14df/4eHAIeHX4eHh4eHr4eH14eH/4evAIevX4evh4evr4ev14ev/4fXAIfXX4fXh4fXr4fX14fX/4f/AIf/X4f/h4f/r4f/14f//68AAK8AX68Ah68Ar68A168A/69fAK9fX69fh69fr69f169f/6+HAK+HX6+Hh6+Hr6+H16+H/6+vAK+vX6+vh6+vr6+v16+v/6/XAK/XX6/Xh6/Xr6/X16/X/6//AK//X6//h6//r6//16///9cAANcAX9cAh9cAr9cA19cA/9dfANdfX9dfh9dfr9df19df/9eHANeHX9eHh9eHr9eH19eH/9evANevX9evh9evr9ev19ev/9fXANfXX9fXh9fXr9fX19fX/9f/ANf/X9f/h9f/r9f/19f///8AAP8AX/8Ah/8Ar/8A1/8A//9fAP9fX/9fh/9fr/9f1/9f//+HAP+HX/+Hh/+Hr/+H1/+H//+vAP+vX/+vh/+vr/+v1/+v///XAP/XX//Xh//Xr//X1//X////AP//X///h///r///1////wgICBISEhwcHCYmJjAwMDo6OkRERE5OTlhYWGJiYmxsbHZ2doCAgIqKipSUlJ6enqioqLKysry8vMbGxtDQ0Nra2uTk5O7u7gAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACADYAAADRHMGoAAABAImGAQAAAAAAAAAXAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAAAAAAAAAAAAAAAAAAAwBABgAACoOKy1AAegAAAAAAgADAAAAgAAAACAAAAAoAcm93LTA5OTg3OQAKAHJvdy0wOTk4ODAACgByb3ctMDk5ODgxAAoAcm93LTA5OTg4MgAKAHJvdy0wOTk4ODMACgByb3ctMDk5ODg0AAoAcm93LTA5OTg4NQAKAHJvdy0wOTk4ODYACgByb3ctMDk5ODg3AAoAcm93LTA5OTg4OAAKAHJvdy0wOTk4ODkACgByb3ctMDk5ODkwAAoAcm93LTA5OTg5MQAKAHJvdy0wOTk4OTIACgByb3ctMDk5ODkzAAoAcm93LTA5OTg5NAAKAHJvdy0wOTk4OTUACgByb3ctMDk5ODk2AAoAcm93LTA5OTg5NwAKAHJvdy0wOTk4OTgACgByb3ctMDk5ODk5AAoAcm93LTA5OTkwMAAKAHJvdy0wOTk5MDEACgByb3ctMDk5OTAyAAoAcm93LTA5OTkwMwAKAHJvdy0wOTk5MDQACgByb3ctMDk5OTA1AAoAcm93LTA5OTkwNgAKAHJvdy0wOTk5MDcACgByb3ctMDk5OTA4AAoAcm93LTA5OTkwOQAKAHJvdy0wOTk5MTAACgByb3ctMDk5OTExAAoAcm93LTA5OTkxMgAKAHJvdy0wOTk5MTMACgByb3ctMDk5OTE0AAoAcm93LTA5OTkxNQAKAHJvdy0wOTk5MTYACgByb3ctMDk5OTE3AAoAcm93LTA5OTkxOAAKAHJvdy0wOTk5MTkACgByb3ctMDk5OTIwAAoAcm93LTA5OTkyMQAKAHJvdy0wOTk5MjIACgByb3ctMDk5OTIzAAoAcm93LTA5OTkyNAAKAHJvdy0wOTk5MjUACgByb3ctMDk5OTI2AAoAcm93LTA5OTkyNwAKAHJvdy0wOTk5MjgACgByb3ctMDk5OTI5AAoAcm93LTA5OTkzMAAKAHJvdy0wOTk5MzEACgByb3ctMDk5OTMyAAoAcm93LTA5OTkzMwAKAHJvdy0wOTk5MzQACgByb3ctMDk5OTM1AAoAcm93LTA5OTkzNgAKAHJvdy0wOTk5MzcACgByb3ctMDk5OTM4AAoAcm93LTA5OTkzOQAKAHJvdy0wOTk5NDAACgByb3ctMDk5OTQxAAoAcm93LTA5OTk0MgAKAHJvdy0wOTk5NDMACgByb3ctMDk5OTQ0AAoAcm93LTA5OTk0NQAKAHJvdy0wOTk5NDYACgByb3ctMDk5OTQ3AAoAcm93LTA5OTk0OAAKAHJvdy0wOTk5NDkACgByb3ctMDk5OTUwAAoAcm93LTA5OTk1MQAKAHJvdy0wOTk5NTIACgByb3ctMDk5OTUzAAoAcm93LTA5OTk1NAAKAHJvdy0wOTk5NTUACgByb3ctMDk5OTU2AAoAcm93LTA5OTk1NwAKAHJvdy0wOTk5NTgACgByb3ctMDk5OTU5AAoAcm93LTA5OTk2MAAKAHJvdy0wOTk5NjEACgByb3ctMDk5OTYyAAoAcm93LTA5OTk2MwAKAHJvdy0wOTk5NjQACgByb3ctMDk5OTY1AAoAcm93LTA5OTk2NgAKAHJvdy0wOTk5NjcACgByb3ctMDk5OTY4AAoAcm93LTA5OTk2OQAKAHJvdy0wOTk5NzAACgByb3ctMDk5OTcxAAoAcm93LTA5OTk3MgAKAHJvdy0wOTk5NzMACgByb3ctMDk5OTc0AAoAcm93LTA5OTk3NQAKAHJvdy0wOTk5NzYACgByb3ctMDk5OTc3AAoAcm93LTA5OTk3OAAKAHJvdy0wOTk5NzkACgByb3ctMDk5OTgwAAoAcm93LTA5OTk4MQAKAHJvdy0wOTk5ODIACgByb3ctMDk5OTgzAAoAcm93LTA5OTk4NAAKAHJvdy0wOTk5ODUACgByb3ctMDk5OTg2AAoAcm93LTA5OTk4NwAKAHJvdy0wOTk5ODgACgByb3ctMDk5OTg5AAoAcm93LTA5OTk5MAAKAHJvdy0wOTk5OTEACgByb3ctMDk5OTkyAAoAcm93LTA5OTk5MwAKAHJvdy0wOTk5OTQACgByb3ctMDk5OTk1AAoAcm93LTA5OTk5NgAKAHJvdy0wOTk5OTcACgByb3ctMDk5OTk4AAoAcm93LTA5OTk5OQAAAAAAAAAHAAQAAAAw1SAXG1szMQUAAAAAAOQg7wo="
    private static let page = "AwAbHgAABS9In1AATwIAAAAAgADAAAAgAAAACAAAAAoAcm93LTA5OTI4OAAKAHJvdy0wOTkyODkACgByb3ctMDk5MjkwAAoAcm93LTA5OTI5MQAKAHJvdy0wOTkyOTIACgByb3ctMDk5MjkzAAoAcm93LTA5OTI5NAAKAHJvdy0wOTkyOTUACgByb3ctMDk5Mjk2AAoAcm93LTA5OTI5NwAKAHJvdy0wOTkyOTgACgByb3ctMDk5Mjk5AAoAcm93LTA5OTMwMAAKAHJvdy0wOTkzMDEACgByb3ctMDk5MzAyAAoAcm93LTA5OTMwMwAKAHJvdy0wOTkzMDQACgByb3ctMDk5MzA1AAoAcm93LTA5OTMwNgAKAHJvdy0wOTkzMDcACgByb3ctMDk5MzA4AAoAcm93LTA5OTMwOQAKAHJvdy0wOTkzMTAACgByb3ctMDk5MzExAAoAcm93LTA5OTMxMgAKAHJvdy0wOTkzMTMACgByb3ctMDk5MzE0AAoAcm93LTA5OTMxNQAKAHJvdy0wOTkzMTYACgByb3ctMDk5MzE3AAoAcm93LTA5OTMxOAAKAHJvdy0wOTkzMTkACgByb3ctMDk5MzIwAAoAcm93LTA5OTMyMQAKAHJvdy0wOTkzMjIACgByb3ctMDk5MzIzAAoAcm93LTA5OTMyNAAKAHJvdy0wOTkzMjUACgByb3ctMDk5MzI2AAoAcm93LTA5OTMyNwAKAHJvdy0wOTkzMjgACgByb3ctMDk5MzI5AAoAcm93LTA5OTMzMAAKAHJvdy0wOTkzMzEACgByb3ctMDk5MzMyAAoAcm93LTA5OTMzMwAKAHJvdy0wOTkzMzQACgByb3ctMDk5MzM1AAoAcm93LTA5OTMzNgAKAHJvdy0wOTkzMzcACgByb3ctMDk5MzM4AAoAcm93LTA5OTMzOQAKAHJvdy0wOTkzNDAACgByb3ctMDk5MzQxAAoAcm93LTA5OTM0MgAKAHJvdy0wOTkzNDMACgByb3ctMDk5MzQ0AAoAcm93LTA5OTM0NQAKAHJvdy0wOTkzNDYACgByb3ctMDk5MzQ3AAoAcm93LTA5OTM0OAAKAHJvdy0wOTkzNDkACgByb3ctMDk5MzUwAAoAcm93LTA5OTM1MQAKAHJvdy0wOTkzNTIACgByb3ctMDk5MzUzAAoAcm93LTA5OTM1NAAKAHJvdy0wOTkzNTUACgByb3ctMDk5MzU2AAoAcm93LTA5OTM1NwAKAHJvdy0wOTkzNTgACgByb3ctMDk5MzU5AAoAcm93LTA5OTM2MAAKAHJvdy0wOTkzNjEACgByb3ctMDk5MzYyAAoAcm93LTA5OTM2MwAKAHJvdy0wOTkzNjQACgByb3ctMDk5MzY1AAoAcm93LTA5OTM2NgAKAHJvdy0wOTkzNjcACgByb3ctMDk5MzY4AAoAcm93LTA5OTM2OQAKAHJvdy0wOTkzNzAACgByb3ctMDk5MzcxAAoAcm93LTA5OTM3MgAKAHJvdy0wOTkzNzMACgByb3ctMDk5Mzc0AAoAcm93LTA5OTM3NQAKAHJvdy0wOTkzNzYACgByb3ctMDk5Mzc3AAoAcm93LTA5OTM3OAAKAHJvdy0wOTkzNzkACgByb3ctMDk5MzgwAAoAcm93LTA5OTM4MQAKAHJvdy0wOTkzODIACgByb3ctMDk5MzgzAAoAcm93LTA5OTM4NAAKAHJvdy0wOTkzODUACgByb3ctMDk5Mzg2AAoAcm93LTA5OTM4NwAKAHJvdy0wOTkzODgACgByb3ctMDk5Mzg5AAoAcm93LTA5OTM5MAAKAHJvdy0wOTkzOTEACgByb3ctMDk5MzkyAAoAcm93LTA5OTM5MwAKAHJvdy0wOTkzOTQACgByb3ctMDk5Mzk1AAoAcm93LTA5OTM5NgAKAHJvdy0wOTkzOTcACgByb3ctMDk5Mzk4AAoAcm93LTA5OTM5OQAKAHJvdy0wOTk0MDAACgByb3ctMDk5NDAxAAoAcm93LTA5OTQwMgAKAHJvdy0wOTk0MDMACgByb3ctMDk5NDA0AAoAcm93LTA5OTQwNQAKAHJvdy0wOTk0MDYACgByb3ctMDk5NDA3AAoAcm93LTA5OTQwOAAKAHJvdy0wOTk0MDkACgByb3ctMDk5NDEwAAoAcm93LTA5OTQxMQAKAHJvdy0wOTk0MTIACgByb3ctMDk5NDEzAAoAcm93LTA5OTQxNAAKAHJvdy0wOTk0MTUACgByb3ctMDk5NDE2AAoAcm93LTA5OTQxNwAKAHJvdy0wOTk0MTgACgByb3ctMDk5NDE5AAoAcm93LTA5OTQyMAAKAHJvdy0wOTk0MjEACgByb3ctMDk5NDIyAAoAcm93LTA5OTQyMwAKAHJvdy0wOTk0MjQACgByb3ctMDk5NDI1AAoAcm93LTA5OTQyNgAKAHJvdy0wOTk0MjcACgByb3ctMDk5NDI4AAoAcm93LTA5OTQyOQAKAHJvdy0wOTk0MzAACgByb3ctMDk5NDMxAAoAcm93LTA5OTQzMgAKAHJvdy0wOTk0MzMACgByb3ctMDk5NDM0AAoAcm93LTA5OTQzNQAKAHJvdy0wOTk0MzYACgByb3ctMDk5NDM3AAoAcm93LTA5OTQzOAAKAHJvdy0wOTk0MzkACgByb3ctMDk5NDQwAAoAcm93LTA5OTQ0MQAKAHJvdy0wOTk0NDIACgByb3ctMDk5NDQzAAoAcm93LTA5OTQ0NAAKAHJvdy0wOTk0NDUACgByb3ctMDk5NDQ2AAoAcm93LTA5OTQ0NwAKAHJvdy0wOTk0NDgACgByb3ctMDk5NDQ5AAoAcm93LTA5OTQ1MAAKAHJvdy0wOTk0NTEACgByb3ctMDk5NDUyAAoAcm93LTA5OTQ1MwAKAHJvdy0wOTk0NTQACgByb3ctMDk5NDU1AAoAcm93LTA5OTQ1NgAKAHJvdy0wOTk0NTcACgByb3ctMDk5NDU4AAoAcm93LTA5OTQ1OQAKAHJvdy0wOTk0NjAACgByb3ctMDk5NDYxAAoAcm93LTA5OTQ2MgAKAHJvdy0wOTk0NjMACgByb3ctMDk5NDY0AAoAcm93LTA5OTQ2NQAKAHJvdy0wOTk0NjYACgByb3ctMDk5NDY3AAoAcm93LTA5OTQ2OAAKAHJvdy0wOTk0NjkACgByb3ctMDk5NDcwAAoAcm93LTA5OTQ3MQAKAHJvdy0wOTk0NzIACgByb3ctMDk5NDczAAoAcm93LTA5OTQ3NAAKAHJvdy0wOTk0NzUACgByb3ctMDk5NDc2AAoAcm93LTA5OTQ3NwAKAHJvdy0wOTk0NzgACgByb3ctMDk5NDc5AAoAcm93LTA5OTQ4MAAKAHJvdy0wOTk0ODEACgByb3ctMDk5NDgyAAoAcm93LTA5OTQ4MwAKAHJvdy0wOTk0ODQACgByb3ctMDk5NDg1AAoAcm93LTA5OTQ4NgAKAHJvdy0wOTk0ODcACgByb3ctMDk5NDg4AAoAcm93LTA5OTQ4OQAKAHJvdy0wOTk0OTAACgByb3ctMDk5NDkxAAoAcm93LTA5OTQ5MgAKAHJvdy0wOTk0OTMACgByb3ctMDk5NDk0AAoAcm93LTA5OTQ5NQAKAHJvdy0wOTk0OTYACgByb3ctMDk5NDk3AAoAcm93LTA5OTQ5OAAKAHJvdy0wOTk0OTkACgByb3ctMDk5NTAwAAoAcm93LTA5OTUwMQAKAHJvdy0wOTk1MDIACgByb3ctMDk5NTAzAAoAcm93LTA5OTUwNAAKAHJvdy0wOTk1MDUACgByb3ctMDk5NTA2AAoAcm93LTA5OTUwNwAKAHJvdy0wOTk1MDgACgByb3ctMDk5NTA5AAoAcm93LTA5OTUxMAAKAHJvdy0wOTk1MTEACgByb3ctMDk5NTEyAAoAcm93LTA5OTUxMwAKAHJvdy0wOTk1MTQACgByb3ctMDk5NTE1AAoAcm93LTA5OTUxNgAKAHJvdy0wOTk1MTcACgByb3ctMDk5NTE4AAoAcm93LTA5OTUxOQAKAHJvdy0wOTk1MjAACgByb3ctMDk5NTIxAAoAcm93LTA5OTUyMgAKAHJvdy0wOTk1MjMACgByb3ctMDk5NTI0AAoAcm93LTA5OTUyNQAKAHJvdy0wOTk1MjYACgByb3ctMDk5NTI3AAoAcm93LTA5OTUyOAAKAHJvdy0wOTk1MjkACgByb3ctMDk5NTMwAAoAcm93LTA5OTUzMQAKAHJvdy0wOTk1MzIACgByb3ctMDk5NTMzAAoAcm93LTA5OTUzNAAKAHJvdy0wOTk1MzUACgByb3ctMDk5NTM2AAoAcm93LTA5OTUzNwAKAHJvdy0wOTk1MzgACgByb3ctMDk5NTM5AAoAcm93LTA5OTU0MAAKAHJvdy0wOTk1NDEACgByb3ctMDk5NTQyAAoAcm93LTA5OTU0MwAKAHJvdy0wOTk1NDQACgByb3ctMDk5NTQ1AAoAcm93LTA5OTU0NgAKAHJvdy0wOTk1NDcACgByb3ctMDk5NTQ4AAoAcm93LTA5OTU0OQAKAHJvdy0wOTk1NTAACgByb3ctMDk5NTUxAAoAcm93LTA5OTU1MgAKAHJvdy0wOTk1NTMACgByb3ctMDk5NTU0AAoAcm93LTA5OTU1NQAKAHJvdy0wOTk1NTYACgByb3ctMDk5NTU3AAoAcm93LTA5OTU1OAAKAHJvdy0wOTk1NTkACgByb3ctMDk5NTYwAAoAcm93LTA5OTU2MQAKAHJvdy0wOTk1NjIACgByb3ctMDk5NTYzAAoAcm93LTA5OTU2NAAKAHJvdy0wOTk1NjUACgByb3ctMDk5NTY2AAoAcm93LTA5OTU2NwAKAHJvdy0wOTk1NjgACgByb3ctMDk5NTY5AAoAcm93LTA5OTU3MAAKAHJvdy0wOTk1NzEACgByb3ctMDk5NTcyAAoAcm93LTA5OTU3MwAKAHJvdy0wOTk1NzQACgByb3ctMDk5NTc1AAoAcm93LTA5OTU3NgAKAHJvdy0wOTk1NzcACgByb3ctMDk5NTc4AAoAcm93LTA5OTU3OQAKAHJvdy0wOTk1ODAACgByb3ctMDk5NTgxAAoAcm93LTA5OTU4MgAKAHJvdy0wOTk1ODMACgByb3ctMDk5NTg0AAoAcm93LTA5OTU4NQAKAHJvdy0wOTk1ODYACgByb3ctMDk5NTg3AAoAcm93LTA5OTU4OAAKAHJvdy0wOTk1ODkACgByb3ctMDk5NTkwAAoAcm93LTA5OTU5MQAKAHJvdy0wOTk1OTIACgByb3ctMDk5NTkzAAoAcm93LTA5OTU5NAAKAHJvdy0wOTk1OTUACgByb3ctMDk5NTk2AAoAcm93LTA5OTU5NwAKAHJvdy0wOTk1OTgACgByb3ctMDk5NTk5AAoAcm93LTA5OTYwMAAKAHJvdy0wOTk2MDEACgByb3ctMDk5NjAyAAoAcm93LTA5OTYwMwAKAHJvdy0wOTk2MDQACgByb3ctMDk5NjA1AAoAcm93LTA5OTYwNgAKAHJvdy0wOTk2MDcACgByb3ctMDk5NjA4AAoAcm93LTA5OTYwOQAKAHJvdy0wOTk2MTAACgByb3ctMDk5NjExAAoAcm93LTA5OTYxMgAKAHJvdy0wOTk2MTMACgByb3ctMDk5NjE0AAoAcm93LTA5OTYxNQAKAHJvdy0wOTk2MTYACgByb3ctMDk5NjE3AAoAcm93LTA5OTYxOAAKAHJvdy0wOTk2MTkACgByb3ctMDk5NjIwAAoAcm93LTA5OTYyMQAKAHJvdy0wOTk2MjIACgByb3ctMDk5NjIzAAoAcm93LTA5OTYyNAAKAHJvdy0wOTk2MjUACgByb3ctMDk5NjI2AAoAcm93LTA5OTYyNwAKAHJvdy0wOTk2MjgACgByb3ctMDk5NjI5AAoAcm93LTA5OTYzMAAKAHJvdy0wOTk2MzEACgByb3ctMDk5NjMyAAoAcm93LTA5OTYzMwAKAHJvdy0wOTk2MzQACgByb3ctMDk5NjM1AAoAcm93LTA5OTYzNgAKAHJvdy0wOTk2MzcACgByb3ctMDk5NjM4AAoAcm93LTA5OTYzOQAKAHJvdy0wOTk2NDAACgByb3ctMDk5NjQxAAoAcm93LTA5OTY0MgAKAHJvdy0wOTk2NDMACgByb3ctMDk5NjQ0AAoAcm93LTA5OTY0NQAKAHJvdy0wOTk2NDYACgByb3ctMDk5NjQ3AAoAcm93LTA5OTY0OAAKAHJvdy0wOTk2NDkACgByb3ctMDk5NjUwAAoAcm93LTA5OTY1MQAKAHJvdy0wOTk2NTIACgByb3ctMDk5NjUzAAoAcm93LTA5OTY1NAAKAHJvdy0wOTk2NTUACgByb3ctMDk5NjU2AAoAcm93LTA5OTY1NwAKAHJvdy0wOTk2NTgACgByb3ctMDk5NjU5AAoAcm93LTA5OTY2MAAKAHJvdy0wOTk2NjEACgByb3ctMDk5NjYyAAoAcm93LTA5OTY2MwAKAHJvdy0wOTk2NjQACgByb3ctMDk5NjY1AAoAcm93LTA5OTY2NgAKAHJvdy0wOTk2NjcACgByb3ctMDk5NjY4AAoAcm93LTA5OTY2OQAKAHJvdy0wOTk2NzAACgByb3ctMDk5NjcxAAoAcm93LTA5OTY3MgAKAHJvdy0wOTk2NzMACgByb3ctMDk5Njc0AAoAcm93LTA5OTY3NQAKAHJvdy0wOTk2NzYACgByb3ctMDk5Njc3AAoAcm93LTA5OTY3OAAKAHJvdy0wOTk2NzkACgByb3ctMDk5NjgwAAoAcm93LTA5OTY4MQAKAHJvdy0wOTk2ODIACgByb3ctMDk5NjgzAAoAcm93LTA5OTY4NAAKAHJvdy0wOTk2ODUACgByb3ctMDk5Njg2AAoAcm93LTA5OTY4NwAKAHJvdy0wOTk2ODgACgByb3ctMDk5Njg5AAoAcm93LTA5OTY5MAAKAHJvdy0wOTk2OTEACgByb3ctMDk5NjkyAAoAcm93LTA5OTY5MwAKAHJvdy0wOTk2OTQACgByb3ctMDk5Njk1AAoAcm93LTA5OTY5NgAKAHJvdy0wOTk2OTcACgByb3ctMDk5Njk4AAoAcm93LTA5OTY5OQAKAHJvdy0wOTk3MDAACgByb3ctMDk5NzAxAAoAcm93LTA5OTcwMgAKAHJvdy0wOTk3MDMACgByb3ctMDk5NzA0AAoAcm93LTA5OTcwNQAKAHJvdy0wOTk3MDYACgByb3ctMDk5NzA3AAoAcm93LTA5OTcwOAAKAHJvdy0wOTk3MDkACgByb3ctMDk5NzEwAAoAcm93LTA5OTcxMQAKAHJvdy0wOTk3MTIACgByb3ctMDk5NzEzAAoAcm93LTA5OTcxNAAKAHJvdy0wOTk3MTUACgByb3ctMDk5NzE2AAoAcm93LTA5OTcxNwAKAHJvdy0wOTk3MTgACgByb3ctMDk5NzE5AAoAcm93LTA5OTcyMAAKAHJvdy0wOTk3MjEACgByb3ctMDk5NzIyAAoAcm93LTA5OTcyMwAKAHJvdy0wOTk3MjQACgByb3ctMDk5NzI1AAoAcm93LTA5OTcyNgAKAHJvdy0wOTk3MjcACgByb3ctMDk5NzI4AAoAcm93LTA5OTcyOQAKAHJvdy0wOTk3MzAACgByb3ctMDk5NzMxAAoAcm93LTA5OTczMgAKAHJvdy0wOTk3MzMACgByb3ctMDk5NzM0AAoAcm93LTA5OTczNQAKAHJvdy0wOTk3MzYACgByb3ctMDk5NzM3AAoAcm93LTA5OTczOAAKAHJvdy0wOTk3MzkACgByb3ctMDk5NzQwAAoAcm93LTA5OTc0MQAKAHJvdy0wOTk3NDIACgByb3ctMDk5NzQzAAoAcm93LTA5OTc0NAAKAHJvdy0wOTk3NDUACgByb3ctMDk5NzQ2AAoAcm93LTA5OTc0NwAKAHJvdy0wOTk3NDgACgByb3ctMDk5NzQ5AAoAcm93LTA5OTc1MAAKAHJvdy0wOTk3NTEACgByb3ctMDk5NzUyAAoAcm93LTA5OTc1MwAKAHJvdy0wOTk3NTQACgByb3ctMDk5NzU1AAoAcm93LTA5OTc1NgAKAHJvdy0wOTk3NTcACgByb3ctMDk5NzU4AAoAcm93LTA5OTc1OQAKAHJvdy0wOTk3NjAACgByb3ctMDk5NzYxAAoAcm93LTA5OTc2MgAKAHJvdy0wOTk3NjMACgByb3ctMDk5NzY0AAoAcm93LTA5OTc2NQAKAHJvdy0wOTk3NjYACgByb3ctMDk5NzY3AAoAcm93LTA5OTc2OAAKAHJvdy0wOTk3NjkACgByb3ctMDk5NzcwAAoAcm93LTA5OTc3MQAKAHJvdy0wOTk3NzIACgByb3ctMDk5NzczAAoAcm93LTA5OTc3NAAKAHJvdy0wOTk3NzUACgByb3ctMDk5Nzc2AAoAcm93LTA5OTc3NwAKAHJvdy0wOTk3NzgACgByb3ctMDk5Nzc5AAoAcm93LTA5OTc4MAAKAHJvdy0wOTk3ODEACgByb3ctMDk5NzgyAAoAcm93LTA5OTc4MwAKAHJvdy0wOTk3ODQACgByb3ctMDk5Nzg1AAoAcm93LTA5OTc4NgAKAHJvdy0wOTk3ODcACgByb3ctMDk5Nzg4AAoAcm93LTA5OTc4OQAKAHJvdy0wOTk3OTAACgByb3ctMDk5NzkxAAoAcm93LTA5OTc5MgAKAHJvdy0wOTk3OTMACgByb3ctMDk5Nzk0AAoAcm93LTA5OTc5NQAKAHJvdy0wOTk3OTYACgByb3ctMDk5Nzk3AAoAcm93LTA5OTc5OAAKAHJvdy0wOTk3OTkACgByb3ctMDk5ODAwAAoAcm93LTA5OTgwMQAKAHJvdy0wOTk4MDIACgByb3ctMDk5ODAzAAoAcm93LTA5OTgwNAAKAHJvdy0wOTk4MDUACgByb3ctMDk5ODA2AAoAcm93LTA5OTgwNwAKAHJvdy0wOTk4MDgACgByb3ctMDk5ODA5AAoAcm93LTA5OTgxMAAKAHJvdy0wOTk4MTEACgByb3ctMDk5ODEyAAoAcm93LTA5OTgxMwAKAHJvdy0wOTk4MTQACgByb3ctMDk5ODE1AAoAcm93LTA5OTgxNgAKAHJvdy0wOTk4MTcACgByb3ctMDk5ODE4AAoAcm93LTA5OTgxOQAKAHJvdy0wOTk4MjAACgByb3ctMDk5ODIxAAoAcm93LTA5OTgyMgAKAHJvdy0wOTk4MjMACgByb3ctMDk5ODI0AAoAcm93LTA5OTgyNQAKAHJvdy0wOTk4MjYACgByb3ctMDk5ODI3AAoAcm93LTA5OTgyOAAKAHJvdy0wOTk4MjkACgByb3ctMDk5ODMwAAoAcm93LTA5OTgzMQAKAHJvdy0wOTk4MzIACgByb3ctMDk5ODMzAAoAcm93LTA5OTgzNAAKAHJvdy0wOTk4MzUACgByb3ctMDk5ODM2AAoAcm93LTA5OTgzNwAKAHJvdy0wOTk4MzgACgByb3ctMDk5ODM5AAoAcm93LTA5OTg0MAAKAHJvdy0wOTk4NDEACgByb3ctMDk5ODQyAAoAcm93LTA5OTg0MwAKAHJvdy0wOTk4NDQACgByb3ctMDk5ODQ1AAoAcm93LTA5OTg0NgAKAHJvdy0wOTk4NDcACgByb3ctMDk5ODQ4AAoAcm93LTA5OTg0OQAKAHJvdy0wOTk4NTAACgByb3ctMDk5ODUxAAoAcm93LTA5OTg1MgAKAHJvdy0wOTk4NTMACgByb3ctMDk5ODU0AAoAcm93LTA5OTg1NQAKAHJvdy0wOTk4NTYACgByb3ctMDk5ODU3AAoAcm93LTA5OTg1OAAKAHJvdy0wOTk4NTkACgByb3ctMDk5ODYwAAoAcm93LTA5OTg2MQAKAHJvdy0wOTk4NjIACgByb3ctMDk5ODYzAAoAcm93LTA5OTg2NAAKAHJvdy0wOTk4NjUACgByb3ctMDk5ODY2AAoAcm93LTA5OTg2NwAKAHJvdy0wOTk4NjgACgByb3ctMDk5ODY5AAoAcm93LTA5OTg3MAAKAHJvdy0wOTk4NzEACgByb3ctMDk5ODcyAAoAcm93LTA5OTg3MwAKAHJvdy0wOTk4NzQACgByb3ctMDk5ODc1AAoAcm93LTA5OTg3NgAKAHJvdy0wOTk4NzcACgByb3ctMDk5ODc4AAAAAA=="
}
#endif
