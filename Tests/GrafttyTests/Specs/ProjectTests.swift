import Foundation
import Testing
@testable import GrafttyKit

@Suite("@spec PROJECT-1.0: Each repository entry shall record whether its on-disk path is tracked by git.")
struct RepoEntryIsGitTrackedTests {
    @Test("Default initializer marks new entries as git-tracked")
    func defaultsToGitTracked() {
        let repo = RepoEntry(path: "/tmp/x", displayName: "x")
        #expect(repo.isGitTracked == true)
    }

    @Test("Initializer accepts isGitTracked: false")
    func acceptsNonGit() {
        let repo = RepoEntry(path: "/tmp/y", displayName: "y", isGitTracked: false)
        #expect(repo.isGitTracked == false)
    }
}

@Suite("@spec PROJECT-1.5: When decoding a repository entry that lacks the isGitTracked key, the application shall default it to true so pre-feature state.json blobs load unchanged.")
struct RepoEntryIsGitTrackedDecodeTests {
    @Test("Pre-feature JSON without isGitTracked decodes as git-tracked")
    func decodeLegacyAsGitTracked() throws {
        let json = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "path": "/tmp/legacy",
            "displayName": "legacy",
            "worktrees": []
        }
        """.data(using: .utf8)!
        let repo = try JSONDecoder().decode(RepoEntry.self, from: json)
        #expect(repo.isGitTracked == true)
    }

    @Test("Non-git entry round-trips through encode/decode")
    func roundTripNonGit() throws {
        let original = RepoEntry(
            path: "/tmp/nongit",
            displayName: "nongit",
            worktrees: [],
            isGitTracked: false
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RepoEntry.self, from: data)
        #expect(decoded.isGitTracked == false)
        #expect(decoded.path == original.path)
        #expect(decoded.displayName == original.displayName)
    }
}

@Suite("@spec PROJECT-1.4: When WorktreeDiscovery.discover is invoked with a non-git-tracked repository, the application shall return exactly one synthesized DiscoveredWorktree with path equal to the repo path and branch \"main\", without invoking git.")
struct WorktreeDiscoveryFacadeTests {
    @Test("Non-git repo synthesizes a single main worktree")
    func nonGitReturnsSyntheticWorktree() async throws {
        let repo = RepoEntry(
            path: "/tmp/example",
            displayName: "example",
            isGitTracked: false
        )
        let results = try await WorktreeDiscovery.discover(repo: repo)
        #expect(results.count == 1)
        #expect(results[0].path == "/tmp/example")
        #expect(results[0].branch == "main")
    }
}
