import Testing
import Foundation
@testable import EspalierKit

@Suite("GitRepoDetector Tests")
struct GitRepoDetectorTests {

    func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("espalier-git-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func shell(_ command: String, at dir: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = dir
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
        guard process.terminationStatus == 0 else {
            throw GitRepoDetectorTestError.shellFailed(command, process.terminationStatus)
        }
    }

    enum GitRepoDetectorTestError: Error {
        case shellFailed(String, Int32)
    }

    @Test func detectsRepoRoot() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try shell("git init && git commit --allow-empty -m 'init'", at: dir)
        let result = try GitRepoDetector.detect(path: dir.path)
        // Use the same `realpath`-based canonicalization as the detector
        // (macOS /var -> /private/var). Foundation's symlink resolver goes
        // the opposite way and would diverge from `git worktree list`'s
        // emitted paths.
        let expectedPath = CanonicalPath.canonicalize(dir.path)
        #expect(result == .repoRoot(expectedPath))
    }

    @Test func detectsWorktree() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repoDir = dir.appendingPathComponent("repo")
        let wtDir = dir.appendingPathComponent("worktree-feature")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        try shell("git init && git commit --allow-empty -m 'init'", at: repoDir)
        try shell("git worktree add \(wtDir.path) -b feature", at: repoDir)

        let result = try GitRepoDetector.detect(path: wtDir.path)
        let expectedWtPath = CanonicalPath.canonicalize(wtDir.path)
        let expectedRepoPath = CanonicalPath.canonicalize(repoDir.path)
        if case .worktree(let worktreePath, let repoPath) = result {
            #expect(worktreePath == expectedWtPath)
            #expect(repoPath == expectedRepoPath)
        } else {
            Issue.record("Expected .worktree, got \(result)")
        }
    }

    @Test func detectsNotARepo() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = try GitRepoDetector.detect(path: dir.path)
        #expect(result == .notARepo)
    }

    @Test func detectsSubdirectoryOfRepo() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try shell("git init && git commit --allow-empty -m 'init'", at: dir)
        let subDir = dir.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        let result = try GitRepoDetector.detect(path: subDir.path)
        // Use the same `realpath`-based canonicalization as the detector
        // (macOS /var -> /private/var). Foundation's symlink resolver goes
        // the opposite way and would diverge from `git worktree list`'s
        // emitted paths.
        let expectedPath = CanonicalPath.canonicalize(dir.path)
        #expect(result == .repoRoot(expectedPath))
    }
}
