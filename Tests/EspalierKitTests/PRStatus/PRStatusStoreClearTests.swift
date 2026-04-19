import Testing
import Foundation
@testable import EspalierKit

// When a worktree is removed from the model (or a branch change forces
// a re-resolve), `clear(worktreePath:)` wipes the known PR state. Two
// invariants that weren't previously covered:
//
//   1. inFlight gets reset. Otherwise, a refresh mid-fetch would leave
//      the path stuck in `inFlight` until the prior Task completes,
//      blocking the next refresh — which for branch-change-triggered
//      re-resolves is exactly the moment Andy expects the new branch's
//      PR to show up immediately.
//
//   2. Each `clear` bumps a per-path generation counter. `performFetch`
//      captures the generation at start and checks it before writing
//      back to `infos`/`absent`/etc. If the generation changed (because
//      clear ran during the in-flight fetch), the stale blob is
//      dropped — no ghost PR badge for a cleared worktree.
@Suite("PRStatusStore.clear")
struct PRStatusStoreClearTests {

    @MainActor
    @Test func clearRemovesInFlightEntry() async {
        let fake = FakeCLIExecutor()
        let store = PRStatusStore(
            executor: fake,
            fetcherFor: { _ in nil },
            detectHost: { _ in nil }
        )
        store.beginInFlightForTesting("/wt")
        #expect(store.isInFlightForTesting("/wt"))
        store.clear(worktreePath: "/wt")
        #expect(!store.isInFlightForTesting("/wt"))
    }

    @MainActor
    @Test func clearBumpsGenerationCounter() async {
        let fake = FakeCLIExecutor()
        let store = PRStatusStore(
            executor: fake,
            fetcherFor: { _ in nil },
            detectHost: { _ in nil }
        )
        let before = store.generationForTesting("/wt")
        store.clear(worktreePath: "/wt")
        let after = store.generationForTesting("/wt")
        #expect(after == before + 1)
    }

    @MainActor
    @Test func repeatedClearsKeepBumpingGeneration() async {
        let fake = FakeCLIExecutor()
        let store = PRStatusStore(
            executor: fake,
            fetcherFor: { _ in nil },
            detectHost: { _ in nil }
        )
        let start = store.generationForTesting("/wt")
        for _ in 0..<3 { store.clear(worktreePath: "/wt") }
        #expect(store.generationForTesting("/wt") == start + 3)
    }
}
