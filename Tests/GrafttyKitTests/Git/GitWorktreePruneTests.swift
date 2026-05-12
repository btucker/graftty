import Testing
import Foundation
@testable import GrafttyKit

@Suite("GitWorktreePrune Tests", .serialized)
struct GitWorktreePruneTests {

    /// Exercises the git-level half of GIT-4.13: `prune --expire=now`
    /// against a repo with an orphaned `.git/worktrees/<name>` entry
    /// (directory gone, admin dir still present) removes the admin dir.
    /// The UI-glue half (calling this from `performDeleteWorktree`'s
    /// missing-directory branch and then `finishWorktreeRemoval`) is
    /// verified manually against the running app, matching the
    /// convention used for `performDeleteWorktree`'s other branches.
    @Test("""
@spec GIT-4.13: When the user confirms Delete Worktree on a worktree whose directory no longer exists on disk, the application shall run `git worktree prune --expire=now`, drop the worktree entry from the sidebar without prompting the user with a Force Delete alert, and tear down any running terminal surfaces for the entry.
""")
    func pruneRemovesOrphanedAdminEntry() async throws {
        let dir = try makeTempDir(prefix: "graftty-prune")
        defer { try? FileManager.default.removeItem(at: dir) }

        let repoDir = dir.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        let worktreeDir = dir.appendingPathComponent("wt-feature")

        try shellInRepo("""
            git init && \
            git commit --allow-empty -m 'init' && \
            git worktree add \(worktreeDir.path) -b feature
            """, at: repoDir)

        // Stage the stale-registry condition: directory gone, admin entry
        // still present. This is what agent tooling produces when it
        // rm -rfs its scratch worktree without calling `git worktree remove`.
        try FileManager.default.removeItem(at: worktreeDir)
        let adminEntry = repoDir.appendingPathComponent(".git/worktrees/wt-feature")
        #expect(FileManager.default.fileExists(atPath: adminEntry.path))

        try await GitWorktreePrune.run(repoPath: repoDir.path)

        #expect(!FileManager.default.fileExists(atPath: adminEntry.path))
    }

    /// `git worktree prune` is well-defined on a repo that has no
    /// prunable entries — exits 0. The UI calls `prune` via `try?`, so
    /// verifying the no-op path doesn't throw guards against a future
    /// regression where the UI silently masks a legitimate error.
    @Test func pruneNoopOnCleanRepo() async throws {
        let dir = try makeTempDir(prefix: "graftty-prune-noop")
        defer { try? FileManager.default.removeItem(at: dir) }

        let repoDir = dir.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        try shellInRepo("git init && git commit --allow-empty -m 'init'", at: repoDir)

        try await GitWorktreePrune.run(repoPath: repoDir.path)
    }

    /// A non-git path raises `gitFailed` rather than a launch error —
    /// `git` itself exits non-zero with a populated stderr.
    @Test func pruneFailsOnNonGitPath() async throws {
        let dir = try makeTempDir(prefix: "graftty-prune-bad")
        defer { try? FileManager.default.removeItem(at: dir) }

        do {
            try await GitWorktreePrune.run(repoPath: dir.path)
            Issue.record("expected gitFailed for non-git directory")
        } catch GitWorktreePrune.Error.gitFailed(let code, let stderr) {
            #expect(code != 0)
            #expect(!stderr.isEmpty)
        }
    }
}
