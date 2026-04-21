import Testing
import Foundation
@testable import GrafttyKit

@Suite("RepoEntry Codable Tests")
struct RepoEntryCodableTests {

    @Test func decodeLegacyRepoEntryWithoutBookmarkYieldsNilBookmark() throws {
        // Shape of a pre-LAYOUT-4.5 persisted RepoEntry: no `bookmark` key.
        let json = """
        {
          "id": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
          "path": "/tmp/repo",
          "displayName": "repo",
          "isCollapsed": false,
          "worktrees": []
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(RepoEntry.self, from: json)

        #expect(decoded.path == "/tmp/repo")
        #expect(decoded.displayName == "repo")
        #expect(decoded.bookmark == nil)
    }

    @Test func roundTripPreservesBookmarkBytes() throws {
        var entry = RepoEntry(path: "/tmp/repo", displayName: "repo")
        entry.bookmark = Data([0xDE, 0xAD, 0xBE, 0xEF])

        let encoded = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(RepoEntry.self, from: encoded)

        #expect(decoded.bookmark == Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    @Test func repoEntryPathIsMutable() {
        var entry = RepoEntry(path: "/tmp/old", displayName: "old")
        entry.path = "/tmp/new"
        #expect(entry.path == "/tmp/new")
    }
}
