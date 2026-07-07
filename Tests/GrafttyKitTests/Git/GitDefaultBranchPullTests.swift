import Testing
import Foundation
@testable import GrafttyKit

@Suite("GitDefaultBranchPull Tests", .serialized)
struct GitDefaultBranchPullTests {

    @Test func pullTargetsAdvertisedOriginBranch() async throws {
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
        GitRunner.configure(executor: fake)
        defer { GitRunner.resetForTests() }

        try await GitDefaultBranchPull.pull(repoPath: "/tmp/repo", branchName: "main")

        #expect(fake.invocations.map { $0.args } == [
            ["branch", "--show-current"],
            ["pull", "--ff-only", "origin", "main"],
        ])
        #expect(fake.invocations.allSatisfy { $0.directory == "/tmp/repo" })
    }

    @Test func pullRefusesWhenCheckoutMovedOffDefaultBranch() async throws {
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "git",
            args: ["branch", "--show-current"],
            output: CLIOutput(stdout: "develop\n", stderr: "", exitCode: 0)
        )
        GitRunner.configure(executor: fake)
        defer { GitRunner.resetForTests() }

        do {
            try await GitDefaultBranchPull.pull(repoPath: "/tmp/repo", branchName: "main")
            Issue.record("expected GitDefaultBranchPull.Error.gitFailed")
        } catch GitDefaultBranchPull.Error.gitFailed(let exitCode, let stderr) {
            #expect(exitCode == 1)
            #expect(stderr.contains("no longer on main"))
        }

        #expect(fake.invocations.map { $0.args } == [
            ["branch", "--show-current"],
        ])
    }

    @Test func pullMapsGitFailureToUserVisibleError() async throws {
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "git",
            args: ["branch", "--show-current"],
            output: CLIOutput(stdout: "main\n", stderr: "", exitCode: 0)
        )
        fake.stub(
            command: "git",
            args: ["pull", "--ff-only", "origin", "main"],
            output: CLIOutput(stdout: "", stderr: "fatal: Not possible to fast-forward", exitCode: 128)
        )
        GitRunner.configure(executor: fake)
        defer { GitRunner.resetForTests() }

        do {
            try await GitDefaultBranchPull.pull(repoPath: "/tmp/repo", branchName: "main")
            Issue.record("expected GitDefaultBranchPull.Error.gitFailed")
        } catch GitDefaultBranchPull.Error.gitFailed(let exitCode, let stderr) {
            #expect(exitCode == 128)
            #expect(stderr == "fatal: Not possible to fast-forward")
        }
    }
}
