import Testing
import Foundation
@testable import GrafttyKit

@Suite("GitWorktreeRemove Tests", .serialized)
struct GitWorktreeRemoveTests {

    /// The happy path: add a linked worktree, remove it, and confirm both
    /// the directory and the administrative `.git/worktrees/<name>` entry
    /// are gone, but the branch ref the worktree had checked out is
    /// preserved — this is the invariant the confirmation dialog
    /// promises the user.
    @Test func removeDeletesDirectoryButPreservesBranch() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-remove-\(UUID().uuidString)")
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

        #expect(FileManager.default.fileExists(atPath: worktreeDir.path))
        #expect(FileManager.default.fileExists(
            atPath: repoDir.appendingPathComponent(".git/worktrees/wt-feature").path
        ))

        try await GitWorktreeRemove.remove(repoPath: repoDir.path, worktreePath: worktreeDir.path)

        #expect(!FileManager.default.fileExists(atPath: worktreeDir.path))
        #expect(!FileManager.default.fileExists(
            atPath: repoDir.appendingPathComponent(".git/worktrees/wt-feature").path
        ))

        // The branch must survive — `git worktree remove` doesn't touch
        // refs, and the confirmation dialog explicitly promises this.
        let refs = try await GitRunner.run(
            args: ["for-each-ref", "--format=%(refname:short)", "refs/heads/"],
            at: repoDir.path
        )
        #expect(refs.contains("feature"))
    }

    @Test("""
@spec GIT-4.12: If the user clicks "Force Delete" on the GIT-4.4 failure alert, the application shall re-run `git worktree remove --force <path>` and, on success, proceed through the same teardown path as GIT-4.5 / GIT-4.6 / GIT-4.10. If the forced remove also fails, the application shall surface git's stderr in a single-button error alert without offering Force Delete a second time, so the user is not trapped in a retry loop.
""")
    func removeWithForceDeletesDirtyWorktree() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-remove-force-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let repoDir = dir.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        let worktreeDir = dir.appendingPathComponent("wt-feature")

        try runShell("""
            git init && \
            git commit --allow-empty -m 'init' && \
            git worktree add \(worktreeDir.path) -b feature && \
            echo "scratch" > \(worktreeDir.path)/untracked.txt
            """, at: repoDir)

        // Sanity: a non-force remove refuses (untracked file present).
        do {
            try await GitWorktreeRemove.remove(repoPath: repoDir.path, worktreePath: worktreeDir.path)
            Issue.record("expected gitFailed for dirty worktree under non-force remove")
        } catch GitWorktreeRemove.Error.gitFailed { }

        // The force path succeeds.
        try await GitWorktreeRemove.remove(
            repoPath: repoDir.path,
            worktreePath: worktreeDir.path,
            force: true
        )

        #expect(!FileManager.default.fileExists(atPath: worktreeDir.path))
        #expect(!FileManager.default.fileExists(
            atPath: repoDir.appendingPathComponent(".git/worktrees/wt-feature").path
        ))
    }

    /// Git refuses to delete the main checkout. Ensure our wrapper surfaces
    /// that as a structured `gitFailed` error with stderr populated, so
    /// the UI can show a helpful message.
    @Test func removeRefusesMainCheckout() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-remove-main-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let repoDir = dir.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)

        try runShell("git init && git commit --allow-empty -m 'init'", at: repoDir)

        do {
            try await GitWorktreeRemove.remove(repoPath: repoDir.path, worktreePath: repoDir.path)
            Issue.record("expected gitFailed error for main-checkout removal")
        } catch GitWorktreeRemove.Error.gitFailed(let code, let stderr) {
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
