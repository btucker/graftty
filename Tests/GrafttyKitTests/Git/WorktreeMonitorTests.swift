import Testing
import Foundation
@testable import GrafttyKit

@Suite("WorktreeMonitor Tests", .serialized)
struct WorktreeMonitorTests {

    @Test func originRefChangeFiresWhenRemoteTrackingRefsMove() async throws {
        // Covers the "gh pr create" / `git push` flow. Neither moves the
        // local HEAD, so the existing `watchHeadRef` can't see them — the
        // only local artifact is an append to `logs/refs/remotes/origin/`.
        // We simulate by writing into that directory directly (push would
        // produce the same dispatch-source signal on the directory fd).
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-originrefs-\(UUID().uuidString)")
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
    // with churning worktree set), Graftty would hit macOS's 256-fd
    // ulimit and every subsequent `open` would fail.
    //
    // This test opens many watchers, cancels them, and verifies the
    // process's open-fd count returns to baseline rather than growing
    // monotonically. Uses `/dev/fd/` — the macOS-visible enumeration of
    // a process's open file descriptors.
    @Test("""
    @spec GIT-3.11: `WorktreeMonitor`'s `DispatchSource` watchers (one per watched worktree-directory, worktree-path, HEAD reflog, and origin-refs directory) shall release their underlying file descriptors on cancel. Specifically: `createFileWatcher` installs `source.setCancelHandler { close(fd) }`, and no `watch*` method shall override that handler — DispatchSource allows only one cancel handler per source, and an override silently leaks the fd. A long-running session that churns repos (add/remove, stale/resurrect) would otherwise monotonically grow its open-fd count and eventually hit macOS's 256-fd ulimit, failing every subsequent `open` (including socket accepts, terminal PTYs, and config reloads).
    """)
    func watchersCloseTheirFdsWhenCancelled() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-fdleak-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Each watch/stop cycle opens one fd. Pre-GIT-3.11 fix, every
        // watcher leaked its fd because the `watch*` method overrode
        // `setCancelHandler` after `createFileWatcher` installed the
        // close-fd handler. Post-fix, every fd `createFileWatcher`
        // opens is closed by the cancel handler.
        //
        // This test used to sample process-wide `/dev/fd` count before
        // and after, which was flaky under concurrent-test load (other
        // suites opening subprocess/socket fds polluted the delta).
        // We now measure the monitor's OWN counter of open fds.
        let monitor = WorktreeMonitor()
        for _ in 0..<50 {
            monitor.watchWorktreePath(tmp.path)
            monitor.stopAll()
        }

        // Let the DispatchSource cancel handlers drain on their queue.
        // The counter is decremented inside the cancel handler, which
        // runs asynchronously relative to stopAll().
        for _ in 0..<50 {
            if monitor.liveFdCountForTesting == 0 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        #expect(monitor.liveFdCountForTesting == 0,
                "\(monitor.liveFdCountForTesting) fds still open on WorktreeMonitor — cancel handlers leaked")
    }

