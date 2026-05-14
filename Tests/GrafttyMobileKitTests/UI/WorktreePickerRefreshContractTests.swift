#if canImport(UIKit)
import Testing
import Foundation
import GrafttyProtocol
@testable import GrafttyMobileKit

@Suite("WorktreePickerRefresh")
struct WorktreePickerRefreshContractTests {

    @Test("""
    @spec IOS-4.20: While the user pull-to-refreshes the worktree picker (`IOS-4.1`), the application shall not blank the already-loaded list to a loading placeholder; the refresh shall re-fetch in place so the SwiftUI `.refreshable` host view remains mounted and the gesture completes without error.
    """)
    func refreshYieldsOnlyTerminalTransition() async {
        let payload = [WorktreePanes(
            path: "/p/wt", displayName: "wt", repoDisplayName: "r",
            displayBranch: "wt", state: .running, isMainCheckout: false,
            prBadge: nil, stats: nil, attentionText: nil, layout: nil
        )]
        let outcome = await WorktreePickerRefresh.refresh { payload }
        if case .replaced(let list) = outcome {
            #expect(list.count == 1)
        } else {
            Issue.record("expected .replaced, got \(outcome)")
        }
    }

    @Test func refreshFailureProducesTerminalFailure() async {
        struct Boom: Error {}
        let outcome = await WorktreePickerRefresh.refresh {
            throw Boom()
        }
        if case .failed = outcome {} else {
            Issue.record("expected .failed, got \(outcome)")
        }
    }
}
#endif
