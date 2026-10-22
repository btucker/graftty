import Foundation
import Testing
@testable import GrafttyProtocol

/// `Fixtures/repo-info-v1.json` was encoded by `WebServer.RepoInfo` before
/// the type moved to GrafttyProtocol (#484). The web client and Mobile
/// (`ReposFetcher`) read `GET /repos`, including repositories relayed from
/// other Macs, so the shared type must keep its shape.
@Suite("RepoInfo wire fixture")
struct RepoInfoWireTests {
    static let expected = [
        RepoInfo(
            path: "/Users/me/repo", displayName: "repo",
            defaultBranchStatus: .init(branchName: "main", remoteRef: "origin/main", behindCount: 2),
            branches: [
                RemoteRepositoryInfo.Branch(
                    name: "feature/x", source: .local,
                    lastCommitDate: Date(timeIntervalSince1970: 1_700_000_000.5),
                    mountedWorktreeID: "/Users/me/repo/.worktrees/x", pullRequest: .init(number: 7, title: "X")),
                RemoteRepositoryInfo.Branch(
                    name: "origin-only", source: .remoteOnly,
                    lastCommitDate: Date(timeIntervalSince1970: 1_699_000_000),
                    mountedWorktreeID: nil, pullRequest: nil),
            ],
            origin: WorktreeOrigin(deviceID: RemoteDeviceID(value: "dev-b"), deviceLabel: "Mac B", relayDepth: 1)),
        RepoInfo(path: "/Users/me/other", displayName: "other"),
    ]

    private func fixture() throws -> Data {
        try WireFixture.data("repo-info-v1")
    }

    @Test
    func releasedEncoderOutputDecodesToTheSameRepos() throws {
        #expect(try JSONDecoder().decode([RepoInfo].self, from: fixture()) == Self.expected)
    }

    @Test
    func currentEncoderProducesTheReleasedJSON() throws {
        let current = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.expected)) as? NSArray
        let released = try JSONSerialization.jsonObject(with: fixture()) as? NSArray
        #expect(current != nil)
        #expect(current == released)
    }
}
