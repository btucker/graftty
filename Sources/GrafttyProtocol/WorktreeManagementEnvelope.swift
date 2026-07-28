import Foundation

/// Repository and branch metadata used by both the native and Mobile
/// Add Worktree flows. Identifiers are opaque round-trip tokens; clients
/// must never infer filesystem paths from them.
public struct RemoteRepositoryInfo: Codable, Sendable, Hashable {
    public struct DefaultBranchStatus: Codable, Sendable, Hashable {
        public let branchName: String
        public let remoteRef: String
        public let behindCount: Int

        public init(branchName: String, remoteRef: String, behindCount: Int) {
            self.branchName = branchName
            self.remoteRef = remoteRef
            self.behindCount = behindCount
        }
    }

    public struct Branch: Codable, Sendable, Hashable {
        public enum Source: String, Codable, Sendable, Hashable {
            case local
            case remoteOnly = "remote_only"
            /// Resolve the exact local or origin-tracking ref on the owning
            /// Mac. Used when a free-form client has no fresh branch snapshot.
            case automatic
        }

        public struct PullRequest: Codable, Sendable, Hashable {
            public let number: Int
            public let title: String

            public init(number: Int, title: String) {
                self.number = number
                self.title = title
            }
        }

        public let name: String
        public let source: Source
        public let lastCommitDate: Date
        public let mountedWorktreeID: String?
        public let pullRequest: PullRequest?

        public init(
            name: String,
            source: Source,
            lastCommitDate: Date,
            mountedWorktreeID: String?,
            pullRequest: PullRequest?
        ) {
            self.name = name
            self.source = source
            self.lastCommitDate = lastCommitDate
            self.mountedWorktreeID = mountedWorktreeID
            self.pullRequest = pullRequest
        }
    }

    public let id: String
    public let displayName: String
    public let origin: WorktreeOrigin?
    public let defaultBranchStatus: DefaultBranchStatus?
    public let branches: [Branch]

    public init(
        id: String,
        displayName: String,
        origin: WorktreeOrigin?,
        defaultBranchStatus: DefaultBranchStatus?,
        branches: [Branch]
    ) {
        self.id = id
        self.displayName = displayName
        self.origin = origin
        self.defaultBranchStatus = defaultBranchStatus
        self.branches = branches
    }
}

/// Requests on `worktree-management@graftty.dev`.
public enum WorktreeManagementRequest: Sendable, Equatable {
    case listRepositories
    case create(repositoryID: String, worktreeName: String, branchName: String, existingSource: RemoteRepositoryInfo.Branch.Source?)
    case pullDefaultBranch(repositoryID: String)
    case open(worktreeID: String)
    case delete(worktreeID: String, force: Bool)
    case acknowledge(worktreeID: String, paneID: String?)
}

extension WorktreeManagementRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, repositoryID, worktreeID, worktreeName, branchName,
             existingSource, force, paneID
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .listRepositories:
            try c.encode("list_repositories", forKey: .type)
        case let .create(repositoryID, worktreeName, branchName, existingSource):
            try c.encode("create", forKey: .type)
            try c.encode(repositoryID, forKey: .repositoryID)
            try c.encode(worktreeName, forKey: .worktreeName)
            try c.encode(branchName, forKey: .branchName)
            try c.encodeIfPresent(existingSource, forKey: .existingSource)
        case .pullDefaultBranch(let repositoryID):
            try c.encode("pull_default_branch", forKey: .type)
            try c.encode(repositoryID, forKey: .repositoryID)
        case .open(let worktreeID):
            try c.encode("open", forKey: .type)
            try c.encode(worktreeID, forKey: .worktreeID)
        case let .delete(worktreeID, force):
            try c.encode("delete", forKey: .type)
            try c.encode(worktreeID, forKey: .worktreeID)
            try c.encode(force, forKey: .force)
        case let .acknowledge(worktreeID, paneID):
            try c.encode("acknowledge", forKey: .type)
            try c.encode(worktreeID, forKey: .worktreeID)
            try c.encodeIfPresent(paneID, forKey: .paneID)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "list_repositories":
            self = .listRepositories
        case "create":
            self = .create(
                repositoryID: try c.decode(String.self, forKey: .repositoryID),
                worktreeName: try c.decode(String.self, forKey: .worktreeName),
                branchName: try c.decode(String.self, forKey: .branchName),
                existingSource: try c.decodeIfPresent(
                    RemoteRepositoryInfo.Branch.Source.self,
                    forKey: .existingSource
                )
            )
        case "pull_default_branch":
            self = .pullDefaultBranch(
                repositoryID: try c.decode(String.self, forKey: .repositoryID)
            )
        case "open":
            self = .open(
                worktreeID: try c.decode(String.self, forKey: .worktreeID)
            )
        case "delete":
            self = .delete(
                worktreeID: try c.decode(String.self, forKey: .worktreeID),
                force: try c.decodeIfPresent(Bool.self, forKey: .force) ?? false
            )
        case "acknowledge":
            self = .acknowledge(
                worktreeID: try c.decode(String.self, forKey: .worktreeID),
                paneID: try c.decodeIfPresent(String.self, forKey: .paneID)
            )
        case let type:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: c,
                debugDescription: "unknown WorktreeManagementRequest type: \(type)"
            )
        }
    }
}

public enum WorktreeManagementResponse: Sendable, Equatable {
    case repositories([RemoteRepositoryInfo])
    case created(worktreeID: String, paneID: String)
    case deleted(dismissed: Bool)
    case ok
    case error(code: String, message: String, forceAllowed: Bool, shortStatus: String?)
}

extension WorktreeManagementResponse: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, repositories, worktreeID, paneID, dismissed, code, message,
             forceAllowed, shortStatus
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .repositories(let repositories):
            try c.encode("repositories", forKey: .type)
            try c.encode(repositories, forKey: .repositories)
        case let .created(worktreeID, paneID):
            try c.encode("created", forKey: .type)
            try c.encode(worktreeID, forKey: .worktreeID)
            try c.encode(paneID, forKey: .paneID)
        case .deleted(let dismissed):
            try c.encode("deleted", forKey: .type)
            try c.encode(dismissed, forKey: .dismissed)
        case .ok:
            try c.encode("ok", forKey: .type)
        case let .error(code, message, forceAllowed, shortStatus):
            try c.encode("error", forKey: .type)
            try c.encode(code, forKey: .code)
            try c.encode(message, forKey: .message)
            try c.encode(forceAllowed, forKey: .forceAllowed)
            try c.encodeIfPresent(shortStatus, forKey: .shortStatus)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "repositories":
            self = .repositories(
                try c.decode([RemoteRepositoryInfo].self, forKey: .repositories)
            )
        case "created":
            self = .created(
                worktreeID: try c.decode(String.self, forKey: .worktreeID),
                paneID: try c.decode(String.self, forKey: .paneID)
            )
        case "deleted":
            self = .deleted(
                dismissed: try c.decodeIfPresent(Bool.self, forKey: .dismissed) ?? false
            )
        case "ok":
            self = .ok
        case "error":
            self = .error(
                code: try c.decode(String.self, forKey: .code),
                message: try c.decode(String.self, forKey: .message),
                forceAllowed: try c.decodeIfPresent(Bool.self, forKey: .forceAllowed) ?? false,
                shortStatus: try c.decodeIfPresent(String.self, forKey: .shortStatus)
            )
        case let type:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: c,
                debugDescription: "unknown WorktreeManagementResponse type: \(type)"
            )
        }
    }
}
