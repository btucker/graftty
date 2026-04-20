import Foundation

public protocol WorktreeMonitorDelegate: AnyObject {
    func worktreeMonitorDidDetectChange(_ monitor: WorktreeMonitor, repoPath: String)
    func worktreeMonitorDidDetectDeletion(_ monitor: WorktreeMonitor, worktreePath: String)
    func worktreeMonitorDidDetectBranchChange(_ monitor: WorktreeMonitor, worktreePath: String)
    func worktreeMonitorDidDetectOriginRefChange(_ monitor: WorktreeMonitor, repoPath: String)
}

public final class WorktreeMonitor: @unchecked Sendable {
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private let queue = DispatchQueue(label: "com.espalier.worktree-monitor")
    public weak var delegate: WorktreeMonitorDelegate?

    /// Test-only: count of fds opened by `createFileWatcher` that have
    /// not yet been closed by their DispatchSource cancel handler. Reads
    /// after `stopAll` should be zero; a non-zero residue means a caller
    /// has overridden `setCancelHandler` (the `GIT-3.11` regression).
    /// Mutated under `fdCounterLock` because the cancel handler runs on
    /// `queue` while test reads happen on the main actor.
    private let fdCounterLock = NSLock()
    private var _liveFdCount: Int = 0
    public var liveFdCountForTesting: Int {
        fdCounterLock.lock()
        defer { fdCounterLock.unlock() }
        return _liveFdCount
    }

    public init() {}

    deinit { stopAll() }

    public func watchWorktreeDirectory(repoPath: String) {
        let gitWorktreesDir = "\(repoPath)/.git/worktrees"
        try? FileManager.default.createDirectory(atPath: gitWorktreesDir, withIntermediateDirectories: true)
        let key = "worktrees:\(repoPath)"
        guard sources[key] == nil else { return }
        guard let source = createFileWatcher(path: gitWorktreesDir, events: [.write, .link]) else { return }
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.delegate?.worktreeMonitorDidDetectChange(self, repoPath: repoPath)
        }
        source.resume()
        sources[key] = source
    }

    public func watchWorktreePath(_ worktreePath: String) {
        let key = "path:\(worktreePath)"
        guard sources[key] == nil else { return }
        guard let source = createFileWatcher(path: worktreePath, events: [.delete, .rename]) else { return }
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if !FileManager.default.fileExists(atPath: worktreePath) {
                self.delegate?.worktreeMonitorDidDetectDeletion(self, worktreePath: worktreePath)
            }
        }
        source.resume()
        sources[key] = source
    }

    /// Watches the HEAD reflog (`logs/HEAD`) rather than the HEAD file itself:
    /// `git commit` updates the branch ref via atomic rename and leaves HEAD's
    /// inode/mtime alone, so a `.write` watcher on HEAD silently misses local
    /// commits. The reflog is appended in place for every HEAD movement.
    public func watchHeadRef(worktreePath: String, repoPath: String) {
        let reflogPath = resolveHeadLogPath(worktreePath: worktreePath, repoPath: repoPath)
        let key = "head:\(worktreePath)"
        guard sources[key] == nil else { return }
        guard let source = createFileWatcher(path: reflogPath, events: [.write, .extend]) else { return }
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.delegate?.worktreeMonitorDidDetectBranchChange(self, worktreePath: worktreePath)
        }
        source.resume()
        sources[key] = source
    }

    /// Watches `<repoPath>/.git/logs/refs/remotes/origin/` — the dir
    /// git appends to on every remote-tracking-ref movement (push,
    /// fetch, prune). Catches the `gh pr create` / `git push` flow,
    /// which doesn't move HEAD and is therefore invisible to the
    /// per-worktree HEAD watcher. One watch per repo covers every
    /// linked worktree, since they share the main repo's git dir.
    ///
    /// The directory is created if missing so the watch can arm before
    /// the first push ever creates a reflog file inside it. A packed-
    /// refs regime (`git gc`) leaves the `logs/` side of refs intact.
    public func watchOriginRefs(repoPath: String) {
        let dir = "\(repoPath)/.git/logs/refs/remotes/origin"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let key = "originrefs:\(repoPath)"
        guard sources[key] == nil else { return }
        guard let source = createFileWatcher(path: dir, events: [.write, .extend, .link]) else { return }
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.delegate?.worktreeMonitorDidDetectOriginRefChange(self, repoPath: repoPath)
        }
        source.resume()
        sources[key] = source
    }

    public func stopWatching(repoPath: String) {
        let keysToRemove = sources.keys.filter { $0.contains(repoPath) }
        for key in keysToRemove {
            sources[key]?.cancel()
            sources.removeValue(forKey: key)
        }
    }

    public func stopAll() {
        for source in sources.values { source.cancel() }
        sources.removeAll()
    }

    /// Opens an fd on `path` and wraps it in a dispatch source that
    /// closes the fd on cancel. Callers MUST NOT call
    /// `source.setCancelHandler(...)` on the returned source — doing so
    /// silently replaces the fd-close handler and leaks the fd. `GIT-3.11`.
    private func createFileWatcher(path: String, events: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        fdCounterLock.lock(); _liveFdCount += 1; fdCounterLock.unlock()
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: events, queue: queue)
        let lock = fdCounterLock
        source.setCancelHandler { [weak self] in
            close(fd)
            lock.lock()
            self?._liveFdCount -= 1
            lock.unlock()
        }
        return source
    }

    private func resolveHeadLogPath(worktreePath: String, repoPath: String) -> String {
        if worktreePath == repoPath { return "\(repoPath)/.git/logs/HEAD" }
        let gitFilePath = "\(worktreePath)/.git"
        if let contents = try? String(contentsOfFile: gitFilePath, encoding: .utf8),
           contents.hasPrefix("gitdir: ") {
            let gitDir = contents.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst("gitdir: ".count)
            return "\(gitDir)/logs/HEAD"
        }
        let name = URL(fileURLWithPath: worktreePath).lastPathComponent
        return "\(repoPath)/.git/worktrees/\(name)/logs/HEAD"
    }
}
