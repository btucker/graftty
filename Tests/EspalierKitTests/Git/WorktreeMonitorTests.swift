import Testing
import Foundation
@testable import EspalierKit

@Suite("WorktreeMonitor Tests")
struct WorktreeMonitorTests {

    @Test func branchChangeFiresOnCommit() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("espalier-monitor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try runGit(
            ["init", "--initial-branch=main"],
            cwd: tmp
        )
        try runGit(["commit", "--allow-empty", "-m", "init"], cwd: tmp)

        let recorder = BranchChangeRecorder()
        let monitor = WorktreeMonitor()
        monitor.delegate = recorder
        monitor.watchHeadRef(worktreePath: tmp.path, repoPath: tmp.path)

        // Give the dispatch source a moment to arm before we trigger the write
        // — without this the very first event can race past the source.
        try await Task.sleep(nanoseconds: 100_000_000)

        try runGit(["commit", "--allow-empty", "-m", "second"], cwd: tmp)

        try await waitUntil(timeout: 2.0) { recorder.didFire }
    }

    // MARK: - Helpers

    private func runGit(_ args: [String], cwd: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = cwd
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/local/bin",
            "HOME": NSHomeDirectory(),
            "GIT_AUTHOR_NAME": "Test",
            "GIT_AUTHOR_EMAIL": "test@test.com",
            "GIT_COMMITTER_NAME": "Test",
            "GIT_COMMITTER_EMAIL": "test@test.com",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: @escaping @Sendable () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(condition(), "waitUntil timed out")
    }
}

private final class BranchChangeRecorder: WorktreeMonitorDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _didFire = false

    var didFire: Bool {
        lock.lock(); defer { lock.unlock() }
        return _didFire
    }

    func worktreeMonitorDidDetectChange(_ monitor: WorktreeMonitor, repoPath: String) {}
    func worktreeMonitorDidDetectDeletion(_ monitor: WorktreeMonitor, worktreePath: String) {}
    func worktreeMonitorDidDetectBranchChange(_ monitor: WorktreeMonitor, worktreePath: String) {
        lock.lock(); defer { lock.unlock() }
        _didFire = true
    }
}
