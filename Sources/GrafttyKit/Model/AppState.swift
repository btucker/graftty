import Foundation

public struct WindowFrame: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double = 100, y: Double = 100, width: Double = 1400, height: Double = 900) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public struct AppState: Codable, Sendable, Equatable {
    public var repos: [RepoEntry]
    public var selectedWorktreePath: String?
    public var windowFrame: WindowFrame
    public var sidebarWidth: Double

    public init(
        repos: [RepoEntry] = [],
        selectedWorktreePath: String? = nil,
        windowFrame: WindowFrame = WindowFrame(),
        sidebarWidth: Double = 240
    ) {
        self.repos = repos
        self.selectedWorktreePath = selectedWorktreePath
        self.windowFrame = windowFrame
        self.sidebarWidth = sidebarWidth
    }

    public mutating func addRepo(_ repo: RepoEntry) {
        guard !repos.contains(where: { $0.path == repo.path }) else { return }
        repos.append(repo)
    }

    /// Reorders worktrees inside a single repository and reapplies the
    /// stale-last invariant before publishing the new array.
    ///
    /// Returns false for an unknown repo, invalid move, or no-op order.
    @discardableResult
    public mutating func moveWorktrees(
        inRepoID repoID: RepoEntry.ID,
        movingWorktreeIDs: [WorktreeEntry.ID],
        toIndex: Int
    ) -> Bool {
        guard let repoIdx = repos.firstIndex(where: { $0.id == repoID }) else { return false }
        guard let reordered = WorktreeOrdering.move(
            repos[repoIdx].worktrees,
            movingIDs: movingWorktreeIDs,
            toIndex: toIndex
        ) else { return false }
        guard reordered != repos[repoIdx].worktrees else { return false }
        repos[repoIdx].worktrees = reordered
        return true
    }

    /// Permanently moves stale/yellow worktrees to the bottom of a repo's
    /// saved order, preserving relative order within the non-stale and
    /// stale groups.
    ///
    /// Returns false for an unknown repo or already-normalized order.
    @discardableResult
    public mutating func moveStaleWorktreesToBottom(inRepoID repoID: RepoEntry.ID) -> Bool {
        guard let repoIdx = repos.firstIndex(where: { $0.id == repoID }) else { return false }
        let reordered = WorktreeOrdering.staleLast(repos[repoIdx].worktrees)
        guard reordered != repos[repoIdx].worktrees else { return false }
        repos[repoIdx].worktrees = reordered
        return true
    }

    /// Repository-lifecycle primitive that removes the repo at `path` and
    /// preserves the "selection never points at a vanished worktree"
    /// invariant by clearing `selectedWorktreePath` when it lives under
    /// the removed repo (across any of its worktrees, including the main
    /// checkout). Analogous to `removeWorktree(atPath:)` below, but at
    /// the repo granularity — the user-visible caller is the
    /// "Remove Repository" cascade in MainWindow (`LAYOUT-4.3`).
    ///
    /// Silent no-op for an unknown path.
    public mutating func removeRepo(atPath path: String) {
        guard let repo = repos.first(where: { $0.path == path }) else { return }
        let victimPaths = Set(repo.worktrees.map(\.path))
        repos.removeAll { $0.path == path }
        if let selected = selectedWorktreePath, victimPaths.contains(selected) {
            selectedWorktreePath = nil
        }
    }

    /// Persist "this pane had focus last" on the worktree at `path`, so
    /// `TERM-2.3`'s focus-restore contract survives a worktree switch.
    ///
    /// Every pane-focus site — sidebar pane-row click, split-tree
    /// mouse-click, new-split creation, pane-close focus promotion,
    /// PWD-migration graft — must call this rather than only
    /// `TerminalManager.setFocus`. The libghostty focus alone is
    /// ephemeral (lives on the `NSView` / surface); the model state is
    /// the persisted truth that `selectWorktree` consults when
    /// restoring focus on a return visit.
    ///
    /// Silent no-op for an unknown path — keeps the call site terse at
    /// places like `TerminalContentView.onFocusTerminal` that don't
    /// have a handy "this worktree exists" invariant.
    public mutating func setFocusedTerminal(
        _ terminalID: PaneSlotID?,
        forWorktreePath path: String
    ) {
        for repoIdx in repos.indices {
            for wtIdx in repos[repoIdx].worktrees.indices
                where repos[repoIdx].worktrees[wtIdx].path == path
            {
                repos[repoIdx].worktrees[wtIdx].focusedPaneSlotID = terminalID
            }
        }
    }

