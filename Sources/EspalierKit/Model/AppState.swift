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

    public mutating func removeRepo(atPath path: String) {
        repos.removeAll { $0.path == path }
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
            .appendingPathComponent("Espalier")
    }
}
