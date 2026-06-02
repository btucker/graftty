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

/// Why a deep-link resolution failed. The valid set of reasons is
/// enforced behaviorally by the resolver specs (URL-1.2 / URL-1.3);
/// this type carries no separate `@spec` ID to avoid a duplicate
/// type-location for URL-1.0 (`DeepLinkTarget` owns that ID).
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
        guard url.scheme == "graftty",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host == "open"
        else { return nil }

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
            // `layout?.leaves` is an in-order pane walk; short-circuit on
            // the first leaf whose `sessionName` matches.
            for wt in worktrees
            where wt.layout?.leaves.contains(where: { $0.sessionName == name }) == true {
                return .resolved(worktreePath: wt.path, sessionName: name)
            }
            return .notFound(.unknownSession)
        case .worktree(let repo, let worktree):
            // Single pass: distinguish "repo not present" from "repo
            // present but worktree missing" without materializing a
            // filtered array.
            var repoSeen = false
            for wt in worktrees where wt.repoDisplayName == repo {
                repoSeen = true
                if WorktreeNameSanitizer.sanitize(wt.displayBranch) == worktree {
                    return .resolved(worktreePath: wt.path, sessionName: nil)
                }
            }
            return .notFound(repoSeen ? .unknownWorktree : .unknownRepo)
        }
    }
}
