import Foundation
import GrafttyProtocol

/// Resolve a worktree by the user-facing name printed by
/// `graftty team list` (the sanitized branch name) to its persisted
/// path, scanning every repo in `repos`. Pure function for testability;
/// the CLI wrapper at `WorktreeResolver.resolveWorktreeName(_:)` loads
/// `state.json` and delegates here.
///
/// Uses the same `WorktreeNameSanitizer.sanitize` as the team-msg path,
/// so a name accepted by `team msg` is also accepted by every `pane`
/// subcommand. Unlike `TeamLookup.member(named:)` this also resolves
/// solo-worktree repos (which have no team), so `pane *` works on a
/// non-team repo. Returns `nil` for an unknown name.
public enum WorktreeNameLookup {
    public static func lookup(name: String, in repos: [RepoEntry]) -> WorktreeEntry? {
        repos
            .lazy
            .flatMap(\.worktrees)
            .first { WorktreeNameSanitizer.sanitize($0.branch) == name }
    }

    /// File-loading variant: loads `state.json` from `stateDirectory`
    /// and resolves `name` to a worktree path. Returns nil when the
    /// state can't be loaded or the name isn't found. Used by the CLI's
    /// `WorktreeResolver.resolveWorktreeName(_:)` and exposed publicly
    /// so the spec test can drive the same code path through a temp
    /// state directory.
    public static func resolvePath(
        name: String,
        stateDirectory: URL
    ) -> String? {
        guard let state = try? AppState.load(from: stateDirectory) else { return nil }
        return lookup(name: name, in: state.repos)?.path
    }
}
