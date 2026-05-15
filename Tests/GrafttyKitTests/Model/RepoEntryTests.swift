import Testing
import Foundation
@testable import GrafttyKit

@Suite("RepoEntry")
struct RepoEntryTests {
    @Test func decodesPreFeatureBlobWithoutDefaultBranchHint() throws {
        // Pre-feature state.json blob shape — no `defaultBranchHint` key.
        let preFeatureJSON = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "path": "/repo",
            "displayName": "repo",
            "isCollapsed": false,
            "worktrees": [],
            "isGitTracked": true
        }
        """
        let data = preFeatureJSON.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RepoEntry.self, from: data)
        #expect(decoded.defaultBranchHint == nil)
        #expect(decoded.path == "/repo")
    }

    @Test func decodesNewBlobWithDefaultBranchHint() throws {
        let json = """
        {
            "id": "22222222-2222-2222-2222-222222222222",
            "path": "/repo",
            "displayName": "repo",
            "isCollapsed": false,
            "worktrees": [],
            "isGitTracked": true,
            "defaultBranchHint": "trunk"
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RepoEntry.self, from: data)
        #expect(decoded.defaultBranchHint == "trunk")
    }
}
