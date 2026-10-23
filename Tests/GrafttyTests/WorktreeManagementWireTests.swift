import Foundation
import Testing
import GrafttyKit
import GrafttyProtocol
@testable import Graftty

/// Every `WorktreeManagement` result, mapped to the web REST outcome and the
/// paired-device envelope. The expected values are the ones the inline
/// transport closures in `GrafttyApp` produced before #483, so web and mobile
/// clients see the same wire.
@Suite("@spec WEB-7.13: When a worktree create, delete or default-branch pull finishes, the application shall report it to web and paired-device clients from one shared result, mapping each failure to that transport's existing status, code and message.")
@MainActor
struct WorktreeManagementWireTests {
    private let created = AddWorktreeFlow.Result(sessionName: "graftty-1", worktreePath: "/r/.worktrees/a")

    @Test func createMapsToRestOutcomes() {
        let cases: [(Result<AddWorktreeFlow.Result, WorktreeCreationError>, WebServer.CreateWorktreeOutcome)] = [
            (.success(created), .success(.init(sessionName: "graftty-1", worktreePath: "/r/.worktrees/a"))),
            (.failure(.gitFailed("fatal: x")), .gitFailed("fatal: x")),
            (.failure(.repoNotFound), .invalid("repository not tracked")),
            (.failure(.pathCollision), .invalid("a worktree at that name already exists")),
            (.failure(.branchAlreadyMounted(at: "/r/.worktrees/b")), .conflict(message: "branch is already mounted at b")),
            (.failure(.invalidInput("bad name")), .invalid("bad name")),
            (.failure(.discoveryFailed("no surface")), .internalFailure("no surface")),
        ]
        for (result, expected) in cases {
            #expect(WebServer.CreateWorktreeOutcome(result) == expected, "\(result)")
        }
    }

    @Test func createMapsToEnvelopeResponses() {
        let failure = { (message: String) in
            WorktreeManagementResponse.error(code: "create-failed", message: message, forceAllowed: false, shortStatus: nil)
        }
        let cases: [(Result<AddWorktreeFlow.Result, WorktreeCreationError>, WorktreeManagementResponse)] = [
            (.success(created), .created(worktreeID: "/r/.worktrees/a", paneID: "graftty-1")),
            (.failure(.gitFailed("fatal: x")), failure("fatal: x")),
            (.failure(.repoNotFound), failure("repository no longer tracked")),
            (.failure(.pathCollision), failure("a worktree at that name already exists")),
            (.failure(.branchAlreadyMounted(at: "/r/.worktrees/b")), failure("branch is already mounted at b")),
            (.failure(.invalidInput("bad name")), failure("bad name")),
            (.failure(.discoveryFailed("no surface")), failure("could not create worktree")),
        ]
        for (result, expected) in cases {
            #expect(WorktreeManagementResponse(creation: result) == expected, "\(result)")
        }
    }

    @Test func deleteMapsToRestOutcomes() {
        let cases: [(Result<WorktreeRemovalOutcome, WorktreeRemovalError>, WebServer.DeleteWorktreeOutcome)] = [
            (.success(.init(dismissed: false)), .success(.init(dismissed: false))),
            (.success(.init(dismissed: true)), .success(.init(dismissed: true))),
            (.failure(.notFound), .notFound("unknown worktree path")),
            (.failure(.mainCheckoutRejected), .invalid("cannot delete the repo's main checkout")),
            (.failure(.gitFailedForceable(stderr: "dirty", shortStatus: "?? a")), .gitFailedForceable(stderr: "dirty", shortStatus: "?? a")),
            (.failure(.gitFailedFinal("locked")), .gitFailedFinal("locked")),
        ]
        for (result, expected) in cases {
            #expect(WebServer.DeleteWorktreeOutcome(result) == expected, "\(result)")
        }
    }

    @Test func deleteMapsToEnvelopeResponses() {
        let cases: [(Result<WorktreeRemovalOutcome, WorktreeRemovalError>, WorktreeManagementResponse)] = [
            (.success(.init(dismissed: true)), .deleted(dismissed: true)),
            (.failure(.notFound), .error(code: "not-found", message: "unknown worktree", forceAllowed: false, shortStatus: nil)),
            (.failure(.mainCheckoutRejected), .error(code: "invalid", message: "cannot delete the main checkout", forceAllowed: false, shortStatus: nil)),
            (.failure(.gitFailedForceable(stderr: "dirty", shortStatus: "?? a")), .error(code: "git-failed", message: "dirty", forceAllowed: true, shortStatus: "?? a")),
            (.failure(.gitFailedFinal("locked")), .error(code: "git-failed", message: "locked", forceAllowed: false, shortStatus: nil)),
        ]
        for (result, expected) in cases {
            #expect(WorktreeManagementResponse(removal: result) == expected, "\(result)")
        }
    }

    private struct PullFailure: Error, CustomStringConvertible { var description: String { "network down" } }

    @Test func pullMapsToRestOutcomes() {
        let gitError = GitDefaultBranchPull.Error.gitFailed(exitCode: 1, stderr: "not a fast-forward")
        let cases: [(Result<Void, WorktreeManagement.DefaultBranchPullError>, WebServer.PullDefaultBranchOutcome)] = [
            (.success(()), .success(.init(ok: true))),
            (.failure(.repositoryNotTracked), .invalid("repository not tracked")),
            (.failure(.notBehind), .invalid("default checkout is not behind origin")),
            (.failure(.pullFailed(gitError)), .gitFailed("not a fast-forward")),
            (.failure(.pullFailed(PullFailure())), .internalFailure("network down")),
        ]
        for (result, expected) in cases {
            #expect(WebServer.PullDefaultBranchOutcome(result) == expected, "\(result)")
        }
    }

    @Test func pullMapsToEnvelopeResponses() {
        let gitError = GitDefaultBranchPull.Error.gitFailed(exitCode: 1, stderr: "not a fast-forward")
        let notBehind = WorktreeManagementResponse.error(code: "invalid", message: "default checkout is not behind origin",
                                                         forceAllowed: false, shortStatus: nil)
        let cases: [(Result<Void, WorktreeManagement.DefaultBranchPullError>, WorktreeManagementResponse)] = [
            (.success(()), .ok),
            (.failure(.repositoryNotTracked), notBehind),
            (.failure(.notBehind), notBehind),
            (.failure(.pullFailed(gitError)), .error(code: "pull-failed", message: String(describing: gitError),
                                                     forceAllowed: false, shortStatus: nil)),
        ]
        for (result, expected) in cases {
            #expect(WorktreeManagementResponse(defaultBranchPull: result) == expected, "\(result)")
        }
    }
}
