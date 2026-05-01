import Testing
import Foundation
@testable import GrafttyKit

@Suite("GitStatusCapture Tests", .serialized)
struct GitStatusCaptureTests {

    /// Captures `git status --short` output as a single string. This is the
    /// content the GIT-4.4 failure dialog appends after git's stderr so the
    /// user can see exactly which paths blocked the delete.
    @Test func shortStatusListsModifiedAndUntrackedPaths() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try runShell("""
            git init && \
            git commit --allow-empty -m 'init' && \
            echo 'tracked' > tracked.txt && \
            git add tracked.txt && \
            git commit -m 'add tracked' && \
            echo 'modified' >> tracked.txt && \
            echo 'new' > untracked.txt
            """, at: dir)

        let status = await GitStatusCapture.shortStatus(at: dir.path)
        #expect(status.contains("tracked.txt"))
        #expect(status.contains("untracked.txt"))
        // Porcelain prefixes: ` M` for modified-tracked, `??` for untracked.
        #expect(status.contains("M tracked.txt"))
        #expect(status.contains("?? untracked.txt"))
    }

    /// A clean worktree returns an empty string, not whitespace. Callers
    /// branch on `.isEmpty` to decide whether to render the status block.
    @Test func shortStatusReturnsEmptyForCleanWorktree() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-status-clean-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try runShell("git init && git commit --allow-empty -m 'init'", at: dir)

        let status = await GitStatusCapture.shortStatus(at: dir.path)
        #expect(status.isEmpty)
    }

    /// A non-existent path can't surface a useful status — return empty so
    /// the dialog still renders the stderr without an exception bubble.
    @Test func shortStatusReturnsEmptyForNonRepoPath() async throws {
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-status-missing-\(UUID().uuidString)").path
        let status = await GitStatusCapture.shortStatus(at: bogus)
        #expect(status.isEmpty)
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
