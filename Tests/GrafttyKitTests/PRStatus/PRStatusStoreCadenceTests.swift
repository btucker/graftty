import Testing
import Foundation
@testable import GrafttyKit

@Suite("PRStatusStore cadence")
struct PRStatusStoreCadenceTests {
    let url = URL(string: "https://github.com/x/y/pull/1")!

    @Test func pendingOpenIs10s() {
        let info = PRInfo(number: 1, title: "x", url: url, state: .open, checks: .pending, fetchedAt: Date())
        let d = PRStatusStore.cadenceFor(info: info, isAbsent: false, failureStreak: 0)
        #expect(d == .seconds(10))
    }

    @Test func stableOpenIs30s() {
        let info = PRInfo(number: 1, title: "x", url: url, state: .open, checks: .success, fetchedAt: Date())
        let d = PRStatusStore.cadenceFor(info: info, isAbsent: false, failureStreak: 0)
        #expect(d == .seconds(30))
    }

    @Test func mergedIs30s() {
        let info = PRInfo(number: 1, title: "x", url: url, state: .merged, checks: .none, fetchedAt: Date())
        let d = PRStatusStore.cadenceFor(info: info, isAbsent: false, failureStreak: 0)
        #expect(d == .seconds(30))
    }

    @Test func absentIs30s() {
        let d = PRStatusStore.cadenceFor(info: nil, isAbsent: true, failureStreak: 0)
        #expect(d == .seconds(30))
    }

    @Test func unknownIsImmediate() {
        let d = PRStatusStore.cadenceFor(info: nil, isAbsent: false, failureStreak: 0)
        #expect(d == .zero)
    }

    /// Pending CI is the cadence-tightening tier — every 10s so a green/red
    /// transition lands in the breadcrumb within one polling window. Backoff
    /// still doubles on failure, but it doubles from the 10s base, not 30s.
    @Test func pendingChecksBackoffStartsAtTenSeconds() {
        let info = PRInfo(number: 1, title: "x", url: url, state: .open, checks: .pending, fetchedAt: Date())
        #expect(PRStatusStore.cadenceFor(info: info, isAbsent: false, failureStreak: 1) == .seconds(20))
        #expect(PRStatusStore.cadenceFor(info: info, isAbsent: false, failureStreak: 2) == .seconds(40))
    }

    /// `PR-7.2`: the cap is 60s — a run of transient `gh` failures cannot
    /// push the next poll beyond a minute. Prior cap was 30 minutes, which
    /// produced silent staleness because `PR-7.10` preserves the cached
    /// info on failure and the user can't see that the schedule has
    /// drifted out.
    @Test func backoffCapsAtOneMinute() {
        let info = PRInfo(number: 1, title: "x", url: url, state: .open, checks: .success, fetchedAt: Date())
        // 30s × 2 = 60s (already at cap).
        #expect(PRStatusStore.cadenceFor(info: info, isAbsent: false, failureStreak: 1) == .seconds(60))
        // Higher streaks stay clamped.
        #expect(PRStatusStore.cadenceFor(info: info, isAbsent: false, failureStreak: 5) == .seconds(60))
        #expect(PRStatusStore.cadenceFor(info: info, isAbsent: false, failureStreak: 20) == .seconds(60))
        // Pending tier hits the cap at streak ≥ 3 (10 × 8 = 80 > 60).
        let pending = PRInfo(number: 1, title: "x", url: url, state: .open, checks: .pending, fetchedAt: Date())
        #expect(PRStatusStore.cadenceFor(info: pending, isAbsent: false, failureStreak: 3) == .seconds(60))
        #expect(PRStatusStore.cadenceFor(info: pending, isAbsent: false, failureStreak: 20) == .seconds(60))
    }

    /// When a fetch fails before the store knows whether a PR exists (e.g.
    /// `gh` not installed), the worktree stays `info: nil, isAbsent: false`
    /// but its failureStreak grows. The cadence must NOT be zero in that
    /// state — otherwise the poller hammers a broken CLI every tick.
    @Test func unknownWithFailureStreakBacksOff() {
        let d1 = PRStatusStore.cadenceFor(info: nil, isAbsent: false, failureStreak: 1)
        #expect(d1 >= .seconds(60))
        let d3 = PRStatusStore.cadenceFor(info: nil, isAbsent: false, failureStreak: 3)
        #expect(d3 >= .seconds(60))
        // And caps at 60s like every other failure path.
        let dMany = PRStatusStore.cadenceFor(info: nil, isAbsent: false, failureStreak: 20)
        #expect(dMany == .seconds(60))
    }
}
