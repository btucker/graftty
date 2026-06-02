import Foundation
import GrafttyProtocol

/// @spec URL-1.3
/// Result of resolving a deep link against the macOS app's tracked
/// repos. The focus key on macOS is the `PaneSlotID`
/// (`WorktreeEntry.focusedPaneSlotID`).
public enum MacDeepLinkOutcome: Equatable, Sendable {
    case resolved(worktreePath: String, paneSlot: PaneSlotID?)
    case notFound(DeepLinkNotFoundReason)
}

/// Pure resolution of a `DeepLinkTarget` against `[RepoEntry]`.
public enum DeepLinkResolver {
    public static func resolve(
        _ target: DeepLinkTarget,
        inRepos repos: [RepoEntry]
    ) -> MacDeepLinkOutcome {
        switch target {
        case .session(let name):
            for repo in repos {
                for wt in repo.worktrees {
                    if let slot = wt.paneSessions.first(where: {
                        ZmxLauncher.sessionName(for: $0.value) == name
                    })?.key {
                        return .resolved(worktreePath: wt.path, paneSlot: slot)
                    }
                }
            }
            return .notFound(.unknownSession)
        case .worktree(let repoName, let worktreeName):
            guard let repo = repos.first(where: { $0.displayName == repoName }) else {
                return .notFound(.unknownRepo)
            }
            guard let wt = repo.worktrees.first(where: {
                WorktreeNameSanitizer.sanitize($0.branch) == worktreeName
            }) else { return .notFound(.unknownWorktree) }
            return .resolved(worktreePath: wt.path, paneSlot: nil)
        }
    }
}
