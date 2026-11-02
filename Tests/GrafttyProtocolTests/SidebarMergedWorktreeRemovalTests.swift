import Testing
@testable import GrafttyProtocol

struct SidebarMergedWorktreeRemovalTests {
    @Test("@spec LAYOUT-2.189: When a removable linked worktree has a merged PR or MR, the sidebar shall replace its Git divergence counts with a remove button that invokes the existing worktree deletion flow.")
    func mergedLinkedWorktreesOfferRemoval() {
        for state in [WorktreeWireState.running, .closed] {
            #expect(SidebarMergedWorktreeRemoval.isAvailable(prState: .merged, isMainCheckout: false, state: state))
            #expect(!SidebarMergedWorktreeRemoval.isAvailable(prState: .merged, isMainCheckout: true, state: state))
            for prState: PRInfo.State? in [nil, .open, .closed] {
                #expect(!SidebarMergedWorktreeRemoval.isAvailable(prState: prState, isMainCheckout: false, state: state))
            }
        }
        for state in [WorktreeWireState.creating, .deleting, .stale] {
            #expect(!SidebarMergedWorktreeRemoval.isAvailable(prState: .merged, isMainCheckout: false, state: state))
        }
    }
}
