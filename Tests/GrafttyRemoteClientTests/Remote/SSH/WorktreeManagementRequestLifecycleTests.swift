import Testing
@testable import GrafttyRemoteClient

@Suite("Worktree management request lifecycle")
struct WorktreeManagementRequestLifecycleTests {
    @Test("a response timeout poisons the lifecycle")
    func timeoutPreventsAnotherRequest() {
        var lifecycle = WorktreeManagementRequestLifecycle()
        let first = lifecycle.begin()
        guard case .accepted(let requestID) = first else {
            Issue.record("expected the first request to be accepted")
            return
        }

        let poisoned = lifecycle.poison(requestID)
        #expect(poisoned)
        let next = lifecycle.begin()
        #expect(next == .closed)
        let completedLateResponse = lifecycle.completeCurrent()
        #expect(!completedLateResponse)
    }

    @Test("an obsolete deadline cannot poison a newer request")
    func obsoleteDeadlineDoesNotPoisonNewRequest() {
        var lifecycle = WorktreeManagementRequestLifecycle()
        guard case .accepted(let firstID) = lifecycle.begin() else {
            Issue.record("expected the first request to be accepted")
            return
        }
        let completedFirst = lifecycle.completeCurrent()
        #expect(completedFirst)
        guard case .accepted(let secondID) = lifecycle.begin() else {
            Issue.record("expected the second request to be accepted")
            return
        }

        let poisonedByObsoleteDeadline = lifecycle.poison(firstID)
        #expect(!poisonedByObsoleteDeadline)
        #expect(lifecycle.isPending(secondID))
        let completedSecond = lifecycle.completeCurrent()
        #expect(completedSecond)
        #expect(!lifecycle.isClosed)
    }
}
