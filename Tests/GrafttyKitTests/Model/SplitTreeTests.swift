import Foundation
import Testing
@testable import GrafttyKit

@Suite("SplitTree Tests")
struct SplitTreeTests {

    @Test func singleLeaf() {
        let id = TerminalID()
        let tree = SplitTree(root: .leaf(id))
        #expect(tree.root != nil)
        if case .leaf(let leafID) = tree.root {
            #expect(leafID == id)
        } else {
            Issue.record("Expected leaf node")
        }
    }

    @Test func horizontalSplit() {
        let left = TerminalID()
        let right = TerminalID()
        let tree = SplitTree(root: .split(.init(
            direction: .horizontal,
            ratio: 0.5,
            left: .leaf(left),
            right: .leaf(right)
        )))
        #expect(tree.leafCount == 2)
    }

    @Test func insertSplitAtLeaf() {
        let original = TerminalID()
        let tree = SplitTree(root: .leaf(original))
        let newID = TerminalID()
        let updated = tree.inserting(newID, at: original, direction: .horizontal)
        #expect(updated.leafCount == 2)
        guard case .split(let s) = updated.root else {
            Issue.record("expected a split at the root")
            return
        }
        // `inserting` places the new leaf on the right — this distinguishes it
        // from `insertingBefore`, which does the opposite.
        #expect(s.left == .leaf(original))
        #expect(s.right == .leaf(newID))
    }

    @Test func insertBeforeSplitAtLeaf() {
        let original = TerminalID()
        let tree = SplitTree(root: .leaf(original))
        let newID = TerminalID()
        let updated = tree.insertingBefore(newID, at: original, direction: .vertical)
        #expect(updated.leafCount == 2)
        guard case .split(let s) = updated.root else {
            Issue.record("expected a split at the root")
            return
        }
        // `insertingBefore` places the new leaf on the *left/top* — that's what
        // Split Left / Split Up rely on.
        #expect(s.left == .leaf(newID))
        #expect(s.right == .leaf(original))
        #expect(s.direction == .vertical)
    }

    @Test func removeLeaf() {
        let left = TerminalID()
        let right = TerminalID()
        let tree = SplitTree(root: .split(.init(
            direction: .horizontal,
            ratio: 0.5,
            left: .leaf(left),
            right: .leaf(right)
        )))
        let updated = tree.removing(left)
        #expect(updated.leafCount == 1)
        if case .leaf(let remaining) = updated.root {
            #expect(remaining == right)
        } else {
            Issue.record("Expected single leaf after removal")
        }
    }

    @Test func removeLastLeafReturnsNilRoot() {
        let id = TerminalID()
        let tree = SplitTree(root: .leaf(id))
        let updated = tree.removing(id)
        #expect(updated.root == nil)
    }

    @Test func allLeaves() {
        let a = TerminalID()
        let b = TerminalID()
        let c = TerminalID()
        let tree = SplitTree(root: .split(.init(
            direction: .horizontal,
            ratio: 0.5,
            left: .leaf(a),
            right: .split(.init(
                direction: .vertical,
                ratio: 0.5,
                left: .leaf(b),
                right: .leaf(c)
            ))
        )))
        let leaves = tree.allLeaves
        #expect(leaves.count == 3)
        #expect(leaves.contains(a))
        #expect(leaves.contains(b))
        #expect(leaves.contains(c))
    }

    @Test func positionOfSoleLeafIsNil() {
        let id = TerminalID()
        let tree = SplitTree(root: .leaf(id))
        #expect(tree.position(of: id) == nil)
    }

    @Test func positionOfLeftChild() {
        let left = TerminalID()
        let right = TerminalID()
        let tree = SplitTree(root: .split(.init(
            direction: .horizontal,
            ratio: 0.5,
            left: .leaf(left),
            right: .leaf(right)
        )))
        let pos = tree.position(of: left)
        #expect(pos?.anchorID == right)
        #expect(pos?.direction == .horizontal)
        #expect(pos?.placement == .before)
    }

    @Test func positionOfRightChildInNestedSplit() {
        let a = TerminalID()
        let b = TerminalID()
        let c = TerminalID()
        // H-split: a | V-split(b over c)
        let tree = SplitTree(root: .split(.init(
            direction: .horizontal,
            ratio: 0.5,
            left: .leaf(a),
            right: .split(.init(
                direction: .vertical,
                ratio: 0.5,
                left: .leaf(b),
                right: .leaf(c)
            ))
        )))
        let pos = tree.position(of: c)
        #expect(pos?.anchorID == b)
        #expect(pos?.direction == .vertical)
        #expect(pos?.placement == .after)
    }

    @Test func positionSurvivesRemoveAndReinsert() {
        let a = TerminalID()
        let b = TerminalID()
        let c = TerminalID()
        let tree = SplitTree(root: .split(.init(
            direction: .horizontal,
            ratio: 0.5,
            left: .leaf(a),
            right: .split(.init(
                direction: .vertical,
                ratio: 0.5,
                left: .leaf(b),
                right: .leaf(c)
            ))
        )))
        guard let pos = tree.position(of: b) else {
            Issue.record("expected a position for b")
            return
        }
        let pruned = tree.removing(b)
        #expect(pruned.allLeaves.contains(pos.anchorID))

        let restored: SplitTree
        switch pos.placement {
        case .before:
            restored = pruned.insertingBefore(b, at: pos.anchorID, direction: pos.direction)
        case .after:
            restored = pruned.inserting(b, at: pos.anchorID, direction: pos.direction)
        }
        #expect(restored.allLeaves.count == 3)
        let restoredPos = restored.position(of: b)
        #expect(restoredPos?.anchorID == pos.anchorID)
        #expect(restoredPos?.direction == pos.direction)
        #expect(restoredPos?.placement == pos.placement)
    }

    @Test func codableRoundTrip() throws {
        let a = TerminalID()
        let b = TerminalID()
        let tree = SplitTree(root: .split(.init(
            direction: .horizontal,
            ratio: 0.6,
            left: .leaf(a),
            right: .leaf(b)
        )))
        let data = try JSONEncoder().encode(tree)
        let decoded = try JSONDecoder().decode(SplitTree.self, from: data)
        #expect(decoded.leafCount == 2)
        #expect(decoded.allLeaves.contains(a))
        #expect(decoded.allLeaves.contains(b))
    }
}
