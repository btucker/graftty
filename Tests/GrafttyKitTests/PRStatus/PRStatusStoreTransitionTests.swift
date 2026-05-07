import XCTest
@testable import GrafttyKit

@MainActor
final class PRStatusStoreTransitionTests: XCTestCase {
    func testStateOpenToMergedFiresEvent() {
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
        XCTAssertEqual(events.count, 2)
        let routables = events.map(\.0)
        XCTAssertTrue(routables.contains(.prMerged))
        XCTAssertTrue(routables.contains(.ciConclusionChanged))

        // Check attrs on the merged event.
        let merged = events.first { $0.0 == .prMerged }!
        XCTAssertEqual(merged.1, "/wt/a")
        XCTAssertEqual(merged.2["from"], "open")
        XCTAssertEqual(merged.2["to"], "merged")
        XCTAssertEqual(merged.2["pr_number"], "42")
        XCTAssertEqual(merged.2["provider"], "github")
        XCTAssertEqual(merged.2["repo"], "acme/web")
        XCTAssertEqual(merged.2["worktree"], "/wt/a")
        XCTAssertEqual(merged.2["pr_url"], url.absoluteString)
    }

    func testIdempotentSamePRInfoFiresNothing() {
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
        XCTAssertEqual(count, 0)
    }

    func testChecksPendingToFailureFiresOnlyCiEvent() {
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

        XCTAssertEqual(events.count, 1)
        let (routable, attrs) = events[0]
        XCTAssertEqual(routable, .ciConclusionChanged)
        XCTAssertEqual(attrs["from"], "pending")
        XCTAssertEqual(attrs["to"], "failure")
        XCTAssertEqual(attrs["provider"], "gitlab")
        XCTAssertEqual(attrs["repo"], "acme/docs")
    }

    func testNilPreviousDoesNotFireOnInitialDiscovery() {
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
        XCTAssertEqual(events.count, 0)
    }
}
