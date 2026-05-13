import Foundation

/// Branch decision for `AddWorktreeFlow` / `GitWorktreeAdd`. Determines
/// whether `git worktree add` creates a fresh branch (`-b <name>`) or
/// reuses an existing one. For `.useExisting`, the `source` tells the
/// git layer whether to pass the bare branch name (local) or
/// `origin/<name>` (remote-only) so a local tracking branch is created
/// as a side effect.
public enum BranchSelection: Sendable, Hashable {
    /// New-branch source for `git worktree add -b <name>`.
    case createNew(name: String)
    /// @spec GIT-5.10
    /// Existing-branch source for `git worktree add <path> <name|origin/name>`
    /// — no `-b` flag, no start point.
    case useExisting(name: String, source: ExistingSource)

    public enum ExistingSource: Sendable, Hashable {
        case local       // bare branch ref, e.g. "feature/foo"
        case remoteOnly  // origin/<name>, creates a local tracking branch
    }

    public var branchName: String {
        switch self {
        case .createNew(let name): return name
        case .useExisting(let name, _): return name
        }
    }
}
