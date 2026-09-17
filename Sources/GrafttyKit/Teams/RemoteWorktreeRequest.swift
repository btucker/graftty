import Foundation

public enum RemoteWorktreeRequest: Codable, Sendable, Equatable {
    case create(RemoteWorktreeCreation)
    case status(operationID: String)

    public var operationID: String {
        switch self {
        case .create(let request): request.operationID
        case .status(let operationID): operationID
        }
    }
}

/// Contains prompt bytes, never a prompt-file path belonging to the source Mac.
public struct RemoteWorktreeCreation: Codable, Sendable, Equatable {
    public var callerWorktree: String
    public var project: String?
    public var origin: GitRepositoryOrigin?
    public let worktreeName: String
    public let branchName: String
    public let existing: Bool
    public let base: String?
    public let command: String?
    public let agentRuntime: TeamHookRuntime?
    public let agentPrompt: String?
    public let operationID: String

    public init(callerWorktree: String, project: String?, worktreeName: String,
                branchName: String, existing: Bool, base: String?, command: String?,
                agentRuntime: TeamHookRuntime?, agentPrompt: String?, operationID: String) {
        self.callerWorktree = callerWorktree
        self.project = project
        self.worktreeName = worktreeName
        self.branchName = branchName
        self.existing = existing
        self.base = base
        self.command = command
        self.agentRuntime = agentRuntime
        self.agentPrompt = agentPrompt
        self.operationID = operationID
    }

    public func resolvingSourceProject(
        in repos: [RepoEntry],
        readOrigin: GitRepositoryOrigin.Loader? = nil
    ) async throws -> Self {
        var result = self
        if project == nil {
            guard repos.contains(where: { repo in
                repo.worktrees.contains { $0.path == callerWorktree }
            }) else {
                throw RemoteWorktreeError("Caller is not inside a tracked project; use --project with a destination project name or absolute path")
            }
            let detectedOrigin: GitRepositoryOrigin?
            if let readOrigin {
                detectedOrigin = try await readOrigin(callerWorktree)
            } else {
                detectedOrigin = try await GitRepositoryOrigin.detect(repoPath: callerWorktree)
            }
            guard let origin = detectedOrigin else {
                throw RemoteWorktreeError("Caller project has no network origin; use --project with a destination name or absolute path")
            }
            result.origin = origin
        }
        return result
    }

    public func destinationRepository(
        in repos: [RepoEntry],
        readOrigin: GitRepositoryOrigin.Loader? = nil
    ) async throws -> RepoEntry {
        let matches: [RepoEntry]
        let selector: String
        if let project {
            guard !project.isEmpty else { throw RemoteWorktreeError("Destination project must not be empty") }
            selector = "project '\(project)'"
            matches = repos.filter {
                project.hasPrefix("/") ? $0.path == project : $0.displayName == project
            }
        } else if let origin {
            selector = "Git origin"
            var matchingRepos: [RepoEntry] = []
            for repo in repos where repo.isGitTracked {
                let detectedOrigin: GitRepositoryOrigin?
                if let readOrigin {
                    detectedOrigin = try await readOrigin(repo.path)
                } else {
                    detectedOrigin = try await GitRepositoryOrigin.detect(repoPath: repo.path)
                }
                if detectedOrigin == origin { matchingRepos.append(repo) }
            }
            matches = matchingRepos
        } else {
            throw RemoteWorktreeError("Remote worktree creation requires the caller's Git origin or an explicit --project")
        }
        guard matches.count == 1 else {
            let choices = repos.map { "\($0.displayName): \($0.path)" }.sorted().joined(separator: ", ")
            throw RemoteWorktreeError("\(matches.isEmpty ? "Unknown" : "Ambiguous") destination \(selector). Use --project with an exact name or absolute path. Available projects: \(choices.isEmpty ? "none" : choices)")
        }
        return matches[0]
    }
}

public struct RemoteWorktreeError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}
