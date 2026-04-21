import XCTest
@testable import GrafttyKit

@MainActor
final class PRStatusStoreTransitionTests: XCTestCase {
    func testStateOpenToMergedFiresEvent() {
        let store = PRStatusStore()
        var events: [(String, ChannelServerMessage)] = []
        store.onTransition = { path, msg in events.append((path, msg)) }

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

        // Expect BOTH pr_state_changed and ci_conclusion_changed (both differ).
        XCTAssertEqual(events.count, 2)
        let types = events.map { msg -> String in
            guard case let .event(t, _, _) = msg.1 else { return "" }
            return t
        }
        XCTAssertTrue(types.contains(ChannelEventType.prStateChanged))
        XCTAssertTrue(types.contains(ChannelEventType.ciConclusionChanged))

        // Check attrs on the state-changed event.
        let stateEvent = events.first { msg -> Bool in
            if case let .event(t, _, _) = msg.1 { return t == ChannelEventType.prStateChanged }
            return false
        }!
        guard case let .event(_, attrs, _) = stateEvent.1 else { return XCTFail() }
        XCTAssertEqual(attrs["from"], "open")
        XCTAssertEqual(attrs["to"], "merged")
        XCTAssertEqual(attrs["pr_number"], "42")
        XCTAssertEqual(attrs["provider"], "github")
        XCTAssertEqual(attrs["repo"], "acme/web")
        XCTAssertEqual(attrs["worktree"], "/wt/a")
        XCTAssertEqual(attrs["pr_url"], url.absoluteString)
    }

    func testIdempotentSamePRInfoFiresNothing() {
        let store = PRStatusStore()
        var count = 0
        store.onTransition = { _, _ in count += 1 }

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
        var events: [ChannelServerMessage] = []
        store.onTransition = { _, msg in events.append(msg) }

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
        guard case let .event(type, attrs, _) = events.first else { return XCTFail() }
        XCTAssertEqual(type, ChannelEventType.ciConclusionChanged)
        XCTAssertEqual(attrs["from"], "pending")
        XCTAssertEqual(attrs["to"], "failure")
        XCTAssertEqual(attrs["provider"], "gitlab")
        XCTAssertEqual(attrs["repo"], "acme/docs")
    }

    func testNilPreviousStillFiresOnInitialPR() {
        let store = PRStatusStore()
        var events: [ChannelServerMessage] = []
        store.onTransition = { _, msg in events.append(msg) }

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
