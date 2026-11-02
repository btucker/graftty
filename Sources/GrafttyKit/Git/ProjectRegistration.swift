import Foundation

/// Shared Git project preparation for Add Repository and local CLI requests.
/// Preparation performs I/O without holding a mutable app-state snapshot.
public struct ProjectRegistration: Sendable {
    public let repo: RepoEntry
    public let selectedWorktreePath: String

    public static func prepare(path: String) async throws -> Self {
        let detection = try await OffMainIO.run {
            var isDirectory: ObjCBool = false
            guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw RegistrationError(message: "Project path must be an existing directory: \(path)")
            }
            return try GitRepoDetector.detect(path: path)
        }
        let repoPath: String
        let selectedPath: String
        switch detection {
        case .repoRoot(let root):
            repoPath = root
            selectedPath = root
        case .worktree(let worktree, let root):
            repoPath = root
            selectedPath = worktree
        case .notARepo:
            throw RegistrationError(message: "Not a Git repository: \(path). Use Add Repository in Graftty to initialize Git or add a project without Git.")
        }
        let discovered: [DiscoveredWorktree]
        do {
            discovered = try await GitWorktreeDiscovery.discover(repoPath: repoPath)
        } catch let error as GitDiscoveryError {
            let detail: String
            switch error {
            case .gitFailed(.nonZeroExit(_, _, let stderr)):
                detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            case .gitFailed(let failure):
                detail = String(describing: failure)
            }
            throw RegistrationError(message: "Git discovery failed at \(repoPath): \(detail)")
        }
        guard discovered.contains(where: { $0.path == selectedPath }) else {
            throw RegistrationError(message: "Git did not report the selected worktree: \(selectedPath)")
        }
        let bookmark = await OffMainIO.run { try? RepoBookmark.mint(atPath: repoPath) }
        return Self(repo: RepoEntry(
            path: repoPath,
            displayName: URL(fileURLWithPath: repoPath).lastPathComponent,
            worktrees: discovered.map { WorktreeEntry(path: $0.path, branch: $0.branch) },
            bookmark: bookmark,
            defaultBranchHint: discovered.first(where: { $0.path == repoPath })?.branch
        ), selectedWorktreePath: selectedPath)
    }

    /// Apply to the current state after preparation, so concurrent additions
    /// neither overwrite intervening mutations nor replace existing entries.
    public func apply(to state: inout AppState) {
        state.addRepo(repo)
    }

    private struct RegistrationError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
