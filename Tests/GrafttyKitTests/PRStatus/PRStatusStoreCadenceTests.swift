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

    @Test func zeroStreakIsBaseFiveSeconds() {
        #expect(PRStatusStore.cadenceFor(failureStreak: 0) == .seconds(5))
    }

    @Test func backoffDoublesPerFailure() {
        #expect(PRStatusStore.cadenceFor(failureStreak: 1) == .seconds(10))
        #expect(PRStatusStore.cadenceFor(failureStreak: 2) == .seconds(20))
        #expect(PRStatusStore.cadenceFor(failureStreak: 3) == .seconds(40))
    }

    /// A run of transient `gh` failures cannot push the next poll
    /// beyond a minute — `PR-7.10` preserves the cached info on
    /// failure, so a longer cap produces silent staleness with no UI cue.
    @Test func backoffCapsAtOneMinute() {
        #expect(PRStatusStore.cadenceFor(failureStreak: 4) == .seconds(60))
        #expect(PRStatusStore.cadenceFor(failureStreak: 5) == .seconds(60))
        #expect(PRStatusStore.cadenceFor(failureStreak: 20) == .seconds(60))
    }
}
