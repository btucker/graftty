import Foundation

/// Thin wrapper around macOS URL bookmarks for repo paths. Bookmarks let
/// Graftty recover when the user renames or moves a tracked repo folder
/// in Finder — the bookmark resolves to the new path via the inode /
/// volume identity it encoded, without requiring the app to watch every
/// ancestor directory.
///
/// Regular (non-security-scoped) bookmarks are used because Graftty is
/// not sandboxed and `NSOpenPanel` hands the app arbitrary-path URLs.
/// Security-scoped would require `startAccessingSecurityScopedResource`
/// bracketing on every resolve — complexity without benefit (LAYOUT-4.10).
public enum RepoBookmark {

    public struct Resolved {
        public let url: URL
        public let isStale: Bool
    }

    /// Mint a bookmark from a repository's on-disk path.
    ///
    /// Throws if the path does not exist or the system cannot create the
    /// bookmark (permissions, bad filesystem). Callers that want
    /// best-effort behavior should `try?` and store `nil`.
    public static func mint(atPath path: String) throws -> Data {
        let url = URL(fileURLWithPath: path)
        return try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    /// Resolve a bookmark back to a URL. Returns the URL and whether the
    /// bookmark is stale (cross-volume move, APFS firmlink resolution,
    /// etc.) so callers can re-mint.
    ///
    /// The returned URL's path is canonicalized via `CanonicalPath` so
    /// callers can compare against `RepoEntry.path` (which always flows
    /// through `GitRepoDetector.detect` → `CanonicalPath.canonicalize`).
    /// Without this, `URL(resolvingBookmarkData:)` can hand back
    /// `/var/...` where the canonical form is `/private/var/...` on
    /// macOS, false-positively flagging a "move" and contaminating the
    /// model with non-canonical paths that break downstream
    /// `hasPrefix`-based watcher teardown.
    ///
    /// Throws if the bookmark cannot be resolved (referenced folder
    /// deleted, bookmark corrupt, filesystem unavailable).
    public static func resolve(_ bookmark: Data) throws -> Resolved {
        var isStale = false
        let raw = try URL(
            resolvingBookmarkData: bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        let canonical = URL(fileURLWithPath: CanonicalPath.canonicalize(raw.path))
        return Resolved(url: canonical, isStale: isStale)
    }
}
