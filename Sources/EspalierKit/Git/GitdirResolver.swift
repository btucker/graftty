import Foundation

/// Resolves the value of a `gitdir: …` line from a linked worktree's
/// `.git` file into an absolute path. Git ≥ 2.52 with
/// `worktree.useRelativePaths=true` writes relative paths measured
/// from the worktree directory; older git and the default config
/// write absolute paths.
///
/// Used by both `GitRepoDetector.detect` (`GIT-1.4`) and
/// `WorktreeMonitor.resolveHeadLogPath` (`GIT-3.14`). Routes through
/// `CanonicalPath.canonicalize` so the result matches the path shape
/// `state.json` stores — same rationale as `GitRepoDetector`'s pwd
/// normalization.
public enum GitdirResolver {
    public static func resolve(rawGitdir: String, worktreePath: String) -> String {
        let absolute: String
        if rawGitdir.hasPrefix("/") {
            absolute = rawGitdir
        } else {
            absolute = URL(fileURLWithPath: worktreePath)
                .appendingPathComponent(rawGitdir)
                .standardized
                .path
        }
        return CanonicalPath.canonicalize(absolute)
    }
}
