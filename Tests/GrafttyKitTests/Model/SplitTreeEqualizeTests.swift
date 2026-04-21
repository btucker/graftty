import Testing
import Foundation
import CoreGraphics
@testable import GrafttyKit

@Suite("SplitTree — equalizing")
struct SplitTreeEqualizeTests {
    @Test func equalizeResetsAllSplitRatiosToHalf() throws {
        let a = TerminalID(); let b = TerminalID(); let c = TerminalID()
        var tree = SplitTree(root: .leaf(a))
            .inserting(b, at: a, direction: .horizontal)
            .inserting(c, at: b, direction: .vertical)
        // Push the outer split off-center via resizing, then equalize.
        tree = try tree.resizing(
            target: a,
            direction: .right,
            pixels: 100,
            ancestorBounds: CGRect(x: 0, y: 0, width: 1000, height: 600)
        )
        let equalized = tree.equalizing()
        equalized.forEachSplit { #expect(abs($0.ratio - 0.5) < 1e-9) }
    }

    @Test func equalizeClearsZoom() {
        let a = TerminalID(); let b = TerminalID()
        let tree = SplitTree(root: .leaf(a))
            .inserting(b, at: a, direction: .horizontal)
            .withZoom(a)
        #expect(tree.equalizing().zoomed == nil)
    }

    @Test func equalizeIsNoOpForSingleLeaf() {
        let a = TerminalID()
        let tree = SplitTree(root: .leaf(a))
        // No splits to equalize; just a no-op.
        let next = tree.equalizing()
        #expect(next.root == tree.root)
        #expect(next.zoomed == nil)
    }
}
