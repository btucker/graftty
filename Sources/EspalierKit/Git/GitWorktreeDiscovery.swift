import Foundation

public struct DiscoveredWorktree: Sendable {
    public let path: String
    public let branch: String
}

public enum GitWorktreeDiscovery {
    public static func parsePorcelain(_ output: String) -> [DiscoveredWorktree] {
        var results: [DiscoveredWorktree] = []
        var currentPath: String?
        var currentBranch: String?

        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("worktree ") {
                if let path = currentPath {
                    results.append(DiscoveredWorktree(path: path, branch: currentBranch ?? "(unknown)"))
                }
                currentPath = String(line.dropFirst("worktree ".count))
                currentBranch = nil
            } else if line.hasPrefix("branch refs/heads/") {
                currentBranch = String(line.dropFirst("branch refs/heads/".count))
            } else if line == "detached" {
                currentBranch = "(detached)"
            } else if line == "bare" {
                currentBranch = "(bare)"
            }
        }

        if let path = currentPath {
            results.append(DiscoveredWorktree(path: path, branch: currentBranch ?? "(unknown)"))
        }

        return results
    }

    public static func discover(repoPath: String) throws -> [DiscoveredWorktree] {
        do {
            let output = try GitRunner.run(args: ["worktree", "list", "--porcelain"], at: repoPath)
            return parsePorcelain(output)
        } catch GitRunner.Error.gitFailed(let status) {
            throw GitDiscoveryError.gitFailed(terminationStatus: status)
        }
    }
}

public enum GitDiscoveryError: Error {
    case gitFailed(terminationStatus: Int32)
}
