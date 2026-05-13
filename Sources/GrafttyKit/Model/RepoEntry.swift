import Foundation

/// @spec PROJECT-1.0
/// Each repository entry shall record whether its on-disk path is tracked by git.
public struct RepoEntry: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var path: String
    public var displayName: String
    public var isCollapsed: Bool
    public var worktrees: [WorktreeEntry]
    /// macOS URL bookmark for the repo folder, minted at add-time. Enables
    /// transparent recovery when the user renames or moves the folder in
    /// Finder (LAYOUT-4.5 .. LAYOUT-4.9). `nil` for entries decoded from a
    /// pre-LAYOUT-4.5 `state.json`; lazily minted on first successful path
    /// resolution after upgrade (LAYOUT-4.9).
    public var bookmark: Data?
    /// Whether this entry's on-disk path is tracked by git.
    /// Pre-feature `state.json` blobs lack this key — `init(from:)` defaults
    /// it to `true` (PROJECT-1.5) so existing users load unchanged.
    public var isGitTracked: Bool

    public init(
        path: String,
        displayName: String,
        isCollapsed: Bool = false,
        worktrees: [WorktreeEntry] = [],
        bookmark: Data? = nil,
        isGitTracked: Bool = true
    ) {
        self.id = UUID()
        self.path = path
        self.displayName = displayName
        self.isCollapsed = isCollapsed
        self.worktrees = worktrees
        self.bookmark = bookmark
        self.isGitTracked = isGitTracked
    }

    // Custom Decodable so `bookmark` (added in LAYOUT-4.5) is optional on
    // disk. Matches the pattern `WorktreeEntry.init(from:)` uses for
    // `paneAttention` / `offeredDeleteForResolvedPR` — pre-fix persisted
    // state blobs don't carry the key, `decodeIfPresent` defaults it to
    // nil, and existing users keep their state across the upgrade.
    private enum CodingKeys: String, CodingKey {
        case id, path, displayName, isCollapsed, worktrees, bookmark, isGitTracked
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.path = try container.decode(String.self, forKey: .path)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.isCollapsed = try container.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false
        self.worktrees = try container.decode([WorktreeEntry].self, forKey: .worktrees)
        self.bookmark = try container.decodeIfPresent(Data.self, forKey: .bookmark)
        self.isGitTracked = try container.decodeIfPresent(Bool.self, forKey: .isGitTracked) ?? true
    }
}

extension RepoEntry {
    /// Path of the on-disk worktree currently checked out at `branch`,
    /// or nil if no on-disk worktree of this repo uses that branch.
    /// `.creating` placeholders are intentionally excluded — git would
    /// let the user mount the branch even with a placeholder present.
    public func branchMountedPath(_ branch: String) -> String? {
        worktrees.first { $0.branch == branch && $0.state.hasOnDiskWorktree }?.path
    }
}
