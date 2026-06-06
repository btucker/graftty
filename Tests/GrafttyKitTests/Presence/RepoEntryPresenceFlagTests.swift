import Testing
import Foundation
@testable import GrafttyKit

@Suite("RepoEntry — presence sharing flag")
struct RepoEntryPresenceFlagTests {
    @Test("@spec SYNC-4.1: If a persisted RepoEntry predates presence sharing, then the application shall decode presenceSharingEnabled as false.")
    func legacyDecodeDefaultsToFalse() throws {
        let legacy = """
        {"id":"00000000-0000-0000-0000-000000000001","path":"/tmp/repo",
         "displayName":"repo","isCollapsed":false,"worktrees":[],"isGitTracked":true}
        """
        let entry = try JSONDecoder().decode(RepoEntry.self, from: Data(legacy.utf8))
        #expect(entry.presenceSharingEnabled == false)
    }

    @Test("presenceSharingEnabled round-trips when set.")
    func flagRoundTrips() throws {
        var entry = RepoEntry(path: "/tmp/repo", displayName: "repo")
        entry.presenceSharingEnabled = true
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(RepoEntry.self, from: data)
        #expect(decoded.presenceSharingEnabled == true)
    }
}
