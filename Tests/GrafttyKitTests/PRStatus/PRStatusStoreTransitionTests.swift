import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyKit

@MainActor
@Suite
struct PRStatusStoreTransitionTests {
    @Test func stateOpenToMergedFiresEvent() throws {
        let store = PRStatusStore()
        var events: [(RoutableEvent, String, [String: String])] = []
        store.onTransition = { event, path, attrs in events.append((event, path, attrs)) }

        let url = URL(string: "https://github.com/acme/web/pull/42")!
        let prev = PRInfo(number: 42, title: "Add login",
                          url: url, state: .open, checks: .pending, fetchedAt: Date())
        let next = PRInfo(number: 42, title: "Add login",
                          url: url, state: .merged, checks: .success, fetchedAt: Date())
        let origin = HostingOrigin(provider: .github, host: "github.com",
                                   owner: "acme", repo: "web")

        store.detectAndFireTransitionsForTesting(
            worktreePath: "/wt/a",
            previous: prev,
            current: next,
            origin: origin
        )

        // Expect BOTH prMerged (state=>merged) and ciConclusionChanged (both differ).
        #expect(events.count == 2)
        let routables = events.map(\.0)
        #expect(routables.contains(.prMerged))
        #expect(routables.contains(.ciConclusionChanged))

        // Check attrs on the merged event.
        let merged = try #require(events.first { $0.0 == .prMerged })
        #expect(merged.1 == "/wt/a")
        #expect(merged.2["from"] == "open")
        #expect(merged.2["to"] == "merged")
        #expect(merged.2["pr_number"] == "42")
        #expect(merged.2["provider"] == "github")
        #expect(merged.2["repo"] == "acme/web")
        #expect(merged.2["worktree"] == "/wt/a")
        #expect(merged.2["pr_url"] == url.absoluteString)
    }

    @Test func idempotentSamePRInfoFiresNothing() {
        let store = PRStatusStore()
        var count = 0
        store.onTransition = { _, _, _ in count += 1 }

        let url = URL(string: "https://github.com/a/b/pull/1")!
        let same = PRInfo(number: 1, title: "t", url: url,
                          state: .open, checks: .pending, fetchedAt: Date())
        let origin = HostingOrigin(provider: .github, host: "github.com",
                                   owner: "a", repo: "b")

        store.detectAndFireTransitionsForTesting(
            worktreePath: "/wt/b",
            previous: same,
            current: same,
            origin: origin
        )
        #expect(count == 0)
    }

    @Test func checksPendingToFailureFiresOnlyCiEvent() throws {
        let store = PRStatusStore()
        var events: [(RoutableEvent, [String: String])] = []
        store.onTransition = { event, _, attrs in events.append((event, attrs)) }

        let url = URL(string: "https://example/pr/7")!
        let prev = PRInfo(number: 7, title: "t", url: url,
                          state: .open, checks: .pending, fetchedAt: Date())
        let next = PRInfo(number: 7, title: "t", url: url,
                          state: .open, checks: .failure, fetchedAt: Date())
        let origin = HostingOrigin(provider: .gitlab, host: "gitlab.com",
                                   owner: "acme", repo: "docs")

        store.detectAndFireTransitionsForTesting(
            worktreePath: "/wt/c",
            previous: prev, current: next, origin: origin
        )

        #expect(events.count == 1)
        let (routable, attrs) = try #require(events.first)
        #expect(routable == .ciConclusionChanged)
        #expect(attrs["from"] == "pending")
        #expect(attrs["to"] == "failure")
        #expect(attrs["provider"] == "gitlab")
        #expect(attrs["repo"] == "acme/docs")
    }

    @Test func nilPreviousDoesNotFireOnInitialDiscovery() {
        let store = PRStatusStore()
        var events: [(RoutableEvent, String, [String: String])] = []
        store.onTransition = { event, path, attrs in events.append((event, path, attrs)) }

        let url = URL(string: "https://example/pr/1")!
        let next = PRInfo(number: 1, title: "t", url: url,
                          state: .open, checks: .success, fetchedAt: Date())
        let origin = HostingOrigin(provider: .github, host: "github.com",
                                   owner: "a", repo: "b")

        store.detectAndFireTransitionsForTesting(
            worktreePath: "/wt/d",
            previous: nil, current: next, origin: origin
        )

        // Initial discovery: should not fire (no "from" value) — discovery of a
        // new PR is not a transition. Transitions require a previous state.
        #expect(events.count == 0)
    }
}
