import Foundation

public struct RepoEntry: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let path: String
    public var displayName: String
    public var isCollapsed: Bool
    public var worktrees: [WorktreeEntry]

    public init(
        path: String,
        displayName: String,
        isCollapsed: Bool = false,
        worktrees: [WorktreeEntry] = []
    ) {
        self.id = UUID()
        self.path = path
        self.displayName = displayName
        self.isCollapsed = isCollapsed
        self.worktrees = worktrees
    }
}