    /// `stopWatching(repoPath:)` previously filtered by
    /// `key.contains(repoPath)` — plain substring match. When two repos
    /// share a path prefix (e.g. `/projects/foo` and `/projects/foobar`),
    /// removing the shorter one would inadvertently stop watchers for
    /// the longer one too because `"worktrees:/projects/foobar"` still
    /// contains `"/projects/foo"` as a substring.
    ///
    /// The fix is a path-boundary match: a key belongs to `repoPath`
    /// iff its `<tag>:` prefix is followed by exactly `repoPath` or by
    /// a descendant (`repoPath + "/"` prefix). This test creates two
    /// prefix-colliding repos, watches both, stops one, and asserts the
    /// other's fd is still live.
    @Test func stopWatchingDoesNotAffectPrefixColidingSiblingRepos() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-prefix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Two repos that share a path prefix: `/tmp/<id>/foo` and
        // `/tmp/<id>/foobar`. Strict-prefix is the classic bug shape.
        let foo = tmp.appendingPathComponent("foo")
        let foobar = tmp.appendingPathComponent("foobar")
        try FileManager.default.createDirectory(at: foo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: foobar, withIntermediateDirectories: true)
        // Each needs a .git directory for `watchWorktreeDirectory` to open.
        try FileManager.default.createDirectory(
            at: foo.appendingPathComponent(".git/worktrees"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: foobar.appendingPathComponent(".git/worktrees"), withIntermediateDirectories: true)

        let monitor = WorktreeMonitor()
        monitor.watchWorktreeDirectory(repoPath: foo.path)
        monitor.watchWorktreeDirectory(repoPath: foobar.path)
        #expect(monitor.liveFdCountForTesting == 2)

        // Stop the shorter-prefix repo. With the substring bug, this
        // ALSO cancels the foobar watcher; with the fix, foobar remains.
        monitor.stopWatching(repoPath: foo.path)

        // Let the DispatchSource cancel handler drain; liveFdCount drops
        // by the count actually cancelled.
        for _ in 0..<50 {
            if monitor.liveFdCountForTesting <= 1 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(monitor.liveFdCountForTesting == 1,
                "stopWatching('/foo') wrongly cancelled '/foobar' (liveFdCount=\(monitor.liveFdCountForTesting))")

        monitor.stopAll()
    }

    @Test func branchChangeFiresOnCommit() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-monitor-\(UUID().uuidString)")
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

    /// `watchWorktreePath` opens a DispatchSource on the worktree's
    /// inode fd. When the user `rm -rf`'s the worktree, the event
    /// fires and the app transitions the entry to `.stale`. But the
    /// source stays in the monitor's dict watching the reaped inode.
    /// A subsequent `git worktree add` at the same path would
    /// otherwise re-enter the reconciler's idempotent re-register
    /// path (key exists → bail) and leave the new inode uncovered.
    /// `GIT-3.15` gives the app a way out: `stopWatchingWorktree`
    /// drops the three worktree-scoped entries for a single path so
    /// the next `watch*` cleanly re-arms against the new inode.
    @Test("""
    @spec GIT-3.15: When a worktree transitions to the `.stale` state — regardless of which channel observed it (`worktreeMonitorDidDetectDeletion` for the FSEvents path, or `reconcileOnLaunch` / `worktreeMonitorDidDetectChange` when `git worktree list --porcelain` stops listing an entry) — the application shall call `WorktreeMonitor.stopWatchingWorktree(_:)` to drop the path / HEAD-reflog / content watchers for that worktree. Otherwise the watchers stay registered with fds bound to the reaped inode. A subsequent `git worktree add` at the same path (resurrection) would hit the reconciler's "idempotent" re-register (`guard sources[key] == nil else { return }`) and leave the new inode uncovered — the next `rm -rf` would go undetected, and `git commit` would not refresh PR / divergence state until the 30s / 5m polling safety nets catch up. The three stale-transition paths must be symmetric on this, matching `GIT-3.13`'s rule for the stats / PR cache clear.
    """)
    func stopWatchingWorktreeDropsPathAndHeadAndContentWatchers() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-rearm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Seed `.git/logs/HEAD` so `watchHeadRef` has a real file to
        // arm on — otherwise `createFileWatcher`'s `open()` fails and
        // no fd is counted.
        let gitDir = tmp.appendingPathComponent(".git/logs")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try "".write(
            to: gitDir.appendingPathComponent("HEAD"),
            atomically: true, encoding: .utf8
        )

        let monitor = WorktreeMonitor()
        monitor.watchWorktreePath(tmp.path)
        monitor.watchHeadRef(worktreePath: tmp.path, repoPath: tmp.path)
        monitor.watchWorktreeContents(worktreePath: tmp.path)
        // path + head = 2 fds. Content is an FSEventStream, not an fd.
        #expect(monitor.liveFdCountForTesting == 2)

        monitor.stopWatchingWorktree(tmp.path)

        for _ in 0..<50 {
            if monitor.liveFdCountForTesting == 0 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(
            monitor.liveFdCountForTesting == 0,
            "stopWatchingWorktree must drop path + head fds; got \(monitor.liveFdCountForTesting)"
        )

        // Re-register should now reopen a fresh fd per watcher.
        monitor.watchWorktreePath(tmp.path)
        monitor.watchHeadRef(worktreePath: tmp.path, repoPath: tmp.path)
        #expect(
            monitor.liveFdCountForTesting == 2,
            "re-register after stopWatchingWorktree should reopen fresh fds; got \(monitor.liveFdCountForTesting)"
        )
        monitor.stopAll()
    }
}

private final class DeletionRecorder: WorktreeMonitorDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _didFire = false

    var didFire: Bool {
        lock.lock(); defer { lock.unlock() }
        return _didFire
    }

    func worktreeMonitorDidDetectChange(_ monitor: WorktreeMonitor, repoPath: String) {}
    func worktreeMonitorDidDetectDeletion(_ monitor: WorktreeMonitor, worktreePath: String) {
        lock.lock(); defer { lock.unlock() }
        _didFire = true
    }
    func worktreeMonitorDidDetectBranchChange(_ monitor: WorktreeMonitor, worktreePath: String) {}
    func worktreeMonitorDidDetectOriginRefChange(_ monitor: WorktreeMonitor, repoPath: String) {}
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
