import GrafttyProtocol
import SwiftUI
import Testing
@testable import GrafttyCommandUI

@MainActor
@Suite("Shared proportional split view")
struct ProportionalSplitViewTests {
    @Test("""
@spec IPAD-2.2: When `MultiPaneDetailView` renders a `.split(.horizontal, ratio, left, right)`, the application shall render an `HStack` with the two children proportionally sized by `ratio` and a draggable `Divider` between them.
""")
    func ipad_2_2_horizontalSplitUsesSharedProportionalRenderer() {
        let view = ProportionalSplitView(
            direction: PaneLayoutNode.SplitAxis.horizontal,
            ratio: .constant(0.37),
            first: EmptyView(),
            second: EmptyView(),
            onDragEnd: { _ in }
        )

        #expect(view.direction == .horizontal)
        #expect(view.ratio == 0.37)
        #expect(ProportionalSplitView<EmptyView, EmptyView>.clampedRatio(
            position: 1,
            total: 2
        ) == 0.5)
    }

    @Test("""
@spec IPAD-2.3: When `MultiPaneDetailView` renders a `.split(.vertical, ratio, left, right)`, the application shall render a `VStack` with the two children proportionally sized by `ratio` and a draggable `Divider` between them.
""")
    func ipad_2_3_verticalSplitUsesSharedProportionalRenderer() {
        let view = ProportionalSplitView(
            direction: PaneLayoutNode.SplitAxis.vertical,
            ratio: .constant(0.61),
            first: EmptyView(),
            second: EmptyView(),
            onDragEnd: { _ in }
        )

        #expect(view.direction == .vertical)
        #expect(view.ratio == 0.61)
        #expect(ProportionalSplitView<EmptyView, EmptyView>.clampedRatio(
            position: -10,
            total: 100
        ) == 0.1)
        #expect(ProportionalSplitView<EmptyView, EmptyView>.clampedRatio(
            position: 110,
            total: 100
        ) == 0.9)
    }
}
