import Foundation
import Testing
@testable import GrafttyKit

/// macOS's `/tmp` → `/private/tmp` redirection is a private-root symlink.
/// Foundation's `URL.resolvingSymlinksInPath` / `NSString.resolvingSymlinksInPath`
/// / `standardizingPath` all collapse `/private/tmp` BACK to `/tmp` — the
/// "logical" form. POSIX `realpath()` goes the opposite way, keeping the
/// physical path (`/private/tmp/...`), which is what `git worktree list
/// --porcelain` emits and thus what Graftty's `state.json` stores.
///
/// Using Foundation's normalizer in `GitRepoDetector` therefore produced
/// paths that didn't match the tracked-worktree index, and `graftty notify`
/// run from inside a worktree under `/tmp/*` (or any path traversing a
/// private-root symlink) failed with `"Not inside a tracked worktree"`
/// even though the worktree was tracked. Caught live in cycle 82 dogfood.
@Suite("CanonicalPath — macOS private-root handling", .serialized)
struct CanonicalPathTests {

    @Test func canonicalizesPrivateRootSymlink() {
        // macOS-specific: `/tmp` exists and resolves to `/private/tmp`.
        // Skip if the host doesn't expose that symlink (linux CI, etc.).
        guard FileManager.default.fileExists(atPath: "/private/tmp") else { return }
        let result = CanonicalPath.canonicalize("/tmp")
        #expect(result == "/private/tmp")
    }

    @Test func keepsAlreadyCanonicalPath() {
        guard FileManager.default.fileExists(atPath: "/private/tmp") else { return }
        #expect(CanonicalPath.canonicalize("/private/tmp") == "/private/tmp")
    }

    @Test func handlesNonExistentPath() {
        // `realpath` of a non-existent leaf resolves parents but keeps the
        // missing component. We expect the API to either return the input
        // unchanged OR return a best-effort resolved form — never to
        // silently drop the path component.
        let result = CanonicalPath.canonicalize("/tmp/graftty-cycle82-nonexistent-zzzzzzz")
        #expect(result.hasSuffix("/graftty-cycle82-nonexistent-zzzzzzz"))
    }

    @Test func preservesRootPath() {
        #expect(CanonicalPath.canonicalize("/") == "/")
    }
}
