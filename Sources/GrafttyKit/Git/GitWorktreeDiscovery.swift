import Foundation

public struct DiscoveredWorktree: Sendable {
    public let path: String
    public let branch: String
    /// Git retains admin metadata after an external directory deletion and
    /// reports that record as `prunable`. It is not an on-disk resurrection.
    public let isPrunable: Bool

    public init(path: String, branch: String, isPrunable: Bool = false) {
        self.path = path
        self.branch = branch
        self.isPrunable = isPrunable
    }
}

public enum GitWorktreeDiscovery {
    /// Local discovery should normally complete in milliseconds. Keep a
    /// generous bound so an unresponsive filesystem or wedged git process
    /// cannot block launch reconciliation (and its dependent services)
    /// forever.
    public static let discoveryTimeout: Duration = .seconds(30)

    public static func parsePorcelain(_ output: String) -> [DiscoveredWorktree] {
        var results: [DiscoveredWorktree] = []
        var currentPath: String?
        var currentBranch: String?
        var currentIsPrunable = false

        func appendCurrent() {
            guard let path = currentPath else { return }
            results.append(DiscoveredWorktree(
                path: path,
                branch: currentBranch ?? "(unknown)",
                isPrunable: currentIsPrunable
            ))
        }

        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("worktree ") {
                appendCurrent()
                currentPath = String(line.dropFirst("worktree ".count))
                currentBranch = nil
                currentIsPrunable = false
            } else if line.hasPrefix("branch refs/heads/") {
                currentBranch = String(line.dropFirst("branch refs/heads/".count))
            } else if line == "detached" {
                currentBranch = "(detached)"
            } else if line == "bare" {
                currentBranch = "(bare)"
            } else if line.hasPrefix("prunable") {
                currentIsPrunable = true
            }
        }

        appendCurrent()

        return results
    }

    public static func discover(repoPath: String) async throws -> [DiscoveredWorktree] {
        do {
            let output = try await GitRunner.run(
                args: ["worktree", "list", "--porcelain"],
                at: repoPath,
                timeout: discoveryTimeout
            )
            // Do not expose deleted-directory metadata as a live worktree to
            // relocators, branch refreshes, or reconciliation callers.
            return parsePorcelain(output).filter { !$0.isPrunable }
        } catch let err as CLIError {
            throw GitDiscoveryError.gitFailed(err)
        }
    }
}

public enum GitDiscoveryError: Error {
    case gitFailed(CLIError)
}
