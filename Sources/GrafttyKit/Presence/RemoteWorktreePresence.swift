import Foundation

/// One teammate worktree as rendered in the sidebar.
public struct RemoteWorktreePresence: Sendable, Equatable, Identifiable {
    public let ownerName: String
    public let ownerSlug: String
    public let name: String
    public let branch: String
    public let state: PresenceDocument.Worktree.State
    public let updatedAt: Date

    public var id: String { "\(ownerSlug)/\(name)" }

    public init(
        ownerName: String,
        ownerSlug: String,
        name: String,
        branch: String,
        state: PresenceDocument.Worktree.State,
        updatedAt: Date
    ) {
        self.ownerName = ownerName
        self.ownerSlug = ownerSlug
        self.name = name
        self.branch = branch
        self.state = state
        self.updatedAt = updatedAt
    }
}
