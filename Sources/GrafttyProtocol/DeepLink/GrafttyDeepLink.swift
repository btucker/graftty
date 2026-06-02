import Foundation

/// @spec URL-1.0
/// A deep-link target parsed from a `graftty://open` URL: either a
/// specific pane session (which implies its worktree and pane) or a
/// repo+worktree pair (worktree-level, pane-agnostic).
public enum DeepLinkTarget: Equatable, Sendable {
    /// A zmx session name, e.g. `"graftty-ab12cd34"`.
    case session(String)
    /// `repo` matches a repo display name; `worktree` is the sanitized
    /// worktree address (same form as `graftty team msg` / `pane`).
    case worktree(repo: String, worktree: String)
}

/// @spec URL-1.0
/// Why a deep-link resolution failed.
public enum DeepLinkNotFoundReason: Equatable, Sendable {
    case unknownSession
    case unknownRepo
    case unknownWorktree
}

/// Parses and resolves `graftty://` deep links. Pure and dependency-free
/// beyond `GrafttyProtocol` so both the macOS app and the iOS app can
/// share it (`GrafttyMobileKit` depends on `GrafttyProtocol`, not
/// `GrafttyKit`).
public enum GrafttyDeepLink {

    /// Parse a URL into a `DeepLinkTarget`. Returns `nil` for any URL
    /// that is not `graftty://open` with usable params. When both a
    /// `session` and a `repo`+`worktree` pair are present, the session
    /// wins.
    public static func parse(_ url: URL) -> DeepLinkTarget? {
        guard url.scheme == "graftty" else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        guard components.host == "open" else { return nil }

        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            guard let raw = items.first(where: { $0.name == name })?.value, !raw.isEmpty else { return nil }
            return raw
        }

        if let session = value("session") {
            return .session(session)
        }
        if let repo = value("repo"), let worktree = value("worktree") {
            return .worktree(repo: repo, worktree: WorktreeNameSanitizer.sanitize(worktree))
        }
        return nil
    }
}

/// @spec URL-1.2
/// Result of resolving a deep link against an iOS worktree-panes
/// snapshot. The focus key on iOS is the pane `sessionName` string
/// (see `IPadAppState.focusedPaneId`).
public enum SnapshotDeepLinkOutcome: Equatable, Sendable {
    case resolved(worktreePath: String, sessionName: String?)
    case notFound(DeepLinkNotFoundReason)
}

extension GrafttyDeepLink {
    /// Resolve a target against an iOS `[WorktreePanes]` snapshot.
    public static func resolve(
        _ target: DeepLinkTarget,
        inSnapshot worktrees: [WorktreePanes]
    ) -> SnapshotDeepLinkOutcome {
        switch target {
        case .session(let name):
            for wt in worktrees where sessionNames(of: wt).contains(name) {
                return .resolved(worktreePath: wt.path, sessionName: name)
            }
            return .notFound(.unknownSession)
        case .worktree(let repo, let worktree):
            let inRepo = worktrees.filter { $0.repoDisplayName == repo }
            guard !inRepo.isEmpty else { return .notFound(.unknownRepo) }
            guard let match = inRepo.first(where: {
                WorktreeNameSanitizer.sanitize($0.displayBranch) == worktree
            }) else { return .notFound(.unknownWorktree) }
            return .resolved(worktreePath: match.path, sessionName: nil)
        }
    }

    /// All pane session names in a `WorktreePanes` entry.
    /// `layout` is `PaneLayoutNode?`; `.leaves` does an in-order walk
    /// returning `[PaneLayoutNode.Leaf]`, each with a `.sessionName`.
    private static func sessionNames(of wt: WorktreePanes) -> [String] {
        wt.layout?.leaves.map(\.sessionName) ?? []
    }
}
