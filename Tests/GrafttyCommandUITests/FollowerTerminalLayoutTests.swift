import CoreGraphics
import Testing
@testable import GrafttyCommandUI

@Suite("@spec OWN-2.7: While a terminal follows another display, the application shall calculate canvas placement, scroll extent, and history row height from one presentation scale, center unused horizontal space, and preserve the native grid when zooming.")
struct FollowerTerminalLayoutTests {
    @Test func narrowCanvasIsCenteredAboveItsHistory() {
        let canvas = FollowerTerminalLayout.Layout(size: CGSize(width: 300, height: 200), scale: 2)
        let presentation = canvas.presentation(
            viewport: CGSize(width: 600, height: 400), nativeRowHeight: 10,
            historyRows: 50, maximumBaseScale: 1
        )
        #expect(presentation.scale == 1)
        #expect(presentation.rowHeight == 10)
        #expect(presentation.contentSize == CGSize(width: 600, height: 900))
        #expect(presentation.screenFrame(at: 50) == CGRect(x: 150, y: 700, width: 300, height: 200))
        #expect(presentation.screenFrame(at: 10).minX == 150)
    }

    @Test func zoomChangesPresentationWithoutChangingNativeCanvas() {
        let canvas = FollowerTerminalLayout.Layout(size: CGSize(width: 800, height: 400), scale: 0.5)
        let presentation = canvas.presentation(
            viewport: CGSize(width: 400, height: 600), nativeRowHeight: 20,
            historyRows: 50, zoomScale: 3
        )
        #expect(canvas.size == CGSize(width: 800, height: 400))
        #expect(presentation.scale == 1.5)
        #expect(presentation.rowHeight == 30)
        #expect(presentation.contentSize == CGSize(width: 1200, height: 2100))
        #expect(presentation.screenFrame(at: 50) == CGRect(x: 0, y: 1500, width: 1200, height: 600))
    }

    @Test func zoomPreservesAnAnchorAcrossCenteredAndScrollableCanvases() {
        let canvas = FollowerTerminalLayout.Layout(size: CGSize(width: 300, height: 200), scale: 2)
        let viewport = CGSize(width: 600, height: 400)
        let original = canvas.presentation(viewport: viewport, nativeRowHeight: 10,
                                           historyRows: 0, maximumBaseScale: 1)
        let zoomed = canvas.presentation(viewport: viewport, nativeRowHeight: 10,
                                         historyRows: 0, zoomScale: 3, maximumBaseScale: 1)
        let offset = zoomed.anchoredOffset(
            from: original.screenFrame(at: 0), oldOffset: .zero,
            to: zoomed.screenFrame(at: 0), anchor: CGPoint(x: 300, y: 300)
        )
        #expect(offset == CGPoint(x: 150, y: 0))
        #expect(original.anchoredOffset(
            from: zoomed.screenFrame(at: 0), oldOffset: offset,
            to: original.screenFrame(at: 0), anchor: CGPoint(x: 300, y: 300)
        ) == .zero)
    }
}
