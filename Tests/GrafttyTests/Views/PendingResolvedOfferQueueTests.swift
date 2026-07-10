import Testing
import GrafttyProtocol
@testable import Graftty

/// @spec GIT-4.20: `PRStatusStore.onPRResolved` fires the resolved edge
/// exactly once (the idempotent-refetch guard in GIT-4.7 forbids
/// re-firing for the same terminal PR). So when the "delete worktree?"
/// offer can't present at that moment — no `NSApp.mainWindow`, because
/// the app is backgrounded or Settings / the Team Activity Log is
/// foregrounded — the offer would be lost forever. The application shall
/// instead queue such an offer and retry it when a window becomes
/// available, keyed by worktree so a newer resolution supersedes an
/// older one for the same worktree.
@Suite("PendingResolvedOfferQueue (GIT-4.20)")
@MainActor
struct PendingResolvedOfferQueueTests {
    private func offer(_ path: String, _ number: Int, _ state: PRInfo.State = .merged) -> PendingResolvedOffer {
        PendingResolvedOffer(worktreePath: path, prNumber: number, prTitle: "t-\(number)", state: state)
    }

    @Test func drainReturnsEnqueuedOffersThenEmpties() {
        let queue = PendingResolvedOfferQueue()
        #expect(queue.isEmpty)
        queue.enqueue(offer("/wt/a", 1))
        queue.enqueue(offer("/wt/b", 2))
        #expect(!queue.isEmpty)

        let drained = queue.drain().sorted { $0.prNumber < $1.prNumber }
        #expect(drained.map(\.prNumber) == [1, 2])
        // Drain clears — the caller re-enqueues any that still can't present.
        #expect(queue.isEmpty)
        #expect(queue.drain().isEmpty)
    }

    @Test func newerResolutionForSameWorktreeSupersedesOlder() {
        let queue = PendingResolvedOfferQueue()
        queue.enqueue(offer("/wt/a", 1, .merged))
        queue.enqueue(offer("/wt/a", 2, .closed))

        let drained = queue.drain()
        #expect(drained.count == 1)
        #expect(drained.first?.prNumber == 2)
        #expect(drained.first?.state == .closed)
    }

    @Test func removeDropsAWorktreesPendingOffer() {
        let queue = PendingResolvedOfferQueue()
        queue.enqueue(offer("/wt/a", 1))
        queue.enqueue(offer("/wt/b", 2))
        queue.remove(worktreePath: "/wt/a")

        let drained = queue.drain()
        #expect(drained.map(\.worktreePath) == ["/wt/b"])
    }
}
