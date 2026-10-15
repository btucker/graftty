#if os(Linux)
import Foundation

/// Linux uses a bounded polling pass over Git metadata, not the source tree.
public final class WorktreeMonitor: @unchecked Sendable {
    public weak var delegate: WorktreeMonitorDelegate?
    public var liveFdCountForTesting: Int { 0 }
    private enum Kind { case worktrees, deletion, head, origin, index }
    private struct Watch {
        let path: String
        let owner: String
        let kind: Kind
        var signature: String
    }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.graftty.worktree-monitor")
    private var watches: [String: Watch] = [:]
    private var timer: DispatchSourceTimer?

    public init() {}
    deinit { timer?.cancel() }

    public func installRepoWatchers(repo: RepoEntry) {
        watchWorktreeDirectory(repoPath: repo.path)
        watchOriginRefs(repoPath: repo.path)
        for worktree in repo.worktrees where worktree.state.hasOnDiskWorktree {
            watchWorktreePath(worktree.path)
            watchHeadRef(worktreePath: worktree.path, repoPath: repo.path)
            watchWorktreeContents(worktreePath: worktree.path)
        }
    }

    public func watchWorktreeDirectory(repoPath: String) {
        register("worktrees:\(repoPath)", path: commonGitDirectory(repoPath) + "/worktrees", owner: repoPath, kind: .worktrees)
    }
    public func watchWorktreePath(_ worktreePath: String) {
        register("path:\(worktreePath)", path: worktreePath, owner: worktreePath, kind: .deletion)
    }
    public func watchHeadRef(worktreePath: String, repoPath: String) {
        register("head:\(worktreePath)", path: gitDirectory(worktreePath) + "/HEAD", owner: worktreePath, kind: .head)
    }
    public func watchOriginRefs(repoPath: String) {
        register("origin:\(repoPath)", path: commonGitDirectory(repoPath) + "/refs/remotes", owner: repoPath, kind: .origin)
        register("packed:\(repoPath)", path: commonGitDirectory(repoPath) + "/packed-refs", owner: repoPath, kind: .origin)
    }
    public func watchWorktreeContents(worktreePath: String) {
        register("index:\(worktreePath)", path: gitDirectory(worktreePath) + "/index", owner: worktreePath, kind: .index)
    }
    public func stopWatchingWorktree(_ worktreePath: String) { remove(owner: worktreePath) }
    public func stopWatching(repoPath: String) { remove(owner: repoPath) }
    public func stopAll() {
        lock.lock()
        defer { lock.unlock() }
        watches.removeAll()
        timer?.cancel()
        timer = nil
    }

    private func register(_ key: String, path: String, owner: String, kind: Kind) {
        lock.lock()
        defer { lock.unlock() }
        guard watches[key] == nil else { return }
        watches[key] = Watch(path: path, owner: owner, kind: kind, signature: signature(path, kind: kind))
        if timer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
            timer.setEventHandler { [weak self] in self?.poll() }
            timer.resume()
            self.timer = timer
        }
    }

    private func remove(owner: String) {
        lock.lock()
        defer { lock.unlock() }
        watches = watches.filter { $0.value.owner != owner && !$0.value.owner.hasPrefix(owner + "/") }
    }

    private func poll() {
        lock.lock()
        var changed: [Watch] = []
        for (key, var watch) in watches {
            let next = signature(watch.path, kind: watch.kind)
            guard next != watch.signature else { continue }
            watch.signature = next
            watches[key] = watch
            changed.append(watch)
        }
        lock.unlock()
        for watch in changed {
            switch watch.kind {
            case .worktrees: delegate?.worktreeMonitorDidDetectChange(self, repoPath: watch.owner)
            case .deletion:
                if !FileManager.default.fileExists(atPath: watch.path) {
                    delegate?.worktreeMonitorDidDetectDeletion(self, worktreePath: watch.owner)
                }
            case .head: delegate?.worktreeMonitorDidDetectBranchChange(self, worktreePath: watch.owner)
            case .origin: delegate?.worktreeMonitorDidDetectOriginRefChange(self, repoPath: watch.owner)
            case .index: delegate?.worktreeMonitorDidDetectContentChange(self, worktreePath: watch.owner)
            }
        }
    }

    private func signature(_ path: String, kind: Kind) -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return "missing" }
        if kind == .deletion { return "present" }
        var parts = ["\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0):\(attributes[.size] ?? "")"]
        if attributes[.type] as? FileAttributeType == .typeDirectory,
           let entries = FileManager.default.enumerator(atPath: path) {
            for _ in 0..<4096 {
                guard let name = entries.nextObject() as? String else { break }
                let metadata = entries.fileAttributes ?? [:]
                parts.append("\(name):\((metadata[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0):\(metadata[.size] ?? "")")
            }
        } else if kind == .head, let head = try? String(contentsOfFile: path, encoding: .utf8) {
            parts.append(head)
        }
        return parts.sorted().joined(separator: "\n")
    }

    private func gitDirectory(_ path: String) -> String {
        let git = path + "/.git"
        if let value = try? String(contentsOfFile: git, encoding: .utf8), value.hasPrefix("gitdir: ") {
            return GitdirResolver.resolve(rawGitdir: String(value.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines), worktreePath: path)
        }
        return git
    }
    private func commonGitDirectory(_ path: String) -> String {
        let git = gitDirectory(path)
        guard let relative = try? String(contentsOfFile: git + "/commondir", encoding: .utf8) else { return git }
        return GitdirResolver.resolve(rawGitdir: relative.trimmingCharacters(in: .whitespacesAndNewlines), worktreePath: git)
    }
}
#endif
