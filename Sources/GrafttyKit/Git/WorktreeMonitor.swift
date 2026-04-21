import Foundation
import CoreServices

public protocol WorktreeMonitorDelegate: AnyObject {
    func worktreeMonitorDidDetectChange(_ monitor: WorktreeMonitor, repoPath: String)
    func worktreeMonitorDidDetectDeletion(_ monitor: WorktreeMonitor, worktreePath: String)
    func worktreeMonitorDidDetectBranchChange(_ monitor: WorktreeMonitor, worktreePath: String)
    func worktreeMonitorDidDetectOriginRefChange(_ monitor: WorktreeMonitor, repoPath: String)
    /// Fires when any non-`.git/objects` path inside the worktree changes
    /// (working tree edit, stage/unstage via `.git/index`, untracked file
    /// added). Lets the stats store recompute `hasUncommittedChanges` and
    /// `git diff --shortstat` counts without waiting for the 30s local
    /// poll tick.
    func worktreeMonitorDidDetectContentChange(_ monitor: WorktreeMonitor, worktreePath: String)
}

public extension WorktreeMonitorDelegate {
    // Default no-op so existing test recorders don't need to implement the
    // new callback. Production delegate in GrafttyApp implements it.
    func worktreeMonitorDidDetectContentChange(_ monitor: WorktreeMonitor, worktreePath: String) {}
}

public final class WorktreeMonitor: @unchecked Sendable {
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var contentStreams: [String: ContentStream] = [:]
    private let queue = DispatchQueue(label: "com.graftty.worktree-monitor")
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

    /// Install the full watcher set for a repo and its non-stale worktrees.
    /// Used at launch (`startup`), after a relocate (LAYOUT-4.8), and
    /// whenever a repo's worktree membership changes. The per-worktree
    /// install is idempotent on the monitor's side (duplicate registers
    /// coalesce by path key), so calling this multiple times with overlapping
    /// repos is safe — it just no-ops the ones already armed.
    public func installRepoWatchers(repo: RepoEntry) {
        watchWorktreeDirectory(repoPath: repo.path)
        watchOriginRefs(repoPath: repo.path)
        for wt in repo.worktrees where wt.state != .stale {
            watchWorktreePath(wt.path)
            watchHeadRef(worktreePath: wt.path, repoPath: repo.path)
            watchWorktreeContents(worktreePath: wt.path)
        }
    }

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

