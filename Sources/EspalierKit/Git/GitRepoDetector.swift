import Foundation

public enum GitPathType: Equatable, Sendable {
    case repoRoot(String)
    case worktree(worktreePath: String, repoPath: String)
    case notARepo
}

public enum GitRepoDetector {
    public static func detect(path: String) throws -> GitPathType {
        var current = URL(fileURLWithPath: path).resolvingSymlinksInPath()

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
                    let repoPath = resolveRepoRoot(fromGitDir: gitDir)
                    return .worktree(worktreePath: current.path, repoPath: repoPath)
                }
            }

            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return .notARepo }
            current = parent
        }
    }

    private static func resolveRepoRoot(fromGitDir gitDir: String) -> String {
        var url = URL(fileURLWithPath: gitDir).resolvingSymlinksInPath()
        while url.lastPathComponent != ".git" && url.path != "/" {
            url = url.deletingLastPathComponent()
        }
        return url.deletingLastPathComponent().path
    }
}
