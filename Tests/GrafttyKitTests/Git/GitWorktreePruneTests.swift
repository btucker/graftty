import Testing
import Foundation
@testable import GrafttyKit

@Suite("GitWorktreePrune Tests", .serialized)
struct GitWorktreePruneTests {

    /// @spec GIT-4.13: When the user confirms Delete Worktree on a worktree whose directory no longer exists on disk, the application shall run `git worktree prune --expire=now`, drop the worktree entry from the sidebar without prompting the user with a Force Delete alert, and tear down any running terminal surfaces for the entry.
    ///
    /// This test exercises the git-level half of the requirement: that
    /// `prune --expire=now` against a repo with an orphaned
    /// `.git/worktrees/<name>` entry (directory gone but admin dir still
    /// present) successfully removes the admin dir. The UI-glue half
    /// (calling this from `performDeleteWorktree`'s missing-directory
    /// branch and then `finishWorktreeRemoval`) is verified manually
    /// against the running app, matching the convention used for
    /// `performDeleteWorktree`'s other branches.
    @Test("""
@spec GIT-4.13: When the user confirms Delete Worktree on a worktree whose directory no longer exists on disk, the application shall run `git worktree prune --expire=now`, drop the worktree entry from the sidebar without prompting the user with a Force Delete alert, and tear down any running terminal surfaces for the entry.
""")
    func pruneRemovesOrphanedAdminEntry() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-prune-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let repoDir = dir.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        let worktreeDir = dir.appendingPathComponent("wt-feature")

        try runShell("""
            git init && \
            git commit --allow-empty -m 'init' && \
            git worktree add \(worktreeDir.path) -b feature
            """, at: repoDir)

        // Simulate the stale-registry condition: directory gone, admin
        // entry still present. This is what agent tooling produces when
        // it rm -rfs its scratch worktree without calling
        // `git worktree remove`.
        try FileManager.default.removeItem(at: worktreeDir)
        let adminEntry = repoDir.appendingPathComponent(".git/worktrees/wt-feature")
        #expect(FileManager.default.fileExists(atPath: adminEntry.path))

        try await GitWorktreePrune.run(repoPath: repoDir.path)

        #expect(!FileManager.default.fileExists(atPath: adminEntry.path))
    }

    /// `git worktree prune` is well-defined on a repo that has no
    /// prunable entries — exits 0 with empty stderr. Verifying the
    /// no-op shape so the UI's best-effort call (`try?`) does not
    /// silently mask a legitimate error.
    @Test func pruneNoopOnCleanRepo() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-prune-noop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let repoDir = dir.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        try runShell("git init && git commit --allow-empty -m 'init'", at: repoDir)

        try await GitWorktreePrune.run(repoPath: repoDir.path)
    }

    /// A non-git path raises `gitFailed` rather than a launch error —
    /// `git` itself exits non-zero with a populated stderr.
    @Test func pruneFailsOnNonGitPath() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-prune-bad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        do {
            try await GitWorktreePrune.run(repoPath: dir.path)
            Issue.record("expected gitFailed for non-git directory")
        } catch GitWorktreePrune.Error.gitFailed(let code, let stderr) {
            #expect(code != 0)
            #expect(!stderr.isEmpty)
        }
    }

    private func runShell(_ command: String, at directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = directory
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/local/bin",
            "HOME": NSHomeDirectory(),
            "GIT_AUTHOR_NAME": "Test",
            "GIT_AUTHOR_EMAIL": "test@test.com",
            "GIT_COMMITTER_NAME": "Test",
            "GIT_COMMITTER_EMAIL": "test@test.com",
        ]
        try process.run()
        process.waitUntilExit()
    }
}
