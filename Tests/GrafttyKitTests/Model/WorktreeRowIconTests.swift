import Testing
import GrafttyProtocol
@testable import GrafttyKit

@Suite("WorktreeRowIcon")
struct WorktreeRowIconTests {
    @Test func linkedWorktreeWithoutPRUsesBranchSymbol() {
        #expect(WorktreeRowIcon.symbolName(isMainCheckout: false, hasPR: false) == "arrow.triangle.branch")
    }

    @Test func mainCheckoutWithoutPRUsesHouseSymbol() {
        #expect(WorktreeRowIcon.symbolName(isMainCheckout: true, hasPR: false) == "house")
    }

    @Test func worktreeWithPRUsesPullSymbol() {
        #expect(WorktreeRowIcon.symbolName(isMainCheckout: false, hasPR: true) == "arrow.triangle.pull")
    }

    @Test("@spec LAYOUT-2.27: The application shall render the `house` SF Symbol on the main-checkout sidebar row regardless of whether a PR is associated with that worktree, so the home affordance never disappears.")
    func mainCheckoutAlwaysUsesHouseSymbolEvenWithPR() {
        // The home icon is the only persistent visual indicator that
        // identifies the main checkout row. Flipping it to the PR glyph
        // when a PR exists on the main branch would erase the only
        // stable "home" cue once the row's text label also drifts to
        // the current branch.
        #expect(WorktreeRowIcon.symbolName(isMainCheckout: true, hasPR: true) == "house")
    }
}
