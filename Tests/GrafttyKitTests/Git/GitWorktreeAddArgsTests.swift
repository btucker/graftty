import Testing
import Foundation
@testable import GrafttyKit

@Suite("GitWorktreeAdd argv shape", .serialized)
struct GitWorktreeAddArgsTests {
    @Test("createNew without startPoint ends option parsing before the path")
    func createNewNoStart() {
        let argv = GitWorktreeAdd.argvFor(
            branch: .createNew(name: "feat-x"),
            worktreePath: "/repo/.worktrees/feat-x",
            startPoint: nil
        )
        #expect(argv == ["worktree", "add", "-b", "feat-x", "--", "/repo/.worktrees/feat-x"])
    }

    @Test("createNew with startPoint appends the start point")
    func createNewWithStart() {
        let argv = GitWorktreeAdd.argvFor(
            branch: .createNew(name: "feat-x"),
            worktreePath: "/repo/.worktrees/feat-x",
            startPoint: "origin/main"
        )
        #expect(argv == ["worktree", "add", "-b", "feat-x", "--", "/repo/.worktrees/feat-x", "origin/main"])
    }

    @Test("""
    @spec AGENT-5.6: When `graftty worktree add <name> --base <ref>` is invoked for a new branch, the application shall create that branch from the exact locally available Git-resolvable revision without fetching, reject `--base` with `--existing`, and document the option in CLI help and the built-in team session template. Before mutation, the application shall resolve the ref to an immutable commit ID in the worktree that invoked the CLI, so worktree-local revisions such as `HEAD`, `@`, `HEAD~1`, and reflog selectors do not accidentally resolve against the repository's main checkout.
    """)
    func createNewFromExplicitBase() async throws {
        let root = try makeTempDir(prefix: "graftty-explicit-base")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        #expect(try shellInRepo(
            """
            git init -b main &&
            git commit --allow-empty -m base &&
            git tag chosen-base &&
            git commit --allow-empty -m newer
            """,
            at: repo
        ) == 0)

        let target = root.appendingPathComponent("from-base").path
        try await GitWorktreeAdd.add(
            repoPath: repo.path,
            worktreePath: target,
            branch: .createNew(name: "from-base"),
            startPoint: "chosen-base"
        )
        let createdHead = try await GitRunner.run(args: ["rev-parse", "HEAD"], at: target)
        let chosenBase = try await GitRunner.run(args: ["rev-parse", "chosen-base"], at: repo.path)

        #expect(
            createdHead.trimmingCharacters(in: .whitespacesAndNewlines) ==
            chosenBase.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    @Test("""
    @spec GIT-5.22: Worktrees created through GitWorktreeAdd shall allow Git's installed post-checkout hook to complete before the creation call returns, matching a direct `git worktree add`.
    """)
    func worktreeAddRunsPostCheckoutHook() async throws {
        let root = try makeTempDir(prefix: "graftty-worktree-hook")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        let target = root.appendingPathComponent("hooked-worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        #expect(try shellInRepo(
            "git init -b main && git commit --allow-empty -m init",
            at: repo
        ) == 0)

        let hook = repo
            .appendingPathComponent(".git/hooks", isDirectory: true)
            .appendingPathComponent("post-checkout")
        try """
        #!/bin/sh
        printf 'post-checkout-ran\n' > .graftty-post-checkout-ran
        """.write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: hook.path
        )

        try await GitWorktreeAdd.add(
            repoPath: repo.path,
            worktreePath: target.path,
            branch: .createNew(name: "hooked-worktree"),
            startPoint: nil
        )

        let marker = target.appendingPathComponent(".graftty-post-checkout-ran")
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(try String(contentsOf: marker, encoding: .utf8) == "post-checkout-ran\n")
    }

    @Test("A worktree-local base such as HEAD resolves in the invoking worktree")
    func explicitHeadUsesInvokingWorktree() async throws {
        let root = try makeTempDir(prefix: "graftty-caller-relative-base")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        let caller = root.appendingPathComponent("caller", isDirectory: true)
        let target = root.appendingPathComponent("from-caller-head", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        #expect(try shellInRepo(
            """
            git init -b main &&
            git commit --allow-empty -m main &&
            git branch caller &&
            git worktree add \(caller.path) caller
            """,
            at: repo
        ) == 0)
        let instructionsDirectory = caller.appendingPathComponent(
            ".graftty",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: instructionsDirectory,
            withIntermediateDirectories: true
        )
        let leaf = instructionsDirectory.appendingPathComponent(
            "GRAFTTY.from-caller-head.md"
        )
        try "child role".write(to: leaf, atomically: true, encoding: .utf8)
        #expect(try shellInRepo(
            "git add .graftty/GRAFTTY.from-caller-head.md && git commit -m caller",
            at: caller
        ) == 0)

        try await GitWorktreeAdd.add(
            repoPath: repo.path,
            worktreePath: target.path,
            branch: .createNew(name: "from-caller-head"),
            startPoint: "HEAD",
            startPointResolutionPath: caller.path
        )

        let mainHead = try await GitRunner.run(args: ["rev-parse", "HEAD"], at: repo.path)
        let callerHead = try await GitRunner.run(args: ["rev-parse", "HEAD"], at: caller.path)
        let targetHead = try await GitRunner.run(args: ["rev-parse", "HEAD"], at: target.path)
        #expect(targetHead == callerHead)
        #expect(targetHead != mainHead)
        #expect(try String(
            contentsOf: target
                .appendingPathComponent(".graftty", isDirectory: true)
                .appendingPathComponent("GRAFTTY.from-caller-head.md"),
            encoding: .utf8
        ) == "child role")
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
