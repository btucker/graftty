/// One entry served by `GET /sessions`. Minimum useful shape for a
/// client's session picker (`WEB-5.4`): `name` is the URL segment
/// under `/session/`, and the label hints let the picker disambiguate
/// multiple worktrees sharing a directory basename.
public struct SessionInfo: Codable, Sendable, Equatable {
    public let name: String
    public let worktreePath: String
    public let repoDisplayName: String
    public let worktreeDisplayName: String

    public init(
        name: String,
        worktreePath: String,
        repoDisplayName: String,
        worktreeDisplayName: String
    ) {
        self.name = name
        self.worktreePath = worktreePath
        self.repoDisplayName = repoDisplayName
        self.worktreeDisplayName = worktreeDisplayName
    }
}
