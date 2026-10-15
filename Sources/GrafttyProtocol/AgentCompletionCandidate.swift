import Foundation

/// A routable top-level agent, with labels independent of its address.
public struct AgentCompletionCandidate: Codable, Equatable, Identifiable, Sendable {
    public var id: String { address }
    public let address: String
    public let projectPath: String
    public let projectName: String
    public let worktreePath: String
    public let worktreeName: String
    public let hostName: String
    public let runtime: String
    /// Explicit request context also covers quiet and externally located worktrees.
    public let isCurrentProject: Bool?

    public init(address: String, projectPath: String, projectName: String, worktreePath: String,
                worktreeName: String, hostName: String, runtime: String, isCurrentProject: Bool? = nil) {
        self.address = address
        self.projectPath = projectPath
        self.projectName = projectName
        self.worktreePath = worktreePath
        self.worktreeName = worktreeName
        self.hostName = hostName
        self.runtime = runtime
        self.isCurrentProject = isCurrentProject
    }

    public static func matching(_ candidates: [Self], query: String, currentWorktreePath: String?) -> [Self] {
        let currentProject = candidates.first { $0.worktreePath == currentWorktreePath }?.projectPath
            ?? candidates.filter { candidate in
                guard let currentWorktreePath else { return false }
                return currentWorktreePath == candidate.projectPath
                    || currentWorktreePath.hasPrefix(candidate.projectPath + "/")
            }.max { $0.projectPath.count < $1.projectPath.count }?.projectPath
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        var seen = Set<String>()
        return candidates.filter { candidate in
            guard seen.insert(candidate.id).inserted else { return false }
            let searchable = [candidate.worktreeName, candidate.projectName, candidate.hostName,
                              candidate.runtime, candidate.address].joined(separator: " ")
            return words.allSatisfy { searchable.localizedCaseInsensitiveContains($0) }
        }.sorted { lhs, rhs in
            let leftCurrent = lhs.isCurrentProject ?? (currentProject != nil && lhs.projectPath == currentProject)
            let rightCurrent = rhs.isCurrentProject ?? (currentProject != nil && rhs.projectPath == currentProject)
            if leftCurrent != rightCurrent { return leftCurrent }
            let left = [lhs.hostName, lhs.projectName, lhs.worktreeName, lhs.runtime, lhs.address].joined(separator: "\u{0}")
            let right = [rhs.hostName, rhs.projectName, rhs.worktreeName, rhs.runtime, rhs.address].joined(separator: "\u{0}")
            return left.localizedStandardCompare(right) == .orderedAscending
        }
    }
}
