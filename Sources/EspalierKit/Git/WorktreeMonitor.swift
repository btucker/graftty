import Foundation

public protocol WorktreeMonitorDelegate: AnyObject {
    func worktreeMonitorDidDetectChange(_ monitor: WorktreeMonitor, repoPath: String)
    func worktreeMonitorDidDetectDeletion(_ monitor: WorktreeMonitor, worktreePath: String)
    func worktreeMonitorDidDetectBranchChange(_ monitor: WorktreeMonitor, worktreePath: String)
}

public final class WorktreeMonitor: @unchecked Sendable {
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private let queue = DispatchQueue(label: "com.espalier.worktree-monitor")
    public weak var delegate: WorktreeMonitorDelegate?

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
        source.setCancelHandler {}
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
        source.setCancelHandler {}
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
        source.setCancelHandler {}
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

    private func createFileWatcher(path: String, events: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: events, queue: queue)
        source.setCancelHandler { close(fd) }
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
