import Foundation
import Testing
@testable import GrafttyKit

/// TERM-7.3: Cmd+Opt+Arrow pane navigation uses the split tree's spatial
/// layout. Tree-order traversal (old `navigatePane`) silently aliased
/// `.down` to `.right`, so in a `[A | [B / C]]` layout pressing "down"
/// from A jumped to B instead of staying in A (or going nowhere — A has
/// no pane below it). These tests pin the spatial contract.
@Suite("""
SplitTree spatial navigation

@spec TERM-7.3: When the user navigates between panes via directional keyboard (Cmd+Opt+Arrow, or libghostty's `goto_split` left/right/up/down actions), the application shall move focus to the leaf that is spatially adjacent in the requested direction — determined by walking the split tree from the focused leaf up to the nearest ancestor whose split orientation matches the motion axis and whose source-side subtree contains the current leaf, then descending into the opposite subtree's near-edge leaf. If no such ancestor exists, the application shall leave focus unchanged rather than wrapping around the tree in DFS order.
""")
struct SplitTreeSpatialNeighborTests {

    @Test func rightInSimpleHorizontalSplit() {
        let a = TerminalID()
        let b = TerminalID()
        let tree = SplitTree(root: .split(.init(
            direction: .horizontal, ratio: 0.5,
            left: .leaf(a), right: .leaf(b)
        )))
        #expect(tree.spatialNeighbor(of: a, direction: .right) == b)
        #expect(tree.spatialNeighbor(of: a, direction: .left) == nil)
        #expect(tree.spatialNeighbor(of: a, direction: .up) == nil)
        #expect(tree.spatialNeighbor(of: a, direction: .down) == nil)
        #expect(tree.spatialNeighbor(of: b, direction: .left) == a)
        #expect(tree.spatialNeighbor(of: b, direction: .right) == nil)
    }

    @Test func downInVerticalSplit() {
        let a = TerminalID()
        let b = TerminalID()
        let tree = SplitTree(root: .split(.init(
            direction: .vertical, ratio: 0.5,
            left: .leaf(a), right: .leaf(b)
        )))
        #expect(tree.spatialNeighbor(of: a, direction: .down) == b)
        #expect(tree.spatialNeighbor(of: a, direction: .up) == nil)
        #expect(tree.spatialNeighbor(of: a, direction: .left) == nil)
        #expect(tree.spatialNeighbor(of: a, direction: .right) == nil)
        #expect(tree.spatialNeighbor(of: b, direction: .up) == a)
        #expect(tree.spatialNeighbor(of: b, direction: .down) == nil)
    }

    /// Layout:
    ///     +---+---+
    ///     |   | B |
    ///     | A +---+
    ///     |   | C |
    ///     +---+---+
    ///
    /// Root is horizontal. Right subtree is a vertical split (B on top, C below).
    @Test func navigationIntoNestedVerticalFromLeftOfHorizontal() {
        let a = TerminalID()
        let b = TerminalID()
        let c = TerminalID()
        let rightSubtree: SplitTree.Node = .split(.init(
            direction: .vertical, ratio: 0.5,
            left: .leaf(b), right: .leaf(c)
        ))
        let tree = SplitTree(root: .split(.init(
            direction: .horizontal, ratio: 0.5,
            left: .leaf(a), right: rightSubtree
        )))

        // From A, .right lands on B (top-left of the right subtree — the
        // leaf you reach by descending into the "near" side of each split).
        #expect(tree.spatialNeighbor(of: a, direction: .right) == b)
        // No spatial neighbor above/below A — A lives in a horizontal split only.
        #expect(tree.spatialNeighbor(of: a, direction: .up) == nil)
        #expect(tree.spatialNeighbor(of: a, direction: .down) == nil)

        // From B / C going left — the nearest ancestor horizontal split
        // has them on the right side, so both route back to A.
        #expect(tree.spatialNeighbor(of: b, direction: .left) == a)
        #expect(tree.spatialNeighbor(of: c, direction: .left) == a)

        // Vertical-sibling traversal within the right subtree.
        #expect(tree.spatialNeighbor(of: b, direction: .down) == c)
        #expect(tree.spatialNeighbor(of: c, direction: .up) == b)

        // B has no up-neighbor (it's at the top of its vertical split and
        // the enclosing horizontal split doesn't give vertical motion).
        #expect(tree.spatialNeighbor(of: b, direction: .up) == nil)
        #expect(tree.spatialNeighbor(of: c, direction: .down) == nil)
        // B has no right-neighbor, C has no right-neighbor.
        #expect(tree.spatialNeighbor(of: b, direction: .right) == nil)
        #expect(tree.spatialNeighbor(of: c, direction: .right) == nil)
    }

    /// Layout:
    ///     +---+---+
    ///     | A | B |
    ///     +---+---+
    ///     |   C   |
    ///     +-------+
    ///
    /// Root is vertical. Top subtree is a horizontal split.
    @Test func navigationAcrossMixedSplitTypes() {
        let a = TerminalID()
        let b = TerminalID()
        let c = TerminalID()
        let topSubtree: SplitTree.Node = .split(.init(
            direction: .horizontal, ratio: 0.5,
            left: .leaf(a), right: .leaf(b)
        ))
        let tree = SplitTree(root: .split(.init(
            direction: .vertical, ratio: 0.5,
            left: topSubtree, right: .leaf(c)
        )))

        // Horizontal sibling traversal within the top subtree.
        #expect(tree.spatialNeighbor(of: a, direction: .right) == b)
        #expect(tree.spatialNeighbor(of: b, direction: .left) == a)

        // Both A and B can go down into C — that's the enclosing vertical split.
        #expect(tree.spatialNeighbor(of: a, direction: .down) == c)
        #expect(tree.spatialNeighbor(of: b, direction: .down) == c)
        // C going up lands on A (the "first leaf you meet" descending into
        // the top subtree — the convention is left-branch-first, so A).
        #expect(tree.spatialNeighbor(of: c, direction: .up) == a)

        // C has no horizontal neighbor — it's the only leaf at its row.
        #expect(tree.spatialNeighbor(of: c, direction: .left) == nil)
        #expect(tree.spatialNeighbor(of: c, direction: .right) == nil)
    }

    @Test func singleLeafHasNoNeighborsInAnyDirection() {
        let a = TerminalID()
        let tree = SplitTree(root: .leaf(a))
        for direction: SplitTree.SpatialDirection in [.left, .right, .up, .down] {
            #expect(tree.spatialNeighbor(of: a, direction: direction) == nil)
        }
    }

    @Test func emptyTreeReturnsNil() {
        let tree = SplitTree(root: nil)
        #expect(tree.spatialNeighbor(of: TerminalID(), direction: .right) == nil)
    }

    @Test func unknownTerminalReturnsNil() {
        let present = TerminalID()
        let absent = TerminalID()
        let tree = SplitTree(root: .leaf(present))
        #expect(tree.spatialNeighbor(of: absent, direction: .right) == nil)
    }
}
