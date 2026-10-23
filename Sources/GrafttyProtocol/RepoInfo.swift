import Foundation

/// One entry served by `GET /repos` — the set of repositories a web
/// user can create a new worktree under, mirroring the native
/// sidebar's repo disclosures. `path` is opaque to the client and
/// round-tripped as `repoPath` on `POST /worktrees` so the server
/// doesn't have to re-derive it from a display name (which could
/// collide when two repos share a basename).
public struct RepoInfo: Codable, Sendable, Equatable {
    public typealias DefaultBranchStatus = RemoteRepositoryInfo.DefaultBranchStatus

    public let path: String
    public let displayName: String
    public let defaultBranchStatus: DefaultBranchStatus?
    /// Branch metadata is optional for compatibility with older clients.
    /// Older Mobile builds use the source to distinguish a local branch
    /// from a remote-only tracking branch.
    public let branches: [RemoteRepositoryInfo.Branch]?
    /// Identifies which Mac owns the repository. Nil preserves
    /// compatibility with older servers. Relayed repositories carry a
    /// depth-1 origin so older Mobile builds can present an explicit
    /// target-Mac picker while round-tripping the opaque `path`.
    public let origin: WorktreeOrigin?

    public init(
        path: String,
        displayName: String,
        defaultBranchStatus: DefaultBranchStatus? = nil,
        branches: [RemoteRepositoryInfo.Branch]? = nil,
        origin: WorktreeOrigin? = nil
    ) {
        self.path = path
        self.displayName = displayName
        self.defaultBranchStatus = defaultBranchStatus
        self.branches = branches
        self.origin = origin
    }
}
