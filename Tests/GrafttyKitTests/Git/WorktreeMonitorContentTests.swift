import Testing
import Foundation
@testable import GrafttyKit

/// Covers GIT-2.6: the recursive FSEventStream-backed watcher
/// that surfaces working-tree edits, stages (`.git/index`), and
/// untracked-file creation. The existing vnode-based watchers
/// (`watchHeadRef`, `watchOriginRefs`, `watchWorktreePath`) can't see
/// these events because they're gated on specific inodes inside
/// `.git/`, not the working tree itself.
@Suite("""
WorktreeMonitor content watcher

@spec GIT-2.6: While a worktree is in the sidebar and non-stale, the application shall recursively watch the worktree's directory with `FSEventStreamCreate` (coalescing latency 0.5s) so that working-tree edits, stages / unstages via `.git/index`, and untracked-file creation surface as content-change events. Events for the worktree root, the bare `.git` directory, and the `.git/objects/` subtree shall be filtered out: the root and `.git` are coarse parent-mtime bumps that fire alongside more specific descendant events and carry no additional signal, and `.git/objects/` is pure pack-churn noise from `git gc` / pack writes. The watched path shall be resolved via `realpath(3)` before use because FSEvents always reports canonical paths (e.g. `/private/var/...` rather than `/var/...`) and an unresolved root makes the filter's `hasPrefix` comparison miss every event. The other watchers in GIT-2.1–GIT-2.5 use kqueue vnode sources (`DispatchSourceFileSystemObject`), which cannot watch a subtree recursively; the real FSEvents API is used here because the working tree is inherently recursive.
""")
struct WorktreeMonitorContentTests {

    @Test func contentChangeFiresOnWorkingTreeFileWrite() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-content-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let recorder = ContentChangeRecorder()
        let monitor = WorktreeMonitor()
        monitor.delegate = recorder
        monitor.watchWorktreeContents(worktreePath: tmp.path)
        defer { monitor.stopAll() }

        // FSEventStreamStart returns before the stream is fully armed;
        // give it a moment so the write that follows lands inside the
        // stream's observation window (not before `kFSEventStreamEventIdSinceNow`).
        try await Task.sleep(nanoseconds: 200_000_000)

        try "hello".write(
            to: tmp.appendingPathComponent("foo.txt"),
            atomically: true,
            encoding: .utf8
        )

        try await waitUntil(timeout: 3.0) { recorder.didFire }
    }

    @Test func contentChangeFiresOnIndexUpdate() async throws {
        // `.git/index` sits under `.git/` but outside `.git/objects/`, so
        // the filter must NOT exclude it — staging a file is the
        // canonical "dirty state just changed" signal and the sidebar's
        // hasUncommittedChanges indicator depends on it.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-content-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tmp) }

        let recorder = ContentChangeRecorder()
        let monitor = WorktreeMonitor()
        monitor.delegate = recorder
        monitor.watchWorktreeContents(worktreePath: tmp.path)
        defer { monitor.stopAll() }

        try await Task.sleep(nanoseconds: 200_000_000)

        try Data([0, 1, 2, 3]).write(to: tmp.appendingPathComponent(".git/index"))

        try await waitUntil(timeout: 3.0) { recorder.didFire }
    }

    @Test func contentChangeDoesNotFireForObjectsChurn() async throws {
        // `git gc` and pack writes produce high-volume churn under
        // `.git/objects/`, none of which affects `git status` /
        // `git diff --shortstat` output. Firing a refresh for every
        // pack file would thrash the divergence subprocess pipeline
        // during a gc with no user-visible change to indicate for it.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-content-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent(".git/objects/ab"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tmp) }

        let recorder = ContentChangeRecorder()
        let monitor = WorktreeMonitor()
        monitor.delegate = recorder
        monitor.watchWorktreeContents(worktreePath: tmp.path)
        defer { monitor.stopAll() }

        try await Task.sleep(nanoseconds: 200_000_000)

        // Write deep inside `.git/objects/` — purely object churn.
        try Data([0xff]).write(
            to: tmp.appendingPathComponent(".git/objects/ab/0123456789abcdef0123456789abcdef012345")
        )

        // Give FSEvents more than the coalescing latency to deliver
        // anything it was going to deliver, then confirm no fire.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(!recorder.didFire,
                "pack-object write must be filtered; only non-.git/objects paths trigger a refresh")
    }

    @Test func stopWatchingCleansUpContentStream() async throws {
        // `stopWatching(repoPath:)` filters keys by path-boundary match —
        // must cover `content:` keys too, otherwise a repo removed from
        // the sidebar would leak its FSEvents subscription until app exit.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-content-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let recorder = ContentChangeRecorder()
        let monitor = WorktreeMonitor()
        monitor.delegate = recorder
        monitor.watchWorktreeContents(worktreePath: tmp.path)
        try await Task.sleep(nanoseconds: 200_000_000)

        monitor.stopWatching(repoPath: tmp.path)

        // Any write after stopWatching must not surface as a content change.
        try "after".write(
            to: tmp.appendingPathComponent("after.txt"),
            atomically: true,
            encoding: .utf8
        )
        try await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(!recorder.didFire,
                "stopWatching must also tear down content streams for the repoPath")
    }

    // MARK: - Helpers

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

private final class ContentChangeRecorder: WorktreeMonitorDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _didFire = false

    var didFire: Bool {
        lock.lock(); defer { lock.unlock() }
        return _didFire
    }

    func worktreeMonitorDidDetectChange(_ monitor: WorktreeMonitor, repoPath: String) {}
    func worktreeMonitorDidDetectDeletion(_ monitor: WorktreeMonitor, worktreePath: String) {}
    func worktreeMonitorDidDetectBranchChange(_ monitor: WorktreeMonitor, worktreePath: String) {}
    func worktreeMonitorDidDetectOriginRefChange(_ monitor: WorktreeMonitor, repoPath: String) {}
    func worktreeMonitorDidDetectContentChange(_ monitor: WorktreeMonitor, worktreePath: String) {
        lock.lock(); defer { lock.unlock() }
        _didFire = true
    }
}
