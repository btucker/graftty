import Foundation
import Testing
import GrafttyProtocol
@testable import Graftty

@Suite("Worktree visit history")
struct WorktreeNavigationHistoryTests {
    private let a = WorktreeNavigationTarget.local("/a")
    private let b = WorktreeNavigationTarget.local("/b")
    private let c = WorktreeNavigationTarget.local("/c")
    private let d = WorktreeNavigationTarget.local("/d")

    @Test("@spec LAYOUT-1.7: When the user selects a different worktree, the application shall record the visit in window-local history; Back and Forward shall traverse those visits without adding visits, with unavailable directions disabled.")
    func backAndForwardTraverseVisits() {
        var history = WorktreeNavigationHistory()
        #expect(history.target(forward: false) == nil)
        history.record(a)
        #expect(history.target(forward: false) == nil)
        history.record(b)
        history.record(b)
        history.record(c)
        #expect(history.navigate(forward: false) == b)
        history.record(b) // Selection observation after replay must preserve Forward.
        #expect(history.navigate(forward: false) == a)
        #expect(history.navigate(forward: false) == nil)
        #expect(history.navigate(forward: true) == b)
        #expect(history.navigate(forward: true) == c)
        #expect(history.navigate(forward: true) == nil)
    }

    @Test("@spec LAYOUT-1.8: When the user opens another worktree after navigating Back, the application shall replace the forward history while retaining previously visited worktrees in the recent-worktrees dropdown.")
    func newVisitReplacesForwardBranch() {
        var history = WorktreeNavigationHistory()
        [a, b, c].forEach { history.record($0) }
        #expect(history.navigate(forward: false) == b)
        history.record(d)
        #expect(history.target(forward: true) == nil)
        #expect(history.recentTargets == [d, b, c, a])
        #expect(history.navigate(forward: false) == b)
        #expect(history.navigate(forward: false) == a)
    }

    @Test("@spec LAYOUT-1.9: When the user clicks the breadcrumb, the application shall offer distinct recently visited worktrees in most-recent-first order, identify their repository and remote Mac when applicable, mark the current worktree, and select a chosen worktree through the existing selection flow.")
    func recentsDeduplicateAndIncludeRevisits() {
        var history = WorktreeNavigationHistory()
        [a, b, a, c].forEach { history.record($0) }
        #expect(history.recentTargets == [c, a, b])
        #expect(history.navigate(forward: false) == a)
        #expect(history.recentTargets == [a, c, b])
        #expect(history.navigate(forward: false) == b)
        #expect(history.navigate(forward: false) == a)
    }

    @Test("@spec LAYOUT-1.10: If a visited worktree is unavailable, then the application shall skip it in Back, Forward, and the recent-worktrees dropdown, and shall distinguish local and remote visits with the same filesystem path.")
    func unavailableTargetsAndRemoteIdentity() throws {
        let identity = RemoteMacIdentity(id: .init(value: "mac"), fingerprint: try .init(rawBytes: Data(repeating: 1, count: 32)))
        let remote = WorktreeNavigationTarget.remote(identity, "/a")
        let replacement = RemoteMacIdentity(id: identity.id, fingerprint: try .init(rawBytes: Data(repeating: 2, count: 32)))
        #expect(remote != .remote(replacement, "/a"))
        var history = WorktreeNavigationHistory()
        [a, b, remote, c].forEach { history.record($0) }
        #expect(history.navigate(forward: false, isAvailable: { $0 != b && $0 != remote }) == a)
        #expect(history.navigate(forward: true, isAvailable: { $0 != b }) == remote)
        #expect(history.recentTargets.contains(a))
        #expect(history.recentTargets.contains(remote))
    }

    @Test("Unavailable intermediate visits do not navigate back to the current worktree")
    func skipDuplicateExposedByRemoval() {
        var history = WorktreeNavigationHistory()
        [c, a, b, a].forEach { history.record($0) }
        #expect(history.navigate(forward: false, isAvailable: { $0 != b }) == c)
        #expect(history.navigate(forward: true, isAvailable: { $0 != b }) == a)
    }

    @Test("Back returns to the last worktree from an empty selection")
    func emptySelectionRetainsTrail() {
        var history = WorktreeNavigationHistory()
        [a, b].forEach { history.record($0) }
        history.record(nil)
        #expect(history.navigate(forward: false) == b)
        #expect(history.navigate(forward: false) == a)
        #expect(history.navigate(forward: true) == b)
    }

    @Test("History and recents stay bounded")
    func boundedHistory() {
        var history = WorktreeNavigationHistory()
        for index in 0..<150 { history.record(.local("/\(index)")) }
        #expect(history.recentTargets.count == 20)
        var steps = 0
        while history.navigate(forward: false) != nil { steps += 1 }
        #expect(steps == 99)
        #expect(history.target(forward: false) == nil)
    }
}
