import Testing
import Foundation
@testable import GrafttyKit

@Suite("GitWorktreeAdd argv shape", .serialized)
struct GitWorktreeAddArgsTests {
    @Test("createNew without startPoint uses -b <name> <path>")
    func createNewNoStart() {
        let argv = GitWorktreeAdd.argvFor(
            branch: .createNew(name: "feat-x"),
            worktreePath: "/repo/.worktrees/feat-x",
            startPoint: nil
        )
        #expect(argv == ["worktree", "add", "-b", "feat-x", "/repo/.worktrees/feat-x"])
    }

    @Test("createNew with startPoint appends the start point")
    func createNewWithStart() {
        let argv = GitWorktreeAdd.argvFor(
            branch: .createNew(name: "feat-x"),
            worktreePath: "/repo/.worktrees/feat-x",
            startPoint: "origin/main"
        )
        #expect(argv == ["worktree", "add", "-b", "feat-x", "/repo/.worktrees/feat-x", "origin/main"])
    }

    @Test("@spec GIT-5.10: When BranchSelection.useExisting is submitted with a local source, the application shall verify that `refs/heads/<name>` exists and invoke `git worktree add -- <path> <name>` (no `-b` flag), so commit-ish values cannot create a detached worktree and option-shaped names cannot alter Git's parsing.")
    func useExistingLocal() {
        let argv = GitWorktreeAdd.argvFor(
            branch: .useExisting(name: "feat-x", source: .local),
            worktreePath: "/repo/.worktrees/feat-x",
            startPoint: nil
        )
        #expect(argv == ["worktree", "add", "--", "/repo/.worktrees/feat-x", "feat-x"])
    }

    @Test("Existing-local creation rejects a commit-ish but accepts a real local branch.")
    func existingLocalRequiresExactBranchRef() async throws {
        let root = try makeTempDir(prefix: "graftty-existing-local")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        #expect(try shellInRepo(
            "git init -b main && git commit --allow-empty -m init && git branch feature",
            at: repo
        ) == 0)

        let detachedTarget = root.appendingPathComponent("detached").path
        do {
            try await GitWorktreeAdd.add(
                repoPath: repo.path,
                worktreePath: detachedTarget,
                branch: .useExisting(name: "HEAD", source: .local),
                startPoint: nil
            )
            Issue.record("HEAD must not be accepted as an existing local branch")
        } catch GitWorktreeAdd.Error.gitFailed(_, let stderr) {
            #expect(stderr == "local branch does not exist: HEAD")
        }
        #expect(!FileManager.default.fileExists(atPath: detachedTarget))

        let branchTarget = root.appendingPathComponent("feature").path
        try await GitWorktreeAdd.add(
            repoPath: repo.path,
            worktreePath: branchTarget,
            branch: .useExisting(name: "feature", source: .local),
            startPoint: nil
        )
        let head = try await GitRunner.run(
            args: ["symbolic-ref", "--short", "HEAD"],
            at: branchTarget
        )
        #expect(head.trimmingCharacters(in: .whitespacesAndNewlines) == "feature")
    }

    @Test("@spec GIT-5.12: When BranchSelection.useExisting is submitted with a remoteOnly source, the application shall invoke `git worktree add --track -b <name> <path> origin/<name>` so a local branch is created and checked out (not detached HEAD).")
    func useExistingRemoteOnly() {
        let argv = GitWorktreeAdd.argvFor(
            branch: .useExisting(name: "feat-x", source: .remoteOnly),
            worktreePath: "/repo/.worktrees/feat-x",
            startPoint: nil
        )
        #expect(argv == ["worktree", "add", "--track", "-b", "feat-x", "/repo/.worktrees/feat-x", "origin/feat-x"])
    }
}
