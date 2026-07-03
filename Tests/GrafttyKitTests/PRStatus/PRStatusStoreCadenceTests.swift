import Testing
import Foundation
@testable import GrafttyKit

/// `cadenceFor` is now keyed only on the per-repo `failureStreak`.
/// Per-state cadence tiers (pending vs stable PR) went away with
/// the switch to per-repo polling, since one `gh pr list` call
/// covers every PR in the repo regardless of CI state.
///
/// @spec PR-8.19
@Suite("PRStatusStore cadence")
struct PRStatusStoreCadenceTests {

    @Test func zeroStreakIsBaseSixtySeconds() {
        #expect(PRStatusStore.cadenceFor(failureStreak: 0) == .seconds(60))
    }

    @Test func backoffDoublesPerFailure() {
        #expect(PRStatusStore.cadenceFor(failureStreak: 1) == .seconds(120))
        #expect(PRStatusStore.cadenceFor(failureStreak: 2) == .seconds(240))
    }

    /// A run of `gh` failures — most importantly a `403` rate-limit
    /// rejection — backs the next poll off to five minutes rather than
    /// retrying every minute. `PR-7.10` preserves the cached info on
    /// failure, so the extra staleness is invisible-but-safe, and the
    /// slower retry is exactly what a rate-limited host needs.
    @Test func backoffCapsAtFiveMinutes() {
        #expect(PRStatusStore.cadenceFor(failureStreak: 3) == .seconds(300))
        #expect(PRStatusStore.cadenceFor(failureStreak: 4) == .seconds(300))
        #expect(PRStatusStore.cadenceFor(failureStreak: 20) == .seconds(300))
    }
}
