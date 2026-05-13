#if canImport(UIKit)
import Testing
import Foundation
import GrafttyProtocol
@testable import GrafttyMobileKit

@Suite("WorktreePickerGrouping")
struct WorktreePickerGroupingTests {

    private static func wt(_ repo: String, _ name: String) -> WorktreePanes {
        WorktreePanes(
            path: "/p/\(repo)/\(name)",
            displayName: name,
            repoDisplayName: repo,
            displayBranch: name,
            state: .running,
            isMainCheckout: false,
            prBadge: nil,
            stats: nil,
            attentionText: nil,
            layout: nil
        )
    }

    @Test("""
    @spec IOS-9.9: While rendering grouped worktrees in `WorktreePickerView`, the application shall preserve the order of `repoDisplayName` first-occurrences in the `GET /worktrees/panes` response rather than sort the group keys alphabetically, so the mobile picker's repo order matches the user's Mac sidebar order.
    """)
    func preservesFirstOccurrenceOrderNotAlphabetical() {
        // Wire arrives in order zebra, alpha, mango — sidebar order.
        // Alphabetical sort would put alpha first; first-occurrence
        // keeps zebra first.
        let list = [
            Self.wt("zebra", "main"),
            Self.wt("alpha", "main"),
            Self.wt("zebra", "feat-x"),
            Self.wt("mango", "main"),
            Self.wt("alpha", "feat-y"),
        ]
        let groups = WorktreePickerGrouping.grouped(list)
        #expect(groups.map(\.0) == ["zebra", "alpha", "mango"])
        #expect(groups[0].1.map(\.displayName) == ["main", "feat-x"])
        #expect(groups[1].1.map(\.displayName) == ["main", "feat-y"])
        #expect(groups[2].1.map(\.displayName) == ["main"])
    }

    @Test func emptyListReturnsEmpty() {
        #expect(WorktreePickerGrouping.grouped([]).isEmpty)
    }
}
#endif
