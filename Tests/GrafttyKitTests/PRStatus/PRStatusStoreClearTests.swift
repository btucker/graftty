import Testing
import Foundation
@testable import GrafttyKit

/// `clear(worktreePath:)` is per-worktree-cache only now: it
/// removes `infos[wt]` and `absent` membership for the path. The
/// per-repo polling state (in-flight, generation, lastFetch,
/// failureStreak) is no longer keyed by worktree path, so a
/// worktree removal doesn't invalidate the repo's in-flight fetch
/// — the next dispatched fetch's snapshot simply won't find that
/// worktree to apply to.
///
/// @spec PR-8.21
@Suite("PRStatusStore.clear")
struct PRStatusStoreClearTests {

    @MainActor
    @Test func clearRemovesCachedInfo() async {
        let store = PRStatusStore(
            executor: FakeCLIExecutor(),
            fetcherFor: { _ in nil },
            detectHost: { _ in nil }
        )
        let url = URL(string: "https://github.com/x/y/pull/1")!
        let info = PRInfo(
            number: 1, title: "x", url: url,
            state: .open, checks: .pending, fetchedAt: Date()
        )
        store.applyInfoForTesting(worktreePath: "/wt", info: info)
        #expect(store.infos["/wt"] != nil)
        store.clear(worktreePath: "/wt")
        #expect(store.infos["/wt"] == nil)
    }

    @MainActor
    @Test func clearRemovesAbsentMembership() async {
        let store = PRStatusStore(
            executor: FakeCLIExecutor(),
            fetcherFor: { _ in nil },
            detectHost: { _ in nil }
        )
        store.markAbsentForTesting("/wt")
        #expect(store.absent.contains("/wt"))
        store.clear(worktreePath: "/wt")
        #expect(!store.absent.contains("/wt"))
    }

    @MainActor
    @Test func clearOnNeverSeenWorktreeIsNoOp() async {
        let store = PRStatusStore(
            executor: FakeCLIExecutor(),
            fetcherFor: { _ in nil },
            detectHost: { _ in nil }
        )
        // No throw, no @Observable mutation.
        store.clear(worktreePath: "/never-seen")
        #expect(store.infos.isEmpty)
        #expect(store.absent.isEmpty)
    }
}