    /// STATE-2.4: the user focused one pane (clicked its terminal or sidebar
    /// row) — clear just that pane's attention. Kept separate from
    /// `setFocusedTerminal` so programmatic focus restores (e.g. TERM-2.3
    /// after a worktree switch) don't wipe a pending "needs input".
    public mutating func acknowledgePaneAttention(
        _ pane: PaneSlotID,
        forWorktreePath path: String
    ) {
        for repoIdx in repos.indices {
            for wtIdx in repos[repoIdx].worktrees.indices
                where repos[repoIdx].worktrees[wtIdx].path == path
            {
                repos[repoIdx].worktrees[wtIdx].acknowledgePaneAttention(pane)
            }
        }
    }

    /// Fans the AGENT-3.4 resume rule out across every worktree on a
    /// liveness update (the per-worktree rule lives on `WorktreeEntry`):
    /// each pane whose session is now busy has its agent-stop "needs
    /// input" overlay cleared (busy and needs-input are mutually
    /// exclusive). No-op when nothing is busy.
    public mutating func clearAgentStopAttentionForBusyPanes(liveness: [String: AgentLiveness]) {
        let busy = Set(liveness.compactMap { $0.value == .busy ? $0.key : nil })
        guard !busy.isEmpty else { return }
        // Cheap early-out before any mutation: this runs on every liveness
        // change, which is frequent during active work. Only touch the model
        // when a pane-scoped agent-stop pill actually exists to clear (the
        // common steady state has none), so the @State write-back and its
        // re-render diff are skipped.
        let hasPaneAgentStop = repos.contains { repo in
            repo.worktrees.contains { wt in
                wt.paneAttention.values.contains { $0.source == .agentStop }
            }
        }
        guard hasPaneAgentStop else { return }
        for repoIdx in repos.indices {
            for wtIdx in repos[repoIdx].worktrees.indices {
                repos[repoIdx].worktrees[wtIdx].clearAgentStopAttention(forBusySessionNames: busy)
            }
        }
    }

    /// Shared primitive for the Delete Worktree (GIT-4.x) and Dismiss
    /// (GIT-3.6) paths. Removes the worktree at `path` from its
    /// enclosing repo's `worktrees` list, clears `selectedWorktreePath`
    /// if it was the removed one, and returns the removed path so the
    /// caller can pass it to `PRStatusStore.clear` /
    /// `WorktreeStatsStore.clear` to drop per-path cache entries
    /// (`GIT-4.10`).
    ///
    /// Returns nil for an unknown path — caller's "clear caches" step
    /// is then skipped naturally. Surface teardown and the git-side
    /// `git worktree remove` are the caller's responsibility; this
    /// helper owns the model + selection + "tell me what path to clean
    /// up" contract only.
    @discardableResult
    public mutating func removeWorktree(atPath path: String) -> String? {
        guard indices(forWorktreePath: path) != nil else { return nil }
        for repoIdx in repos.indices {
            repos[repoIdx].worktrees.removeAll { $0.path == path }
        }
        if selectedWorktreePath == path {
            selectedWorktreePath = nil
        }
        return path
    }

    public func worktree(forPath path: String) -> WorktreeEntry? {
        for repo in repos {
            if let wt = repo.worktrees.first(where: { $0.path == path }) {
                return wt
            }
        }
        return nil
    }

    public func repo(forWorktreePath path: String) -> RepoEntry? {
        repos.first { repo in
            repo.worktrees.contains { $0.path == path }
        }
    }

