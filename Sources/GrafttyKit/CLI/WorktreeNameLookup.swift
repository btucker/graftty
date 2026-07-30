import Foundation
import GrafttyProtocol

/// Resolve a worktree by any stable address the CLI exposes:
/// - its canonical absolute path (printed by `worktree add`);
/// - the user-facing name printed by `graftty team list` (the sanitized
///   branch name);
/// - the relative directory name originally passed to `worktree add`.
///
/// Scans every repo in `repos`. Pure function for testability; the CLI
/// wrapper at `WorktreeResolver.resolveWorktreeName(_:)` loads `state.json`
/// and delegates here. Unlike `TeamLookup.member(named:)` this also resolves
/// solo-worktree repos (which have no team).
public enum WorktreeNameLookup {
    public enum Resolution: Equatable, Sendable {
        case found(String)
        case notFound
        case ambiguous([String])
    }

    public static func resolve(name: String, in repos: [RepoEntry]) -> Resolution {
        let allWorktrees = repos.flatMap(\.worktrees)
        let candidates: [WorktreeEntry]
        if NSString(string: name).isAbsolutePath {
            let standardizedAddress = URL(fileURLWithPath: name)
                .standardizedFileURL.path
            candidates = allWorktrees.filter {
                    URL(fileURLWithPath: $0.path).standardizedFileURL.path
                        == standardizedAddress
                }
        } else {
            candidates = repos.flatMap { repo in
                let worktreesRoot = repo.path + "/.worktrees/"
                return repo.worktrees.filter { worktree in
                    if WorktreeNameSanitizer.sanitize(worktree.branch) == name {
                        return true
                    }
                    guard worktree.path.hasPrefix(worktreesRoot) else {
                        return false
                    }
                    let relativeName = String(
                        worktree.path.dropFirst(worktreesRoot.count)
                    )
                    return WorktreeNameSanitizer.sanitize(relativeName) == name
                }
            }
        }

        let pathsByStandardizedPath = Dictionary(
            candidates.map {
                (
                    URL(fileURLWithPath: $0.path).standardizedFileURL.path,
                    $0.path
                )
            },
            uniquingKeysWith: { first, _ in first }
        )
        let persistedPaths = pathsByStandardizedPath.values.sorted()
        switch persistedPaths.count {
        case 0: return .notFound
        case 1: return .found(persistedPaths[0])
        default: return .ambiguous(persistedPaths)
        }
    }

    public static func lookup(name: String, in repos: [RepoEntry]) -> WorktreeEntry? {
        guard case .found(let path) = resolve(name: name, in: repos) else {
            return nil
        }
        return repos.lazy.flatMap(\.worktrees).first {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path
                == URL(fileURLWithPath: path).standardizedFileURL.path
        }
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
        guard case .found(let path) = resolvePathResult(
            name: name,
            stateDirectory: stateDirectory
        ) else {
            return nil
        }
        return path
    }

    public static func resolvePathResult(
        name: String,
        stateDirectory: URL
    ) -> Resolution {
        guard let state = try? AppState.load(from: stateDirectory) else {
            return .notFound
        }
        return resolve(name: name, in: state.repos)
    }
}
