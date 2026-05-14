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
    @spec IOS-9.6: When the user swipes a worktree row in `WorktreePickerView` that is neither the repo's main checkout nor in an in-flight state (`.creating` / `.deleting`), the application shall reveal a trailing destructive action labeled "Delete" for non-stale rows and "Dismiss" for `.stale` rows. Rows for the main checkout or for in-flight worktrees shall expose no swipe action.
    """)
    func swipeActionFollowsStateRule() {
        #expect(WorktreePickerGrouping.swipeAction(for: Self.wt(.running, isMainCheckout: true)) == nil)
        #expect(WorktreePickerGrouping.swipeAction(for: Self.wt(.creating)) == nil)
        #expect(WorktreePickerGrouping.swipeAction(for: Self.wt(.deleting)) == nil)
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

    @Test("""
    @spec IOS-9.7: When the user taps the trailing destructive action revealed by `IOS-9.6`, the application shall present a SwiftUI confirmation dialog before any HTTP call. The dialog title shall be "Delete Worktree?" for non-stale rows and "Dismiss Worktree?" for `.stale` rows; the dialog body shall mirror the Mac's NSAlert copy ("This will delete the worktree but not the branch." / "This will remove this stale entry from Graftty."). On cancel, no request shall be issued.
    """)
    func dialogCopyMatchesMacAlert() {
        #expect(WorktreePickerSwipeAction.delete.dialogTitle == "Delete Worktree?")
        #expect(WorktreePickerSwipeAction.delete.dialogBody == "This will delete the worktree but not the branch.")
        #expect(WorktreePickerSwipeAction.dismiss.dialogTitle == "Dismiss Worktree?")
        #expect(WorktreePickerSwipeAction.dismiss.dialogBody == "This will remove this stale entry from Graftty.")
    }

    @Test("""
    @spec IOS-9.8: If `POST /worktrees/delete` returns 409 with `forceAllowed: true`, then the application shall present a Force Delete confirmation surfacing the `shortStatus` field as the dialog body, and shall retry the request with `force: true` only on user confirmation. A 409 with `forceAllowed: false` (or 4xx/5xx of any other shape) shall present a non-retryable error toast and shall not loop.
    """)
    func forceableErrorIsDistinctFromFinalError() {
        let forceable = DeleteWorktreeClient.DeleteError.gitFailedForceable(
            stderr: "err", shortStatus: "M foo"
        )
        let final = DeleteWorktreeClient.DeleteError.gitFailedFinal("main checkout")
        // userMessage nil → caller renders a Force Delete dialog rather than a toast.
        #expect(forceable.userMessage == nil)
        // userMessage non-nil → caller renders a flat error toast.
        #expect(final.userMessage == "main checkout")
    }
}
#endif
