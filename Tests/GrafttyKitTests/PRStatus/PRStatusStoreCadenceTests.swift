import Testing
import Foundation
@testable import GrafttyKit

@Suite("PRStatusStore cadence")
struct PRStatusStoreCadenceTests {
    let url = URL(string: "https://github.com/x/y/pull/1")!

    @Test func pendingOpenIs30s() {
        let info = PRInfo(number: 1, title: "x", url: url, state: .open, checks: .pending, fetchedAt: Date())
        let d = PRStatusStore.cadenceFor(info: info, isAbsent: false, failureStreak: 0)
        #expect(d == .seconds(30))
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

    @Test func backoffDoublesCadence() {
        let info = PRInfo(number: 1, title: "x", url: url, state: .open, checks: .success, fetchedAt: Date())
        // base=30s, 30 * 2^streak, capped at 30min.
        let d1 = PRStatusStore.cadenceFor(info: info, isAbsent: false, failureStreak: 1)
        #expect(d1 == .seconds(60))
        let d2 = PRStatusStore.cadenceFor(info: info, isAbsent: false, failureStreak: 2)
        #expect(d2 == .seconds(120))
        let d5 = PRStatusStore.cadenceFor(info: info, isAbsent: false, failureStreak: 5)
        #expect(d5 == .seconds(30 * 32))
    }

    @Test func backoffMaxesOutAtShift5() {
        // With a 30s base and maxShift=5 (2^5 = 32), failure cadence tops
        // out at 960s, below the 30-min cap — so the cap is only reachable
        // via the unknown-state fallback (covered in
        // `unknownWithFailureStreakBacksOff`).
        let info = PRInfo(number: 1, title: "x", url: url, state: .open, checks: .success, fetchedAt: Date())
        let d = PRStatusStore.cadenceFor(info: info, isAbsent: false, failureStreak: 20)
        #expect(d == .seconds(30 * 32))
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
        // And eventually caps like any other back-off path.
        let dMany = PRStatusStore.cadenceFor(info: nil, isAbsent: false, failureStreak: 20)
        #expect(dMany == .seconds(30 * 60))
    }
}
