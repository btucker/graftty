#if canImport(UIKit)
import CoreGraphics
import Testing
@testable import GrafttyMobileKit

@Suite
struct TerminalWidthLayoutTests {

    @Test
    func nilServerColsFitsContainer() {
        let d = TerminalWidthLayout.decide(
            containerWidth: 390,
            serverCols: nil,
            cellWidth: 6.24
        )
        #expect(d == .fits)
    }

    @Test
    func zeroServerColsFitsContainer() {
        let d = TerminalWidthLayout.decide(
            containerWidth: 390,
            serverCols: 0,
            cellWidth: 6.24
        )
        #expect(d == .fits)
    }

    @Test
    func serverColsFittingVisibleStaysInContainer() {
        // 80 cols × 6.24 = 499.2pt, less than 800pt container → no scroll.
        let d = TerminalWidthLayout.decide(
            containerWidth: 800,
            serverCols: 80,
            cellWidth: 6.24
        )
        #expect(d == .fits)
    }

    @Test
    func serverColsExceedingVisibleProducesScrollFrame() {
        // 120 cols × 6.24 = 748.8pt on a 390pt iPhone — must scroll, and
        // the frame width MUST be exactly serverCols × cellWidth so that
        // libghostty's VT parser runs at serverCols columns (otherwise it
        // wraps text at its own narrower internal grid).
        let d = TerminalWidthLayout.decide(
            containerWidth: 390,
            serverCols: 120,
            cellWidth: 6.24
        )
        #expect(d == .scrollable(frameWidth: 120 * 6.24))
    }

    @Test
    func frameWidthUsesCallerSuppliedCellWidth() {
        let realCell: CGFloat = 6.72
        let d = TerminalWidthLayout.decide(
            containerWidth: 390,
            serverCols: 100,
            cellWidth: realCell
        )
        #expect(d == .scrollable(frameWidth: 100 * realCell))
    }
}
#endif