    /// `(repo, worktree)` index pair for the worktree at `path`, for
    /// callers that need to write back into `repos[...]`. The
    /// value-returning `worktree(forPath:)` helper above is sufficient
    /// for reads; mutations need the indices.
    public func indices(forWorktreePath path: String) -> (repo: Int, worktree: Int)? {
        for (ri, repo) in repos.enumerated() {
            if let wi = repo.worktrees.firstIndex(where: { $0.path == path }) {
                return (ri, wi)
            }
        }
        return nil
    }

    private static let fileName = "state.json"

    public func save(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent(Self.fileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: fileURL, options: .atomic)
    }

    public static func load(from directory: URL) throws -> AppState {
        let fileURL = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return AppState()
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(AppState.self, from: data)
    }

    /// Tries to load `state.json` from `directory`. On decode failure
    /// (corrupt file from a crashed mid-write, a hand-edit typo, or a
    /// schema mismatch), moves the corrupted file aside to
    /// `state.json.corrupt.<ms-since-epoch>` and returns a fresh empty
    /// `AppState` so the app can still boot. The user's prior data
    /// stays on disk, recoverable by hand — vastly better than the
    /// prior behavior of `try? load ?? AppState()`, which silently let
    /// the next save overwrite the broken file with fresh-empty state.
    ///
    /// A missing file is not corruption — returns empty without a
    /// backup, matching `load`'s fresh-install behavior.
    public static func loadOrFreshBackingUpCorruption(
        from directory: URL,
        now: () -> Date = { Date() }
    ) -> AppState {
        do {
            return try load(from: directory)
        } catch {
            let fileURL = directory.appendingPathComponent(fileName)
            let ms = Int(now().timeIntervalSince1970 * 1000)
            let backupURL = directory.appendingPathComponent("\(fileName).corrupt.\(ms)")
            // Best effort: if the rename fails (permissions, etc.) we
            // still return empty so the app boots. The next save will
            // overwrite the corrupt file — slightly worse UX but not
            // worse than the prior silent path.
            try? FileManager.default.moveItem(at: fileURL, to: backupURL)
            return AppState()
        }
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Graftty")
    }

    /// Snapshot of every `.running` worktree's split tree, keyed by path.
    public func runningSplitTreesByPath() -> [String: SplitTree] {
        var result: [String: SplitTree] = [:]
        for repo in repos {
            for wt in repo.worktrees where wt.state == .running {
                result[wt.path] = wt.splitTree
            }
        }
        return result
    }

    /// Reverse lookup from a leaf to its hosting worktree's `(repo, worktree)`
    /// indices. Returns nil when no worktree owns the pane (mid-reassignment).
    public func indicesOfWorktreeContaining(terminalID: PaneSlotID) -> (repo: Int, worktree: Int)? {
        for (ri, repo) in repos.enumerated() {
            for (wi, wt) in repo.worktrees.enumerated()
                where wt.splitTree.containsLeaf(terminalID) {
                return (ri, wi)
            }
        }
        return nil
    }

    /// Longest-prefix match of `path` against every worktree across every
    /// repo. Returns the matching `(repo, worktree)` indices or nil when
    /// no worktree path is a prefix of `path`. Used by both the menu's
    /// auto-detect entry (which needs the matched worktree's *name* to
    /// label the action) and the move primitive that performs the
    /// reassignment. Trailing-slash normalization on both sides prevents
    /// `/r/feat` from falsely matching `/r/feature`.
    public func worktreeIndicesMatching(path: String) -> (repo: Int, worktree: Int)? {
        var bestRepoIdx: Int?
        var bestWorktreeIdx: Int?
        var bestLen = 0
        let normalized = Self.withTrailingSlash(path)
        for (ri, repo) in repos.enumerated() {
            for (wi, wt) in repo.worktrees.enumerated() {
                let candidate = Self.withTrailingSlash(wt.path)
                if normalized.hasPrefix(candidate), candidate.count > bestLen {
                    bestLen = candidate.count
                    bestRepoIdx = ri
                    bestWorktreeIdx = wi
                }
            }
        }
        guard let bestRepoIdx, let bestWorktreeIdx else { return nil }
        return (bestRepoIdx, bestWorktreeIdx)
    }

    private static func withTrailingSlash(_ path: String) -> String {
        path.hasSuffix("/") ? path : path + "/"
    }
}
