import Foundation

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

    public init(
        path: String,
        displayName: String,
        isCollapsed: Bool = false,
        worktrees: [WorktreeEntry] = [],
        bookmark: Data? = nil
    ) {
        self.id = UUID()
        self.path = path
        self.displayName = displayName
        self.isCollapsed = isCollapsed
        self.worktrees = worktrees
        self.bookmark = bookmark
    }

    // Custom Decodable so `bookmark` (added in LAYOUT-4.5) is optional on
    // disk. Matches the pattern `WorktreeEntry.init(from:)` uses for
    // `paneAttention` / `offeredDeleteForMergedPR` — pre-fix persisted
    // state blobs don't carry the key, `decodeIfPresent` defaults it to
    // nil, and existing users keep their state across the upgrade.
    private enum CodingKeys: String, CodingKey {
        case id, path, displayName, isCollapsed, worktrees, bookmark
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.path = try container.decode(String.self, forKey: .path)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.isCollapsed = try container.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false
        self.worktrees = try container.decode([WorktreeEntry].self, forKey: .worktrees)
        self.bookmark = try container.decodeIfPresent(Data.self, forKey: .bookmark)
    }
}
