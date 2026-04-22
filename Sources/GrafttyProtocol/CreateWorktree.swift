import Foundation

/// One entry in the `GET /repos` response (WEB-7.1). The `path` is opaque
/// to clients and shall be round-tripped unchanged in `POST /worktrees`
/// — the server uses it to disambiguate repos whose `displayName`
/// happens to collide.
public struct RepoInfo: Codable, Sendable, Equatable, Hashable {
    public let path: String
    public let displayName: String

    public init(path: String, displayName: String) {
        self.path = path
        self.displayName = displayName
    }
}

/// Body of `POST /worktrees` (WEB-7.2). The server creates a worktree
/// at `<repoPath>/.worktrees/<worktreeName>` on a fresh branch named
/// `branchName` off the repo's resolved default branch.
public struct CreateWorktreeRequest: Codable, Sendable, Equatable {
    public let repoPath: String
    public let worktreeName: String
    public let branchName: String

    public init(repoPath: String, worktreeName: String, branchName: String) {
        self.repoPath = repoPath
        self.worktreeName = worktreeName
        self.branchName = branchName
    }
}

/// Success body of `POST /worktrees`. `sessionName` is the zmx session
/// name of the new worktree's first pane, suitable for use as the
/// `session` query parameter on `/ws`.
public struct CreateWorktreeResponse: Codable, Sendable, Equatable {
    public let sessionName: String
    public let worktreePath: String

    public init(sessionName: String, worktreePath: String) {
        self.sessionName = sessionName
        self.worktreePath = worktreePath
    }
}

/// Error body returned by `POST /worktrees` on 4xx/5xx. The server
/// surfaces `git worktree add` stderr through this field so the client
/// can show the user what git actually complained about (branch
/// already exists, invalid ref-format, etc.).
public struct CreateWorktreeErrorBody: Codable, Sendable, Equatable {
    public let error: String

    public init(error: String) {
        self.error = error
    }
}
