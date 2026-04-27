import Testing
import Foundation
@testable import GrafttyKit

@Suite("GitWorktreeDiscovery Tests", .serialized)
struct GitWorktreeDiscoveryTests {

    @Test func parsePorcelainOutput() throws {
        let output = """
        worktree /Users/ben/projects/myapp
        HEAD abc1234567890abcdef1234567890abcdef123456
        branch refs/heads/main

        worktree /Users/ben/worktrees/myapp/feature-auth
        HEAD def4567890abcdef1234567890abcdef12345678
        branch refs/heads/feature/auth

        worktree /Users/ben/worktrees/myapp/fix-bug
        HEAD 789abcdef1234567890abcdef1234567890abcdef
        branch refs/heads/fix/bug-123

        """
        let entries = GitWorktreeDiscovery.parsePorcelain(output)
        #expect(entries.count == 3)
        #expect(entries[0].path == "/Users/ben/projects/myapp")
        #expect(entries[0].branch == "main")
        #expect(entries[1].path == "/Users/ben/worktrees/myapp/feature-auth")
        #expect(entries[1].branch == "feature/auth")
        #expect(entries[2].branch == "fix/bug-123")
    }

    @Test func parsesDetachedHead() throws {
        let output = """
        worktree /Users/ben/projects/myapp
        HEAD abc1234567890abcdef1234567890abcdef123456
        detached

        """
        let entries = GitWorktreeDiscovery.parsePorcelain(output)
        #expect(entries.count == 1)
        #expect(entries[0].branch == "(detached)")
    }

    @Test func parsesBareRepo() throws {
        let output = """
        worktree /Users/ben/projects/myapp
        HEAD abc1234567890abcdef1234567890abcdef123456
        bare

        """
        let entries = GitWorktreeDiscovery.parsePorcelain(output)
        #expect(entries.count == 1)
        #expect(entries[0].branch == "(bare)")
    }

    /// GIT-4.7 regression guard: `discover` throws when asked to inspect
    /// a path that isn't a git repository. The app-level callers wrap
    /// this in `try?` historically — cycle 100's fix makes them log via
    /// NSLog instead; that behavior depends on `discover` actually
    /// surfacing the failure rather than returning empty.
    @Test func discoverThrowsForNonRepoPath() async {
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-non-repo-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: bogus, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bogus) }

        await #expect(throws: Error.self) {
            _ = try await GitWorktreeDiscovery.discover(repoPath: bogus.path)
        }
    }

    @Test func discoverFromRealRepo() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-discover-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let repoDir = dir.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", """
            git init && \
            git commit --allow-empty -m 'init' && \
            git worktree add ../wt-feature -b feature
            """]
        process.currentDirectoryURL = repoDir
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

        let entries = try await GitWorktreeDiscovery.discover(repoPath: repoDir.path)
        #expect(entries.count == 2)
        // Note: default branch may be 'main' or 'master' depending on git config
        #expect(entries[1].branch == "feature")
    }
}
