import Foundation

public enum WorktreeState: String, Codable, Sendable {
    case closed
    case running
    case stale
}

public struct WorktreeEntry: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let path: String
    public var branch: String
    public var state: WorktreeState
    public var attention: Attention?
    public var splitTree: SplitTree
    public var focusedTerminalID: TerminalID?

    public init(
        path: String,
        branch: String,
        state: WorktreeState = .closed,
        attention: Attention? = nil,
        splitTree: SplitTree = SplitTree(root: nil)
    ) {
        self.id = UUID()
        self.path = path
        self.branch = branch
        self.state = state
        self.attention = attention
        self.splitTree = splitTree
        self.focusedTerminalID = nil
    }

    /// User-facing label for the worktree *in the context of its siblings*.
    ///
    /// Common case: the directory name the user picked when running
    /// `git worktree add ../<name>` is unique and informative, so we show
    /// the last path component.
    ///
    /// Collision case: when two worktrees of the same repo share a last
    /// component (e.g. `/Users/ben/projects/blindspots` AND
    /// `/Users/ben/.codex/worktrees/6750/blindspots` — common with tools
    /// that auto-create worktrees in namespaced directories), the label
    /// would be ambiguous. Fall back to `parent/last` to disambiguate.
    ///
    /// `siblingPaths` must include this worktree's own path; the count
    /// tells us whether there's a collision.
    public func displayName(amongSiblingPaths siblingPaths: [String]) -> String {
        let lastComponent = (path as NSString).lastPathComponent
        let fallback = lastComponent.isEmpty ? branch : lastComponent

        // Is there any OTHER worktree in the repo with the same last
        // component? If so, disambiguate.
        let collides = siblingPaths.contains { siblingPath in
            siblingPath != path &&
            (siblingPath as NSString).lastPathComponent == lastComponent
        }
        guard collides else { return fallback }

        let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        guard !parent.isEmpty else { return fallback }
        return "\(parent)/\(lastComponent)"
    }
}
