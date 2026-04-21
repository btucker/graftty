import Testing
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

    @Test func mainCheckoutWithPRStillUsesPullSymbol() {
        // PR existence wins over the main-vs-linked distinction so the
        // signal is consistent regardless of which checkout the PR is on.
        #expect(WorktreeRowIcon.symbolName(isMainCheckout: true, hasPR: true) == "arrow.triangle.pull")
    }
}