    /// Drop the path / head / content watchers for `worktreePath` and
    /// close their fds. Narrower than `stopWatching(repoPath:)`: matches
    /// exactly the three worktree-scoped keys (`path:` / `head:` /
    /// `content:`), leaving repo-scoped watchers (`worktrees:` /
    /// `originrefs:`) alone.
    ///
    /// Called by the app's `worktreeMonitorDidDetectDeletion` handler
    /// so a subsequent `git worktree add` at the same path (reconcile
    /// → resurrect) reopens fresh fds rather than re-register-no-op'ing
    /// against zombie fds bound to the reaped inode. `GIT-3.15`.
    public func stopWatchingWorktree(_ worktreePath: String) {
        for tag in ["path", "head", "content"] {
            let key = "\(tag):\(worktreePath)"
            sources.removeValue(forKey: key)?.cancel()
            contentStreams.removeValue(forKey: key)?.cancel()
        }
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

    /// Recursively watches the worktree's working tree using FSEvents, so
    /// edits, stages (`.git/index`), and untracked-file creation that the
    /// HEAD-reflog and origin-refs watchers can't see still bump the
    /// divergence indicator promptly. Events under `.git/objects/` are
    /// filtered out — object churn from `git gc` / pack writes doesn't
    /// affect `git status` or `git diff --shortstat` output and would
    /// otherwise fire thousands of no-op refreshes. One stream per
    /// worktree, coalesced with a 0.5s latency.
    public func watchWorktreeContents(worktreePath: String) {
        let key = "content:\(worktreePath)"
        guard contentStreams[key] == nil else { return }
        guard let stream = ContentStream.make(
            worktreePath: worktreePath,
            queue: queue,
            onChange: { [weak self] in
                guard let self else { return }
                self.delegate?.worktreeMonitorDidDetectContentChange(self, worktreePath: worktreePath)
            }
        ) else { return }
        contentStreams[key] = stream
    }

    public func stopWatching(repoPath: String) {
        // Keys have the shape `<tag>:<path>` where path is either the
        // repoPath itself (for repo-scoped watchers like `worktrees:` /
        // `originrefs:`) or a descendant (for worktree-scoped watchers
        // `path:` / `head:` / `content:`). A plain `key.contains(repoPath)`
        // would also match sibling repos whose path is a proper prefix —
        // e.g. stopping `/projects/foo` would wrongly cancel watchers for
        // `/projects/foobar` too, because the stringified key
        // `"worktrees:/projects/foobar"` contains `"/projects/foo"` as
        // a substring. Test: `stopWatchingDoesNotAffectPrefixCollidingSiblingRepos`.
        let matches: (String) -> Bool = { key in
            guard let colonIdx = key.firstIndex(of: ":") else { return false }
            let path = key[key.index(after: colonIdx)...]
            return path == repoPath || path.hasPrefix(repoPath + "/")
        }
        for key in sources.keys.filter(matches) {
            sources[key]?.cancel()
            sources.removeValue(forKey: key)
        }
        for key in contentStreams.keys.filter(matches) {
            contentStreams[key]?.cancel()
            contentStreams.removeValue(forKey: key)
        }
    }

    public func stopAll() {
        for source in sources.values { source.cancel() }
        sources.removeAll()
        for stream in contentStreams.values { stream.cancel() }
        contentStreams.removeAll()
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

    func resolveHeadLogPath(worktreePath: String, repoPath: String) -> String {
        if worktreePath == repoPath { return "\(repoPath)/.git/logs/HEAD" }
        let gitFilePath = "\(worktreePath)/.git"
        if let contents = try? String(contentsOfFile: gitFilePath, encoding: .utf8),
           contents.hasPrefix("gitdir: ") {
            let raw = String(contents
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .dropFirst("gitdir: ".count))
            let absolute = GitdirResolver.resolve(rawGitdir: raw, worktreePath: worktreePath)
            return URL(fileURLWithPath: absolute).appendingPathComponent("logs/HEAD").path
        }
        let name = URL(fileURLWithPath: worktreePath).lastPathComponent
        return "\(repoPath)/.git/worktrees/\(name)/logs/HEAD"
    }
}

/// Captured by the FSEvents C callback via a retained `Unmanaged`
/// pointer. File-private so the callback (also file-private) can name it
/// directly rather than going through a type-erased cast.
fileprivate final class ContentStreamContext {
    let onChange: () -> Void
    let objectsDir: String
    let gitDir: String
    let worktreeRoot: String

    init(worktreePath: String, onChange: @escaping () -> Void) {
        self.onChange = onChange
        // FSEvents reports canonical (symlink-resolved) paths — on
        // macOS `/var` is a symlink to `/private/var`, so a worktree at
        // `/var/folders/...` receives events prefixed with
        // `/private/var/folders/...`. `URL.resolvingSymlinksInPath()`
        // does NOT collapse the `/var` → `/private/var` system symlink;
        // only `realpath(3)` does, which is what FSEvents uses
        // internally. Without this, the filter's `hasPrefix` check
        // misses every event and everything falls through to `onChange`.
        let resolved: String = {
            guard let cStr = realpath(worktreePath, nil) else { return worktreePath }
            defer { free(cStr) }
            return String(cString: cStr)
        }()
        let rootWithoutSlash = resolved.hasSuffix("/") ? String(resolved.dropLast()) : resolved
        self.worktreeRoot = rootWithoutSlash
        self.gitDir = rootWithoutSlash + "/.git"
        // Filter `.git/objects` and every descendant. Use two checks
        // (exact match OR `<dir>/` prefix) because FSEvents delivers
        // directory-level events without a trailing slash; a plain
        // `hasPrefix("<dir>/")` would miss the event fired on the
        // `objects/` directory itself when a child is created.
        self.objectsDir = rootWithoutSlash + "/.git/objects"
    }

    func shouldIgnore(_ path: String) -> Bool {
        // Ignore bare-directory events for the worktree root and the
        // `.git` directory itself. These fire as parent-mtime bumps
        // alongside a more specific descendant event (e.g. a write to
        // `.git/index` delivers BOTH `<root>/.git/index` AND `<root>/.git`),
        // so dropping them loses no signal. We need to drop them
        // explicitly because otherwise a pure `.git/objects/` churn —
        // which should be fully filtered — slips through via the bare
        // `.git` parent event that it also triggers.
        if path == worktreeRoot { return true }
        if path == gitDir { return true }
        if path == objectsDir { return true }
        if path.hasPrefix(objectsDir + "/") { return true }
        return false
    }
}

/// RAII holder for an `FSEventStreamRef`. Owns the stream + the
/// `Unmanaged<ContentStreamContext>` it captures, so `cancel()` tears
/// down both in the correct order (stop → invalidate → release stream,
/// then release the Unmanaged).
fileprivate final class ContentStream {
    private let stream: FSEventStreamRef
    private let context: Unmanaged<ContentStreamContext>

    private init(stream: FSEventStreamRef, context: Unmanaged<ContentStreamContext>) {
        self.stream = stream
        self.context = context
    }

    static func make(
        worktreePath: String,
        queue: DispatchQueue,
        onChange: @escaping () -> Void
    ) -> ContentStream? {
        let ctxObj = ContentStreamContext(worktreePath: worktreePath, onChange: onChange)
        let unmanaged = Unmanaged.passRetained(ctxObj)

        var ctx = FSEventStreamContext(
            version: 0,
            info: unmanaged.toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let paths = [worktreePath] as CFArray
        // Note: no `kFSEventStreamCreateFlagIgnoreSelf`. That flag drops
        // events whose writer PID matches our own; Graftty itself
        // generally doesn't write to worktree files, but any future code
        // that does (e.g. a future in-process `git` binding) must still
        // trigger a stats refresh just like an external editor would.
        // Subprocess writes (`git worktree add`, user shell commands)
        // have different PIDs and are therefore never filtered.
        let flags = UInt32(
            kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagUseCFTypes
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            contentCallback,
            &ctx,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            flags
        ) else {
            unmanaged.release()
            return nil
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            unmanaged.release()
            return nil
        }
        return ContentStream(stream: stream, context: unmanaged)
    }

    func cancel() {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        context.release()
    }
}

/// FSEventStream C callback. With `kFSEventStreamCreateFlagUseCFTypes`
/// set, `eventPaths` is a `CFArray` of `CFString`. Fires `onChange` once
/// per callback as long as at least one event path is outside
/// `.git/objects/` — object-pack churn from `git gc` would otherwise
/// trigger thousands of no-op refreshes without affecting divergence.
fileprivate let contentCallback: FSEventStreamCallback = { _, clientCallBackInfo, _, eventPaths, _, _ in
    guard let clientCallBackInfo else { return }
    let ctx = Unmanaged<ContentStreamContext>.fromOpaque(clientCallBackInfo).takeUnretainedValue()

    let cfPaths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
    for case let path as String in (cfPaths as NSArray) {
        if ctx.shouldIgnore(path) { continue }
        ctx.onChange()
        return
    }
}
