import Testing
@testable import GrafttyMobileKit
import GrafttyProtocol

@Suite("@spec IOS-4.14: When a worktree's pane layout is a single leaf, the worktree-detail screen shall render a static labeled tile rather than a live terminal preview, and shall not open a preview WebSocket for that pane.")
struct WorktreeDetailSinglePaneTests {
    @Test
    func leafIsRecognizedAsSinglePane() {
        #expect(PaneLayoutNode.leaf(sessionName: "only", title: "Only").isLeaf)
    }

    @Test
    func splitIsNotASinglePane() {
        let layout = PaneLayoutNode.split(
            direction: .horizontal,
            ratio: 0.5,
            left: .leaf(sessionName: "left", title: "Left"),
            right: .leaf(sessionName: "right", title: "Right")
        )
        #expect(!layout.isLeaf)
    }
}
