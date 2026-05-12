import Testing
@testable import GrafttyMobileKit
import GrafttyProtocol

@Suite("@spec IOS-4.17: When the user selects a worktree from the picker (`IOS-4.1`) and that worktree's pane layout is a single leaf, the application shall push the fullscreen terminal for that pane directly onto the navigation stack, bypassing the worktree-detail screen (`IOS-4.10`). The system edge-swipe-back gesture and the in-app back button (`IOS-5.5`) shall return the user to the worktree picker.")
struct MobileNavigationDecisionTests {

    @Test
    func singleLeafLayoutDecidesToSession() {
        let layout: PaneLayoutNode = .leaf(
            sessionName: "abc",
            title: "Sass",
            attentionText: nil
        )
        #expect(
            MobileNavigationDecision.decide(layout: layout)
                == .session(sessionName: "abc", title: "Sass")
        )
    }

    @Test
    func singleLeafWithEmptyTitleCarriesTheEmptyTitle() {
        let layout: PaneLayoutNode = .leaf(
            sessionName: "abc",
            title: "",
            attentionText: nil
        )
        #expect(
            MobileNavigationDecision.decide(layout: layout)
                == .session(sessionName: "abc", title: "")
        )
    }

    @Test
    func splitLayoutDecidesToWorktreeDetail() {
        let layout = PaneLayoutNode.split(
            direction: .horizontal,
            ratio: 0.5,
            left: .leaf(sessionName: "a", title: "A", attentionText: nil),
            right: .leaf(sessionName: "b", title: "B", attentionText: nil)
        )
        #expect(MobileNavigationDecision.decide(layout: layout) == .worktreeDetail)
    }

    @Test
    func nilLayoutDecidesToWorktreeDetail() {
        #expect(MobileNavigationDecision.decide(layout: nil) == .worktreeDetail)
    }
}
