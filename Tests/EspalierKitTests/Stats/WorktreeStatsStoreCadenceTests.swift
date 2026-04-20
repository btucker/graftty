import Testing
import Foundation
@testable import EspalierKit

/// Pins `repoFetchCadence` to the values DIVERGE-4.3 describes: 5-minute
/// base with exponential backoff on fetch failure, capped at 30 minutes.
/// Without this, a refactor can silently change the fetch cadence and
/// surface either as a hammer on `git fetch` (too fast) or stale
/// divergence stats (too slow); the spec-alignment was drifting because
/// DIVERGE-4.3 originally said "60s" but the implementation chose 5min
/// with no test pinning the value.
@Suite("WorktreeStatsStore.repoFetchCadence")
struct WorktreeStatsStoreCadenceTests {

    @Test func baseCadenceIsFiveMinutes() {
        #expect(WorktreeStatsStore.repoFetchCadence(failureStreak: 0) == .seconds(5 * 60))
    }

    @Test func firstFailureDoublesTheBase() {
        #expect(WorktreeStatsStore.repoFetchCadence(failureStreak: 1) == .seconds(10 * 60))
    }

    @Test func fifthFailureHitsTheCap() {
        // ExponentialBackoff caps at streak=5 (32× base = 160min) but the
        // hard cap of 30min clamps that.
        #expect(WorktreeStatsStore.repoFetchCadence(failureStreak: 5) == .seconds(30 * 60))
    }

    @Test func runawayFailureStreakStaysAtCap() {
        #expect(WorktreeStatsStore.repoFetchCadence(failureStreak: 100) == .seconds(30 * 60))
    }
}
