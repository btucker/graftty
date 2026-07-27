import Foundation
import Testing
@testable import GrafttyProtocol

@Suite("Worktree management wire envelope")
struct WorktreeManagementEnvelopeTests {
    @Test("""
    @spec REMOTE-13.3: When a paired Mac or GrafttyMobile client manages a \
    remote worktree, the application shall round-trip repository, create, \
    pull, open, delete, and acknowledgement requests over the authenticated \
    worktree-management channel using opaque resource identifiers.
    """)
    func everyRequestRoundTrips() throws {
        let requests: [WorktreeManagementRequest] = [
            .listRepositories,
            .create(
                repositoryID: "repo-token",
                worktreeName: "feature",
                branchName: "feature/login",
                existingSource: .remoteOnly
            ),
            .create(
                repositoryID: "repo-token",
                worktreeName: "fresh-snapshot-gap",
                branchName: "feature/remote",
                existingSource: .automatic
            ),
            .pullDefaultBranch(repositoryID: "repo-token"),
            .open(worktreeID: "worktree-token"),
            .delete(worktreeID: "worktree-token", force: true),
            .acknowledge(
                worktreeID: "worktree-token",
                paneID: "pane-token"
            ),
        ]

        for request in requests {
            let data = try JSONEncoder().encode(request)
            #expect(
                try JSONDecoder().decode(
                    WorktreeManagementRequest.self,
                    from: data
                ) == request
            )
        }
    }

    @Test("repository metadata and every response round-trip")
    func everyResponseRoundTrips() throws {
        let origin = WorktreeOrigin(
            deviceID: RemoteDeviceID(value: "studio"),
            deviceLabel: "Studio",
            relayDepth: 1
        )
        let repository = RemoteRepositoryInfo(
            id: "repo-token",
            displayName: "graftty",
            origin: origin,
            defaultBranchStatus: .init(
                branchName: "main",
                remoteRef: "origin/main",
                behindCount: 2
            ),
            branches: [
                .init(
                    name: "feature",
                    source: .local,
                    lastCommitDate: Date(timeIntervalSince1970: 1_700_000_000),
                    mountedWorktreeID: nil,
                    pullRequest: .init(number: 42, title: "Ship it")
                ),
            ]
        )
        let responses: [WorktreeManagementResponse] = [
            .repositories([repository]),
            .created(worktreeID: "worktree-token", paneID: "pane-token"),
            .deleted(dismissed: true),
            .ok,
            .error(
                code: "git-failed",
                message: "dirty worktree",
                forceAllowed: true,
                shortStatus: " M file.swift"
            ),
        ]

        for response in responses {
            let data = try JSONEncoder().encode(response)
            #expect(
                try JSONDecoder().decode(
                    WorktreeManagementResponse.self,
                    from: data
                ) == response
            )
        }
    }
}
