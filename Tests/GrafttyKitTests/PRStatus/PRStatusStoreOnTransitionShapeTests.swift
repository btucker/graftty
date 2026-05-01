import Foundation
import Testing
@testable import GrafttyKit

@Suite("PRStatusStore.onTransition shape (Phase 2)")
@MainActor
struct PRStatusStoreOnTransitionShapeTests {

    @Test("@spec PR-7.15: PRStatusStore.onTransition shall deliver a (RoutableEvent, worktreePath, attrs) tuple on every PR state or CI conclusion transition, so consumers can re-route via TeamEventDispatcher without parsing wire-format event types.")
    func onTransitionDeliversRoutableEvent() throws {
        let store = PRStatusStore(remoteBranchStore: nil)
        var captured: [(RoutableEvent, String, [String: String])] = []
        store.onTransition = { event, worktreePath, attrs in
            captured.append((event, worktreePath, attrs))
        }

        let url = URL(string: "https://example/pr/42")!
        let prev = PRInfo(
            number: 42,
            title: "x",
            url: url,
            state: .open,
            checks: .pending,
            fetchedAt: Date()
        )
        let curr = PRInfo(
            number: 42,
            title: "x",
            url: url,
            state: .merged,
            checks: .pending,
            fetchedAt: Date()
        )
        let origin = HostingOrigin(
            provider: .github,
            host: "github.com",
            owner: "x",
            repo: "y"
        )

        store.detectAndFireTransitionsForTesting(
            worktreePath: "/repo/.worktrees/alice",
            previous: prev,
            current: curr,
            origin: origin
        )

        // Only state changed (checks .pending -> .pending is identical), so one event.
        #expect(captured.count == 1)
        #expect(captured.first?.0 == .prMerged)
        #expect(captured.first?.1 == "/repo/.worktrees/alice")
        #expect(captured.first?.2["from"] == "open")
        #expect(captured.first?.2["to"] == "merged")
    }
}
