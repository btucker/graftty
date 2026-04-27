import Foundation
@testable import GrafttyKit

enum TeamTestFixtures {
    static func makeRepo(
        path: String = "/r/multi",
        displayName: String = "multi-repo",
        branches: [String]
    ) -> RepoEntry {
        var repo = RepoEntry(path: path, displayName: displayName)
        for (i, b) in branches.enumerated() {
            let worktreePath = i == 0
                ? path
                : "\(path)/.worktrees/\(b.replacingOccurrences(of: "/", with: "-"))"
            repo.worktrees.append(WorktreeEntry(path: worktreePath, branch: b))
        }
        return repo
    }
}
