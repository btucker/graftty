import Testing
import Foundation
@testable import GrafttyKit

/// Pins `repoFetchCadence` to the values DIVERGE-4.3 describes: 30-second
/// base with exponential backoff on fetch failure, capped at 30 minutes.
/// Without this, a refactor can silently change the fetch cadence and
/// surface either as a hammer on `git fetch` (too fast) or stale
/// divergence stats (too slow).
@Suite("""
WorktreeStatsStore.repoFetchCadence

@spec DIVERGE-4.3: The application shall run `git fetch --no-tags --prune origin` (with no refspec, so the remote's configured fetch rules advance every tracked branch) and recompute divergence counts per repository on a 30-second base cadence, doubling the interval for each consecutive fetch failure (capped by `ExponentialBackoff`'s 32× max shift and a 30-minute hard cap, whichever binds first). A fast 5-second polling ticker drives the eligibility check; actual fetches are gated by the per-repo cadence so tracked repositories are not hammered.
""")
struct WorktreeStatsStoreCadenceTests {

    @Test func baseCadenceIsThirtySeconds() {
        #expect(WorktreeStatsStore.repoFetchCadence(failureStreak: 0) == .seconds(30))
    }

    @Test func firstFailureDoublesTheBase() {
        #expect(WorktreeStatsStore.repoFetchCadence(failureStreak: 1) == .seconds(60))
    }

    @Test func fifthFailureSaturatesAtThirtyTwoX() {
        // `ExponentialBackoff.scale` uses `maxShift = 5` (2^5 = 32×), so
        // streak ≥ 5 clamps at `base * 32`. With a 30s base that's 960s
        // (16 min) — below the outer 30-minute cap, which therefore
        // never kicks in. The cap remains as defense-in-depth against a
        // future base bump past ~1 minute.
        #expect(WorktreeStatsStore.repoFetchCadence(failureStreak: 5) == .seconds(30 * 32))
    }

    @Test func runawayFailureStreakDoesNotExceedMaxShift() {
        #expect(WorktreeStatsStore.repoFetchCadence(failureStreak: 100) == .seconds(30 * 32))
    }

    /// DIVERGE-4.6: per-worktree local stats recompute cadence is
    /// independent of the repo-level fetch cadence. Pinned at 30s to
    /// match `PRStatusStore.cadenceFor`'s base so the sidebar's two
    /// indicators (divergence + PR badge) refresh on the same tempo.
    @Test func statsRefreshCadenceIsThirtySeconds() {
        #expect(WorktreeStatsStore.statsRefreshCadence() == .seconds(30))
    }
}
