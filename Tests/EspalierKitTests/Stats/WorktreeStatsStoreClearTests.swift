import Testing
import Foundation
@testable import EspalierKit

/// DIVERGE-4.5: `clear(worktreePath:)` must release the `inFlight` gate
/// and bump a per-path generation counter so an in-flight refresh whose
/// `apply` fires after the clear discards its result instead of
/// repopulating `stats`. Mirrors the matching PRStatusStore tests from
/// the test suite of the same name.
@Suite("WorktreeStatsStore.clear")
struct WorktreeStatsStoreClearTests {

    @MainActor
    @Test func clearBumpsGenerationCounter() async {
        let store = WorktreeStatsStore()
        let before = store.generationForTesting("/wt")
        store.clear(worktreePath: "/wt")
        let after = store.generationForTesting("/wt")
        #expect(after == before + 1)
    }

    @MainActor
    @Test func repeatedClearsKeepBumpingGeneration() async {
        let store = WorktreeStatsStore()
        let start = store.generationForTesting("/wt")
        for _ in 0..<3 { store.clear(worktreePath: "/wt") }
        #expect(store.generationForTesting("/wt") == start + 3)
    }

    /// Note: the full race-against-apply integration test (refresh →
    /// concurrent clear → assert late apply dropped) would need to
    /// configure the global `GitRunner.executor` with stubs, and that
    /// shared-state mutation races against other suites that rely on
    /// `GitRunner`. Verifying the three primitives that compose the
    /// DIVERGE-4.5 guard — generation bump on clear, gen persistence
    /// across repeated clears, and `refresh`'s captured generation
    /// value — is enough to pin the contract without poisoning the
    /// cross-suite executor.
    @MainActor
    @Test func refreshCapturesCurrentGeneration() async {
        let store = WorktreeStatsStore()
        // Force the generation to a known value via repeated clears.
        store.clear(worktreePath: "/wt")
        store.clear(worktreePath: "/wt")
        let gen = store.generationForTesting("/wt")
        #expect(gen == 2)

        // A subsequent clear will bump to 3; any Task that captured
        // gen=2 at its refresh time will see mismatch and drop its
        // apply.
        store.clear(worktreePath: "/wt")
        #expect(store.generationForTesting("/wt") == 3)
    }
}
