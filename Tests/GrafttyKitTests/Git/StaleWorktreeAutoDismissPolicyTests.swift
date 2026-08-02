import Foundation
import Testing
@testable import GrafttyKit

@Suite("StaleWorktreeAutoDismissPolicy")
struct StaleWorktreeAutoDismissPolicyTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    @Test func worktreeIsNotExpiredBeforeGracePeriod() {
        let worktree = WorktreeEntry(
            path: "/repo/wt",
            branch: "feature",
            state: .stale,
            staleSince: now.addingTimeInterval(-3_599)
        )
        let state = appState(containing: [worktree])

        #expect(StaleWorktreeAutoDismissPolicy.expiredWorktreeIDs(
            in: state,
            now: now
        ).isEmpty)
    }

    @Test func worktreeExpiresAtGracePeriodBoundary() {
        let worktree = WorktreeEntry(
            path: "/repo/wt",
            branch: "feature",
            state: .stale,
            staleSince: now.addingTimeInterval(-3_600)
        )
        let state = appState(containing: [worktree])

        #expect(StaleWorktreeAutoDismissPolicy.expiredWorktreeIDs(
            in: state,
            now: now
        ) == [worktree.id])
    }

    @Test func legacyStaleWorktreeWithoutTimestampIsNotExpired() {
        var worktree = WorktreeEntry(
            path: "/repo/wt",
            branch: "feature",
            state: .stale
        )
        worktree.staleSince = nil

        #expect(StaleWorktreeAutoDismissPolicy.expiredWorktreeIDs(
            in: appState(containing: [worktree]),
            now: now
        ).isEmpty)
    }

    @Test func timestampDoesNotExpireNonStaleWorktree() {
        var worktree = WorktreeEntry(path: "/repo/wt", branch: "feature")
        worktree.staleSince = now.addingTimeInterval(-7_200)

        #expect(StaleWorktreeAutoDismissPolicy.expiredWorktreeIDs(
            in: appState(containing: [worktree]),
            now: now
        ).isEmpty)
    }

    private func appState(containing worktrees: [WorktreeEntry]) -> AppState {
        AppState(repos: [
            RepoEntry(
                path: "/repo",
                displayName: "repo",
                worktrees: worktrees
            ),
        ])
    }
}
