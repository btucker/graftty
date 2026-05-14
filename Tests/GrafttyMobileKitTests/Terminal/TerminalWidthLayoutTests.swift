#if canImport(UIKit)
import CoreGraphics
import Testing
@testable import GrafttyMobileKit

@Suite("""
@spec IOS-5.6: While the iOS client is not the size-leader (before the first keystroke on this session per `IOS-6.5`) and the server-announced grid's column count exceeds what fits in the device's container at libghostty's current cell width, the application shall wrap the terminal pane in a horizontal `ScrollView` whose inner frame width equals `serverCols × cellWidthPoints`. `cellWidthPoints` shall be taken from the `cellWidthPixels` field of libghostty's resize-callback viewport (divided by the display scale) — not a static font-aspect estimate — so libghostty's VT parser runs at exactly `serverCols` columns and server output flows through without internal line-wrap. Before the first viewport callback delivers a non-zero cell width, an overshooting fallback shall be used so the scroll frame errs toward too-wide (extra blank cells) rather than too-narrow (wrapped lines).
""")
struct TerminalWidthLayoutTests {

    @Test
    func nilServerColsFitsContainer() {
        let d = TerminalWidthLayout.decide(
            containerWidth: 390,
            serverCols: nil,
            cellWidth: 6.24,
            isLeader: false
        )
        #expect(d == .fits)
    }

    @Test
    func zeroServerColsFitsContainer() {
        let d = TerminalWidthLayout.decide(
            containerWidth: 390,
            serverCols: 0,
            cellWidth: 6.24,
            isLeader: false
        )
        #expect(d == .fits)
    }

    @Test
    func serverColsFittingVisibleStaysInContainer() {
        // 80 cols × 6.24 = 499.2pt, less than 800pt container → no scroll.
        let d = TerminalWidthLayout.decide(
            containerWidth: 800,
            serverCols: 80,
            cellWidth: 6.24,
            isLeader: false
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
            cellWidth: 6.24,
            isLeader: false
        )
        #expect(d == .scrollable(frameWidth: 120 * 6.24))
    }

    @Test
    func frameWidthUsesCallerSuppliedCellWidth() {
        let realCell: CGFloat = 6.72
        let d = TerminalWidthLayout.decide(
            containerWidth: 390,
            serverCols: 100,
            cellWidth: realCell,
            isLeader: false
        )
        #expect(d == .scrollable(frameWidth: 100 * realCell))
    }

    @Test
    func leaderAlwaysFitsContainerDespiteStaleServerCols() {
        // Mid-pinch-zoom-in: cellWidth has just grown from 10 → 12pt so
        // libghostty's resize callback already shrank cols from 39 → 32.
        // iOS, as leader, has sent resize(32) to the server, but the
        // server's grid envelope hasn't round-tripped yet — serverCols
        // is still the pre-pinch 39. Returning .scrollable here would
        // wrap the pane in a 468pt frame, pin libghostty back to 39
        // cols, and (when the prior decision was .fits) remount
        // UITerminalView — discarding the pinch-incremented font size.
        let d = TerminalWidthLayout.decide(
            containerWidth: 390,
            serverCols: 39,
            cellWidth: 12,
            isLeader: true
        )
        #expect(d == .fits)
    }
}
#endif
