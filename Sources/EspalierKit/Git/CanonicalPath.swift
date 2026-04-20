import Foundation

/// POSIX `realpath`-based path canonicalization. Needed because macOS's
/// Foundation normalizers (`URL.resolvingSymlinksInPath`,
/// `NSString.resolvingSymlinksInPath`, `standardizingPath`) collapse
/// `/private/tmp` → `/tmp` — the opposite direction from `git worktree
/// list --porcelain`, which emits `/private/tmp/...`. That mismatch made
/// `espalier notify` fail with "Not inside a tracked worktree" whenever
/// the cwd traversed a private-root symlink, even though the worktree
/// was in `state.json`.
///
/// `realpath(3)` resolves symlinks forward and returns the physical
/// path, matching git's emitted form. We use it at the two spots that
/// must agree with git: `GitRepoDetector.detect`'s initial pwd
/// normalization and any test-side setup.
public enum CanonicalPath {

    /// Return the physical path equivalent via POSIX `realpath`. For
    /// missing components at the tail, `realpath` fails — we fall back
    /// to canonicalizing the parent and reappending the tail so callers
    /// can still compare (a common case when the caller wants to
    /// resolve a `.git` sibling that doesn't exist on an unopened
    /// worktree path). Returns the input unchanged on any other failure.
    public static func canonicalize(_ path: String) -> String {
        if let resolved = realpath(path) {
            return resolved
        }
        // Missing leaf: resolve parent, reappend leaf. Matches the
        // behavior callers intuitively expect from `realpath -m` (the
        // GNU extension macOS's `realpath` lacks).
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().path
        let leaf = url.lastPathComponent
        if parent != path, let resolvedParent = realpath(parent), !leaf.isEmpty {
            return (resolvedParent as NSString).appendingPathComponent(leaf)
        }
        return path
    }

    private static func realpath(_ path: String) -> String? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        return path.withCString { cstr -> String? in
            guard Darwin.realpath(cstr, &buf) != nil else { return nil }
            return String(cString: buf)
        }
    }
}
