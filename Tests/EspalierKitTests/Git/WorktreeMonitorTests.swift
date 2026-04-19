import Testing
import Foundation
@testable import EspalierKit

@Suite("WorktreeMonitor Tests")
struct WorktreeMonitorTests {

    @Test func originRefChangeFiresWhenRemoteTrackingRefsMove() async throws {
        // Covers the "gh pr create" / `git push` flow. Neither moves the
        // local HEAD, so the existing `watchHeadRef` can't see them — the
        // only local artifact is an append to `logs/refs/remotes/origin/`.
        // We simulate by writing into that directory directly (push would
        // produce the same dispatch-source signal on the directory fd).
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("espalier-originrefs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try runGit(["init", "--initial-branch=main"], cwd: tmp)
        try runGit(["commit", "--allow-empty", "-m", "init"], cwd: tmp)

        let recorder = OriginRefRecorder()
        let monitor = WorktreeMonitor()
        monitor.delegate = recorder
        monitor.watchOriginRefs(repoPath: tmp.path)

        try await Task.sleep(nanoseconds: 100_000_000)

        // Simulate what `git push origin <branch>` writes locally: the
        // reflog file under `.git/logs/refs/remotes/origin/<branch>`
        // appears / is extended. The watcher fires on directory-level
        // events regardless of which specific ref moved, which is exactly
        // what we want (refresh *all* tracked worktrees in the repo).
        let reflogDir = tmp.appendingPathComponent(".git/logs/refs/remotes/origin")
        let reflogFile = reflogDir.appendingPathComponent("branchA")
        try "0000000000000000000000000000000000000000 abcdef 1700000000 +0000\tpush\n"
            .write(to: reflogFile, atomically: true, encoding: .utf8)

        try await waitUntil(timeout: 2.0) { recorder.didFire }
    }

    // GIT-3.11: WorktreeMonitor's file-descriptor lifecycle.
    // `createFileWatcher` opens an fd via `open(path, O_EVTONLY)` and
    // installs a DispatchSource cancel handler that `close`s the fd.
    // Pre-fix, every `watch*` method IMMEDIATELY overrode that cancel
    // handler with `source.setCancelHandler {}` — a redundant empty
    // closure that silently replaced the fd-close. Result: every
    // watcher leaked its fd on `stopAll` / `stopWatching` / deinit.
    // Over enough add/remove-repo cycles (or a long-running session
    // with churning worktree set), Espalier would hit macOS's 256-fd
    // ulimit and every subsequent `open` would fail.
    //
    // This test opens many watchers, cancels them, and verifies the
    // process's open-fd count returns to baseline rather than growing
    // monotonically. Uses `/dev/fd/` — the macOS-visible enumeration of
    // a process's open file descriptors.
    @Test func watchersCloseTheirFdsWhenCancelled() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("espalier-fdleak-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Baseline fd count BEFORE any monitor activity.
        let baseline = openFdCount()

        // Each watchWorktreePath opens one fd for the watch. With the
        // pre-fix leak, 50 watch/stop cycles stack 50 fds. With the
        // fix, the per-cycle delta is zero.
        for _ in 0..<50 {
            let monitor = WorktreeMonitor()
            monitor.watchWorktreePath(tmp.path)
            monitor.stopAll()
        }

        // Let the DispatchSource cancel handlers drain on their queue.
        try await Task.sleep(nanoseconds: 200_000_000)

        let after = openFdCount()
        // Allow headroom for concurrent test execution — other suites
        // running in parallel open fds (subprocess pipes, sockets,
        // temp files) that land in this process's /dev/fd between our
        // baseline and after snapshots. Pre-fix, the per-test delta
        // was ≥50 (one fd leaked per watch/stop cycle). Post-fix, the
        // delta should be << 50; a threshold of 40 cleanly separates
        // "fixed" from "broken" even under parallel-test load.
        #expect(after - baseline < 40,
                "fd count grew by \(after - baseline) — WorktreeMonitor is leaking fds")
    }

    private func openFdCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0
    }

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
    func worktreeMonitorDidDetectOriginRefChange(_ monitor: WorktreeMonitor, repoPath: String) {}
}

private final class OriginRefRecorder: WorktreeMonitorDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _didFire = false

    var didFire: Bool {
        lock.lock(); defer { lock.unlock() }
        return _didFire
    }

    func worktreeMonitorDidDetectChange(_ monitor: WorktreeMonitor, repoPath: String) {}
    func worktreeMonitorDidDetectDeletion(_ monitor: WorktreeMonitor, worktreePath: String) {}
    func worktreeMonitorDidDetectBranchChange(_ monitor: WorktreeMonitor, worktreePath: String) {}
    func worktreeMonitorDidDetectOriginRefChange(_ monitor: WorktreeMonitor, repoPath: String) {
        lock.lock(); defer { lock.unlock() }
        _didFire = true
    }
}
