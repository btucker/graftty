#if canImport(UIKit)
import Testing
import GrafttyProtocol
@testable import GrafttyMobileKit

@Suite("WorktreePickerSwipeAction state mapping")
struct WorktreePickerSwipeActionTests {

    private static func wt(
        _ state: WorktreeWireState,
        isMainCheckout: Bool = false
    ) -> WorktreePanes {
        WorktreePanes(
            path: "/p/wt",
            displayName: "wt",
            repoDisplayName: "repo",
            displayBranch: "wt",
            state: state,
            isMainCheckout: isMainCheckout,
            prBadge: nil,
            stats: nil,
            attentionText: nil,
            layout: nil
        )
    }

    @Test("""
    @spec IOS-9.6: When the user swipes a worktree row in `WorktreePickerView` that is neither the repo's main checkout nor in the `.creating` state, the application shall reveal a trailing destructive action labeled "Delete" for non-stale rows and "Dismiss" for `.stale` rows. Rows for the main checkout or for `.creating` worktrees shall expose no swipe action.
    """)
    func swipeActionFollowsStateRule() {
        #expect(WorktreePickerGrouping.swipeAction(for: Self.wt(.running, isMainCheckout: true)) == nil)
        #expect(WorktreePickerGrouping.swipeAction(for: Self.wt(.creating)) == nil)
        #expect(WorktreePickerGrouping.swipeAction(for: Self.wt(.stale)) == .dismiss)
        #expect(WorktreePickerGrouping.swipeAction(for: Self.wt(.running)) == .delete)
        #expect(WorktreePickerGrouping.swipeAction(for: Self.wt(.closed)) == .delete)
    }

    @Test func mainCheckoutOverridesStaleState() {
        // Defensive: main checkout with stale state (rare but defined)
        // — swipe still disabled so we don't offer a dismiss that
        // implies dropping the whole repo by accident.
        #expect(WorktreePickerGrouping.swipeAction(for: Self.wt(.stale, isMainCheckout: true)) == nil)
    }
}
#endif
