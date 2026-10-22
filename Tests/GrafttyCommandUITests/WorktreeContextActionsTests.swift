import GrafttyProtocol
import Testing
@testable import GrafttyCommandUI

@Suite("@spec CONTEXT-21: When a Context history worktree link is opened on mobile, the application shall resolve a unique available target from fresh snapshots on the source host, reopen closed targets before selection, and abandon resolution when newer navigation supersedes it.")
struct WorktreeContextActionsTests {
    private func row(_ path: String, owner: String? = nil, state: WorktreeWireState = .running, ready: Bool = false) -> WorktreePanes {
        .init(path: path, displayName: path, repoDisplayName: "Repo", displayBranch: "main", state: state,
            isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil,
            layout: ready ? .leaf(sessionName: "pane", title: "Terminal", attentionText: nil, isBusy: false, attentionSource: nil) : nil,
            origin: owner.map { .init(deviceID: .init(value: $0), deviceLabel: $0, relayDepth: 0) })
    }

    @MainActor @Test func closedLinksWaitForAuthoritativeRunningLayout() async throws {
        let source = row("/source", owner: "A")
        let closed = row("/target", owner: "A", state: .closed)
        let running = row("/target", owner: "A", ready: true)
        var fetches = 0
        var opened: [String] = []
        let result = try await WorktreeContextActions.resolve("/target", source: source, fetch: {
            fetches += 1
            return [fetches < 3 ? closed : running]
        }, reopen: { opened.append($0) }, isCurrent: { true }, pause: {})
        #expect(opened == ["/target"])
        #expect(fetches == 3)
        #expect(result.worktree == running)
        #expect(result.rows == [running])
    }

    @MainActor @Test func newerNavigationCancelsPendingLinkBeforeReopen() async throws {
        let source = row("/source")
        var current = true
        var opened = false
        await #expect(throws: CancellationError.self) {
            _ = try await WorktreeContextActions.resolve("/target", source: source, fetch: {
                current = false
                return [row("/target", state: .closed)]
            }, reopen: { _ in opened = true }, isCurrent: { current }, pause: {})
        }
        #expect(!opened)
    }

    @MainActor @Test func unavailableLinkNeverReopensAnotherHost() async throws {
        var opened = false
        await #expect(throws: WorktreeContextActions.Failure.unavailable) {
            _ = try await WorktreeContextActions.resolve("/target", source: row("/source", owner: "A"),
                fetch: { [row("/target", owner: "B")] }, reopen: { _ in opened = true }, isCurrent: { true }, pause: {})
        }
        #expect(!opened)
    }

    @Test
    func worktreeLinksStayOnTheirSourceHost() {
        let source = row("/source", owner: "A")
        let target = row("/target", owner: "A")
        let otherHost = row("/target", owner: "B")
        #expect(WorktreeContextActions.target("/target", source: source, rows: [target, otherHost]) == target)
        #expect(WorktreeContextActions.target("/target", source: source, rows: [otherHost]) == nil)
        #expect(WorktreeContextActions.target("/missing", source: source, rows: [target]) == nil)
        #expect(WorktreeContextActions.target("/target", source: source, rows: [target, target]) == nil)
        for state in [WorktreeWireState.creating, .deleting, .stale] {
            #expect(WorktreeContextActions.target("/target", source: source, rows: [row("/target", owner: "A", state: state)]) == nil)
        }
        let legacy = row("/target")
        #expect(WorktreeContextActions.target("/target", source: row("/source"), rows: [legacy, otherHost]) == legacy)
    }
}
