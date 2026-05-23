#if canImport(UIKit)
import CoreGraphics
import Testing
@testable import GrafttyMobileKit

@Suite("""
@spec IOS-5.6: While the iOS client is not the size-leader (before the first leadership-claim event per `IOS-6.5`) and the server-announced grid's column count exceeds what fits in the device's container at the configured (iOS-scaled) font size, the application shall override the terminal controller's font size so that `serverCols × cellWidth ≤ containerWidth`, render the pane at the full container width with no horizontal `ScrollView`, and never wrap a line. The override font size shall be computed as `(containerWidth / serverCols) × safetyScale / monospaceAspect`, mirroring `PanePreviewFontSizing`. When `serverCols` is not yet known, the application shall leave the base config font in place.
""")
struct TerminalWidthLayoutTests {

    @Test
    func leaderUsesConfigFont() {
        let d = TerminalWidthLayout.decide(
            containerWidth: 390,
            serverCols: 120,
            configFontSize: 11,
            isLeader: true
        )
        #expect(d == .useConfigFont)
    }

    @Test
    func nilServerColsUsesConfigFont() {
        let d = TerminalWidthLayout.decide(
            containerWidth: 390,
            serverCols: nil,
            configFontSize: 11,
            isLeader: false
        )
        #expect(d == .useConfigFont)
    }

    @Test
    func zeroServerColsUsesConfigFont() {
        let d = TerminalWidthLayout.decide(
            containerWidth: 390,
            serverCols: 0,
            configFontSize: 11,
            isLeader: false
        )
        #expect(d == .useConfigFont)
    }

    @Test
    func zeroContainerWidthUsesConfigFont() {
        let d = TerminalWidthLayout.decide(
            containerWidth: 0,
            serverCols: 80,
            configFontSize: 11,
            isLeader: false
        )
        #expect(d == .useConfigFont)
    }

    @Test
    func serverColsThatAlreadyFitUseConfigFont() {
        // 80 cols × (11pt × 0.6 aspect) = 528pt. Container is 800pt; the
        // target font computed from 800/80×0.95/0.6 ≈ 15.83pt is larger
        // than the 11pt config, so no override needed.
        let d = TerminalWidthLayout.decide(
            containerWidth: 800,
            serverCols: 80,
            configFontSize: 11,
            isLeader: false
        )
        #expect(d == .useConfigFont)
    }

    @Test
    func overflowProducesFitFontMatchingPreviewMath() {
        // 120 cols on a 390pt iPhone with an 11pt config:
        //   target = 390/120 × 0.95 / 0.6 ≈ 5.146pt
        // Mirrors PanePreviewFontSizing exactly.
        let d = TerminalWidthLayout.decide(
            containerWidth: 390,
            serverCols: 120,
            configFontSize: 11,
            isLeader: false
        )
        let expected: Float = Float((390.0 / 120.0) * 0.95 / 0.6)
        switch d {
        case .useConfigFont:
            Issue.record("Expected .fitFont")
        case let .fitFont(p):
            #expect(abs(p - expected) < 0.0001)
        }
    }

    @Test
    func extremelyNarrowFitClampsToMinimum() {
        // Pathological: container 30pt, 200 cols → ~0.24pt, clamps to 2.
        let d = TerminalWidthLayout.decide(
            containerWidth: 30,
            serverCols: 200,
            configFontSize: 11,
            isLeader: false
        )
        #expect(d == .fitFont(pointSize: 2))
    }
}
#endif
