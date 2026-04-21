import Testing
import Foundation
import CoreGraphics
@testable import GrafttyKit

@Suite("SplitTree — resizing")
struct SplitTreeResizeTests {
    private func horizontalTree() -> (SplitTree, TerminalID, TerminalID) {
        // a | b, 50/50 horizontal split (left / right). `.horizontal`
        // direction = vertical divider separating left/right children.
        let a = TerminalID(); let b = TerminalID()
        let tree = SplitTree(root: .leaf(a))
            .inserting(b, at: a, direction: .horizontal)
        return (tree, a, b)
    }

    @Test func resizeRightGrowsLeftChild() throws {
        let (tree, a, _) = horizontalTree()
        // Ratio starts 0.5; +100px on 1000px-wide split → +0.1 → 0.6.
        let next = try tree.resizing(
            target: a,
            direction: .right,
            pixels: 100,
            ancestorBounds: CGRect(x: 0, y: 0, width: 1000, height: 600)
        )
        let ratio = next.ratioOfSplit(containing: a)
        #expect(abs(ratio - 0.6) < 1e-6, "expected 0.6, got \(ratio)")
    }

    @Test func resizeClampsAtLowerBound() throws {
        let (tree, a, _) = horizontalTree()
        let next = try tree.resizing(
            target: a,
            direction: .left,
            pixels: 10_000,
            ancestorBounds: CGRect(x: 0, y: 0, width: 1000, height: 600)
        )
        #expect(abs(next.ratioOfSplit(containing: a) - 0.1) < 1e-6)
    }

    @Test func resizeClampsAtUpperBound() throws {
        let (tree, a, _) = horizontalTree()
        let next = try tree.resizing(
            target: a,
            direction: .right,
            pixels: 10_000,
            ancestorBounds: CGRect(x: 0, y: 0, width: 1000, height: 600)
        )
        #expect(abs(next.ratioOfSplit(containing: a) - 0.9) < 1e-6)
    }

    @Test func resizeThrowsWhenNoMatchingOrientationAncestor() throws {
        let (tree, a, _) = horizontalTree()
        #expect(throws: SplitTree.SplitTreeError.noMatchingAncestor) {
            try tree.resizing(
                target: a,
                direction: .up,  // needs vertical ancestor; tree has only horizontal
                pixels: 50,
                ancestorBounds: CGRect(x: 0, y: 0, width: 1000, height: 600)
            )
        }
    }

    @Test func resizeClearsZoom() throws {
        let (tree, a, _) = horizontalTree()
        let zoomed = tree.withZoom(a)
        let next = try zoomed.resizing(
            target: a,
            direction: .right,
            pixels: 10,
            ancestorBounds: CGRect(x: 0, y: 0, width: 1000, height: 600)
        )
        #expect(next.zoomed == nil)
    }

    @Test func resizeWalksUpToMatchingAncestor() throws {
        // Build: horizontal(a | vertical(b / c)).
        // Resizing `b` with .right should adjust the outer horizontal split's
        // ratio, not the inner vertical.
        let a = TerminalID(); let b = TerminalID(); let c = TerminalID()
        var tree = SplitTree(root: .leaf(a))
            .inserting(b, at: a, direction: .horizontal)
        tree = tree.inserting(c, at: b, direction: .vertical)

        let next = try tree.resizing(
            target: b,
            direction: .right,
            pixels: 100,
            ancestorBounds: CGRect(x: 0, y: 0, width: 1000, height: 600)
        )
        // After resize: outer horizontal ratio moved from 0.5 to 0.6.
        // Inner vertical (b / c) ratio unchanged.
        let rootRatio = next.ratioOfOutermostSplit()
        #expect(abs(rootRatio - 0.6) < 1e-6, "outer split should be 0.6, got \(rootRatio)")
    }
}
