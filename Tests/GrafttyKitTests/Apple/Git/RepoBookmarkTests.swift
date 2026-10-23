import Testing
import Foundation
@testable import GrafttyKit
import GrafttyTestSupport

@Suite("RepoBookmark Tests")
struct RepoBookmarkTests {

    @Test func mintAndResolveReturnsSamePath() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bookmark = try RepoBookmark.mint(atPath: dir.path)
        let resolved = try RepoBookmark.resolve(bookmark)

        // Bookmark resolution returns physical paths on macOS
        // (`/var/folders/...` -> `/private/var/folders/...`). Compare
        // against the same canonicalization used throughout the codebase.
        #expect(resolved.url.path == CanonicalPath.canonicalize(dir.path))
        #expect(resolved.isStale == false)
    }

    @Test func resolveReturnsNewPathAfterFolderRename() throws {
        let parent = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }

        let before = parent.appendingPathComponent("before")
        try FileManager.default.createDirectory(at: before, withIntermediateDirectories: true)

        let bookmark = try RepoBookmark.mint(atPath: before.path)

        let after = parent.appendingPathComponent("after")
        try FileManager.default.moveItem(at: before, to: after)

        let resolved = try RepoBookmark.resolve(bookmark)
        #expect(resolved.url.path == CanonicalPath.canonicalize(after.path))
    }

    @Test func resolveThrowsAfterFolderDelete() throws {
        let dir = try makeTempDir()
        let bookmark = try RepoBookmark.mint(atPath: dir.path)
        try FileManager.default.removeItem(at: dir)

        #expect(throws: (any Error).self) {
            _ = try RepoBookmark.resolve(bookmark)
        }
    }

    @Test func mintOfMissingPathThrows() {
        #expect(throws: (any Error).self) {
            _ = try RepoBookmark.mint(atPath: "/definitely/not/a/real/path/\(UUID().uuidString)")
        }
    }
}
