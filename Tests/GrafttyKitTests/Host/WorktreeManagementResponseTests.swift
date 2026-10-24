import Testing
import GrafttyProtocol
@testable import GrafttyKit

@Suite("Shared paired-device worktree lifecycle responses")
struct WorktreeManagementResponseTests {
    @Test func creationFailuresKeepTheMacWire() {
        for (message, expected) in [(nil, "could not create worktree"), ("", ""), ("fatal: x", "fatal: x")] as [(String?, String)] {
            #expect(WorktreeManagementResponse.creationFailure(message: message) == .error(
                code: "create-failed", message: expected, forceAllowed: false, shortStatus: nil))
        }
    }

    @Test func removalResultsKeepTheMacWire() {
        let cases: [(Result<WorktreeRemovalOutcome, WorktreeRemovalError>, WorktreeManagementResponse)] = [
            (.success(.init(dismissed: false)), .deleted(dismissed: false)),
            (.success(.init(dismissed: true)), .deleted(dismissed: true)),
            (.failure(.notFound), .error(code: "not-found", message: "unknown worktree", forceAllowed: false, shortStatus: nil)),
            (.failure(.mainCheckoutRejected), .error(code: "invalid", message: "cannot delete the main checkout", forceAllowed: false, shortStatus: nil)),
            (.failure(.gitFailedForceable(stderr: "dirty", shortStatus: "?? a")), .error(code: "git-failed", message: "dirty", forceAllowed: true, shortStatus: "?? a")),
            (.failure(.gitFailedFinal("locked")), .error(code: "git-failed", message: "locked", forceAllowed: false, shortStatus: nil)),
        ]
        for (result, expected) in cases {
            #expect(WorktreeManagementResponse(removal: result) == expected)
        }
    }
}
