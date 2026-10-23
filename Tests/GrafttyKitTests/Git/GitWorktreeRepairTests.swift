import Testing
import Foundation
@testable import GrafttyKit

/// Unit tests for `GitWorktreeRepair`. Unlike the sibling
/// `GitWorktreeRemoveTests` (which shells out to real `git`), these tests
/// pass the shared `FakeCLIExecutor` through `using:` so we can
/// assert the exact args and cwd the wrapper produces without depending
/// on a real repo layout. The wrapper is thin — the contract worth
/// pinning is "the right command is assembled and non-zero becomes
/// `gitFailed`".
@Suite("GitWorktreeRepair Tests")
struct GitWorktreeRepairTests {

    @Test func repairInvokesGitWithExpectedArgs() async throws {
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "git",
            args: [
                "worktree", "repair",
                "/tmp/repo/.worktrees/a",
                "/tmp/repo/.worktrees/b",
            ],
            output: CLIOutput(stdout: "", stderr: "", exitCode: 0)
        )

        try await GitWorktreeRepair.repair(
            repoPath: "/tmp/repo",
            worktreePaths: [
                "/tmp/repo/.worktrees/a",
                "/tmp/repo/.worktrees/b",
            ],
            using: fake
        )

        #expect(fake.invocations.count == 1)
        #expect(fake.invocations[0].command == "git")
        #expect(fake.invocations[0].directory == "/tmp/repo")
        #expect(fake.invocations[0].args == [
            "worktree", "repair",
            "/tmp/repo/.worktrees/a",
            "/tmp/repo/.worktrees/b",
        ])
    }

    @Test func repairWithoutWorktreePathsStillRuns() async throws {
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "git",
            args: ["worktree", "repair"],
            output: CLIOutput(stdout: "", stderr: "", exitCode: 0)
        )

        try await GitWorktreeRepair.repair(repoPath: "/tmp/repo", worktreePaths: [], using: fake)

        #expect(fake.invocations.count == 1)
        #expect(fake.invocations[0].directory == "/tmp/repo")
        #expect(fake.invocations[0].args == ["worktree", "repair"])
    }

    @Test func repairThrowsGitFailedOnNonZeroExit() async throws {
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "git",
            args: ["worktree", "repair"],
            output: CLIOutput(
                stdout: "",
                stderr: "fatal: not a git repository",
                exitCode: 1
            )
        )

        do {
            try await GitWorktreeRepair.repair(repoPath: "/tmp", worktreePaths: [], using: fake)
            Issue.record("expected GitWorktreeRepair.Error.gitFailed to be thrown")
        } catch GitWorktreeRepair.Error.gitFailed(let exitCode, let stderr) {
            #expect(exitCode == 1)
            #expect(stderr == "fatal: not a git repository")
        }
    }
}
