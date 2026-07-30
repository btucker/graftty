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

    @Test("""
    @spec IOS-4.2: When the authenticated paired connection or panes-state \
    channel cannot be established, the application shall preserve any prior \
    snapshot, render an error banner with a manual retry button, and never \
    retry through the legacy Web Access endpoints.
    """)
    func refreshFailurePreservesLastLoadedSnapshot() {
        let snapshot = [WorktreePanes(
            path: "/p/wt", displayName: "wt", repoDisplayName: "r",
            displayBranch: "wt", state: .running, isMainCheckout: false,
            prBadge: nil, stats: nil, attentionText: nil, layout: nil
        )]

        let next = WorktreeListContent.loadState(
            afterFailure: "offline",
            current: .loaded(snapshot)
        )

        #expect(next == .loaded(snapshot))
    }
}
#endif
