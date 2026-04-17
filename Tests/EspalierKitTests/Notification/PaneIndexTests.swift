import Testing
@testable import EspalierKit

@Suite("Pane Index Resolution")
struct PaneIndexTests {
    @Test func emptyTreeReturnsNil() {
        let tree = SplitTree(root: nil)
        #expect(tree.leaf(atPaneID: 1) == nil)
    }

    @Test func singleLeafPaneID1Resolves() {
        let id = TerminalID()
        let tree = SplitTree(root: .leaf(id))
        #expect(tree.leaf(atPaneID: 1) == id)
        #expect(tree.leaf(atPaneID: 0) == nil)
        #expect(tree.leaf(atPaneID: 2) == nil)
    }

    @Test func splitTreeResolvesInAllLeavesOrder() {
        let a = TerminalID()
        let b = TerminalID()
        let c = TerminalID()
        // Tree: (a | (b / c)) — allLeaves order is [a, b, c].
        let inner = SplitTree.Node.split(.init(direction: .vertical, ratio: 0.5, left: .leaf(b), right: .leaf(c)))
        let root = SplitTree.Node.split(.init(direction: .horizontal, ratio: 0.5, left: .leaf(a), right: inner))
        let tree = SplitTree(root: root)

        #expect(tree.allLeaves == [a, b, c])
        #expect(tree.leaf(atPaneID: 1) == a)
        #expect(tree.leaf(atPaneID: 2) == b)
        #expect(tree.leaf(atPaneID: 3) == c)
        #expect(tree.leaf(atPaneID: 4) == nil)
        #expect(tree.leaf(atPaneID: -1) == nil)
    }
}
