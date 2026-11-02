import Testing
import Foundation
@testable import GrafttyKit

@Suite("GitDefaultBranchPull Tests")
struct GitDefaultBranchPullTests {

    @Test("@spec GIT-5.32: When pulling the default checkout before worktree creation, the application shall bound branch validation to five seconds and retain the fast-forward pull's twenty-second timeout.")
    func pullTargetsAdvertisedOriginBranch() async throws {
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "git",
            args: ["branch", "--show-current"],
            output: CLIOutput(stdout: "main\n", stderr: "", exitCode: 0)
        )
        fake.stub(
            command: "git",
            args: ["pull", "--ff-only", "origin", "main"],
            output: CLIOutput(stdout: "", stderr: "", exitCode: 0)
        )

        try await GitDefaultBranchPull.pull(repoPath: "/tmp/repo", branchName: "main", using: fake)

        #expect(fake.invocations.map { $0.args } == [
            ["branch", "--show-current"],
            ["pull", "--ff-only", "origin", "main"],
        ])
        #expect(fake.invocations.allSatisfy { $0.directory == "/tmp/repo" })
        #expect(fake.invocations.map { $0.timeout } == [.seconds(5), .seconds(20)])
    }

    @Test("@spec GIT-5.33: If default-checkout branch validation times out, then the application shall report the failed lookup with exit code 124 and shall not run a pull.")
    func branchLookupTimeoutPreventsPull() async throws {
        let fake = FakeCLIExecutor()
        fake.stub(command: "git", args: ["branch", "--show-current"],
                  error: .timedOut(command: "git", seconds: 5))

        await #expect(throws: GitDefaultBranchPull.Error.gitFailed(
            exitCode: 124, stderr: "git branch --show-current timed out after 5 seconds"
        )) {
            try await GitDefaultBranchPull.pull(repoPath: "/tmp/repo", branchName: "main", using: fake)
        }

        #expect(fake.invocations.map { $0.args } == [["branch", "--show-current"]])
        #expect(fake.invocations.first?.timeout == .seconds(5))
    }

    @Test func pullTimeoutRetainsExistingError() async throws {
        let fake = FakeCLIExecutor()
        fake.stub(command: "git", args: ["branch", "--show-current"],
                  output: CLIOutput(stdout: "main\n", stderr: "", exitCode: 0))
        fake.stub(command: "git", args: ["pull", "--ff-only", "origin", "main"],
                  error: .timedOut(command: "git", seconds: 20))

        await #expect(throws: GitDefaultBranchPull.Error.gitFailed(
            exitCode: 124, stderr: "git pull --ff-only origin main timed out after 20 seconds"
        )) {
            try await GitDefaultBranchPull.pull(repoPath: "/tmp/repo", branchName: "main", using: fake)
        }
        #expect(fake.invocations.map { $0.timeout } == [.seconds(5), .seconds(20)])
    }

    @Test(arguments: ["", " \n", " fatal: HEAD unavailable\n"])
    func branchLookupFailurePreventsPull(stderr: String) async throws {
        let fake = FakeCLIExecutor()
        fake.stub(command: "git", args: ["branch", "--show-current"],
                  output: CLIOutput(stdout: "", stderr: stderr, exitCode: 128))
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)

        await #expect(throws: GitDefaultBranchPull.Error.gitFailed(
            exitCode: 128, stderr: trimmed.isEmpty ? "git branch --show-current failed" : trimmed
        )) {
            try await GitDefaultBranchPull.pull(repoPath: "/tmp/repo", branchName: "main", using: fake)
        }
        #expect(fake.invocations.map { $0.args } == [["branch", "--show-current"]])
    }

    @Test func unknownBranchPreventsAllCommands() async throws {
        let fake = FakeCLIExecutor()
        await #expect(throws: GitDefaultBranchPull.Error.gitFailed(
            exitCode: 1, stderr: "default branch is unknown"
        )) {
            try await GitDefaultBranchPull.pull(repoPath: "/tmp/repo", branchName: " \n", using: fake)
        }
        #expect(fake.invocations.isEmpty)
    }

    @Test func branchLookupLaunchFailureRetainsCLIError() async throws {
        let fake = FakeCLIExecutor()
        let error = CLIError.launchFailed(command: "git", message: "unavailable")
        fake.stub(command: "git", args: ["branch", "--show-current"], error: error)

        await #expect(throws: GitDefaultBranchPull.Error.cliFailure(error)) {
            try await GitDefaultBranchPull.pull(repoPath: "/tmp/repo", branchName: "main", using: fake)
        }
        #expect(fake.invocations.map { $0.args } == [["branch", "--show-current"]])
    }

    @Test func pullRefusesWhenCheckoutMovedOffDefaultBranch() async throws {
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "git",
            args: ["branch", "--show-current"],
            output: CLIOutput(stdout: "develop\n", stderr: "", exitCode: 0)
        )

        do {
            try await GitDefaultBranchPull.pull(repoPath: "/tmp/repo", branchName: "main", using: fake)
            Issue.record("expected GitDefaultBranchPull.Error.gitFailed")
        } catch GitDefaultBranchPull.Error.gitFailed(let exitCode, let stderr) {
            #expect(exitCode == 1)
            #expect(stderr.contains("no longer on main"))
        }

        #expect(fake.invocations.map { $0.args } == [
            ["branch", "--show-current"],
        ])
    }

    @Test(arguments: ["fatal: Not possible to fast-forward", " \n", " fatal: rejected\n"])
    func pullMapsGitFailureToUserVisibleError(stderr originalStderr: String) async throws {
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "git",
            args: ["branch", "--show-current"],
            output: CLIOutput(stdout: "main\n", stderr: "", exitCode: 0)
        )
        fake.stub(
            command: "git",
            args: ["pull", "--ff-only", "origin", "main"],
            output: CLIOutput(stdout: "", stderr: originalStderr, exitCode: 128)
        )

        do {
            try await GitDefaultBranchPull.pull(repoPath: "/tmp/repo", branchName: "main", using: fake)
            Issue.record("expected GitDefaultBranchPull.Error.gitFailed")
        } catch GitDefaultBranchPull.Error.gitFailed(let exitCode, let stderr) {
            #expect(exitCode == 128)
            let trimmed = originalStderr.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(stderr == (trimmed.isEmpty ? "git pull --ff-only origin main failed" : trimmed))
        }
    }
}
