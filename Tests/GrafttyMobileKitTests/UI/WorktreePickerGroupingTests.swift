#if canImport(UIKit)
import Testing
import Foundation
import GrafttyProtocol
@testable import GrafttyMobileKit

@Suite("WorktreePickerGrouping")
struct WorktreePickerGroupingTests {

    private static func wt(
        _ repo: String,
        _ name: String,
        origin: WorktreeOrigin? = nil
    ) -> WorktreePanes {
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
            layout: nil,
            origin: origin
        )
    }

    @Test("""
    @spec IOS-9.9: While rendering grouped worktrees in `WorktreePickerView`, the application shall preserve the order of `repoDisplayName` first-occurrences in the authenticated panes-state snapshot rather than sort the group keys alphabetically, so the mobile picker's repo order matches the user's Mac sidebar order.
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
        #expect(groups.map(\.title) == ["zebra", "alpha", "mango"])
        #expect(groups[0].worktrees.map(\.displayName) == ["main", "feat-x"])
        #expect(groups[1].worktrees.map(\.displayName) == ["main", "feat-y"])
        #expect(groups[2].worktrees.map(\.displayName) == ["main"])
    }

    @Test func emptyListReturnsEmpty() {
        #expect(WorktreePickerGrouping.grouped([]).isEmpty)
    }

    @Test
    func remoteRowsGroupUnderOwningMacAndRepository() {
        let origin = WorktreeOrigin(
            deviceID: RemoteDeviceID(value: "studio"),
            deviceLabel: "Studio Mac",
            relayDepth: 1
        )
        let groups = WorktreePickerGrouping.grouped([
            Self.wt("graftty", "local"),
            Self.wt("graftty", "remote", origin: origin),
        ])

        #expect(groups.map(\.title) == ["graftty", "Studio Mac · graftty"])
        #expect(groups[0].worktrees.map(\.displayName) == ["local"])
        #expect(groups[1].worktrees.map(\.displayName) == ["remote"])
    }

    @Test
    func duplicateRemoteLabelsRemainDistinctByDeviceAndRepository() {
        let one = WorktreeOrigin(
            deviceID: RemoteDeviceID(value: "one"),
            deviceLabel: "Studio Mac",
            relayDepth: 1
        )
        let two = WorktreeOrigin(
            deviceID: RemoteDeviceID(value: "two"),
            deviceLabel: "Studio Mac",
            relayDepth: 1
        )
        let rows = [
            Self.wt("graftty", "one", origin: one),
            Self.wt("graftty", "two", origin: two),
        ]

        let groups = WorktreePickerGrouping.grouped(rows)

        #expect(groups.count == 2)
        #expect(groups[0].id != groups[1].id)
        #expect(groups.map(\.title) == [
            "Studio Mac (one) · graftty",
            "Studio Mac (two) · graftty",
        ])
    }
}
#endif
