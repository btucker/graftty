import Foundation

public enum GitPathType: Equatable, Sendable {
    case repoRoot(String)
    case worktree(worktreePath: String, repoPath: String)
    case notARepo
}

public enum GitRepoDetector {
    public static func detect(path: String) throws -> GitPathType {
        // `CanonicalPath.canonicalize` (POSIX `realpath`) matches the path
        // shape that `git worktree list --porcelain` emits and that
        // `state.json` therefore stores. Foundation's symlink resolvers
        // collapse `/private/tmp` → `/tmp` — the opposite direction —
        // which made `espalier notify` run from under `/tmp/*` fail
        // "Not inside a tracked worktree" even for tracked worktrees.
        var current = URL(fileURLWithPath: CanonicalPath.canonicalize(path))

        while true {
            let gitPath = current.appendingPathComponent(".git")

            if FileManager.default.fileExists(atPath: gitPath.path) {
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: gitPath.path, isDirectory: &isDir)

                if isDir.boolValue {
                    return .repoRoot(current.path)
                } else {
                    let contents = try String(contentsOf: gitPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard contents.hasPrefix("gitdir: ") else { return .notARepo }
                    let gitDir = String(contents.dropFirst("gitdir: ".count))
                    let repoPath = resolveRepoRoot(fromGitDir: gitDir, worktreePath: current.path)
                    return .worktree(worktreePath: current.path, repoPath: repoPath)
                }
            }

            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return .notARepo }
            current = parent
        }
    }

    private static func resolveRepoRoot(fromGitDir gitDir: String, worktreePath: String) -> String {
        // `GitdirResolver` handles the relative-vs-absolute split
        // (`GIT-1.4`) and `CanonicalPath` normalisation.
        var url = URL(fileURLWithPath: GitdirResolver.resolve(
            rawGitdir: gitDir, worktreePath: worktreePath
        ))
        while url.lastPathComponent != ".git" && url.path != "/" {
            url = url.deletingLastPathComponent()
        }
        return url.deletingLastPathComponent().path
    }
}
