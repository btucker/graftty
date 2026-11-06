#if canImport(UIKit)
import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyMobileKit

@Suite("AddWorktreeSheetView submit policy")
struct AddWorktreeSheetViewTests {
    @Test("Mobile creation retains selected provider and exact optional initial task")
    func requestRetainsAgentConfiguration() {
        let empty = CreateWorktreeClient.Request(repoPath: "repo", worktreeName: "feature", branchName: "feature")
        #expect(empty.agent.provider == nil)
        #expect(empty.agent.initialPrompt == nil)
        let prompt = "Fix the tests.\nKeep $(literal syntax).\n"
        let request = CreateWorktreeClient.Request(repoPath: "repo", worktreeName: "feature", branchName: "feature",
            agent: .init(provider: "claude", taskDescription: prompt))
        #expect(request.agent.provider == "claude")
        #expect(request.agent.initialPrompt == prompt)
    }
    @Test("""
@spec IOS-9.17: If the mobile Add Worktree sheet has no authenticated paired connection, then the application shall fail its repository list closed instead of reading repositories over unauthenticated HTTP.
""")
    func repositoryListFailsClosedWithoutPairedConnection() async {
        await #expect(throws: RelayedWorktreeManagementClient.ClientError.pairedConnectionUnavailable) {
            _ = try await AddWorktreeSheetView.loadRepositories(using: nil)
        }
        // The live provider exists for every host and returns nil while
        // the host is unpaired or disconnected.
        await #expect(throws: RelayedWorktreeManagementClient.ClientError.pairedConnectionUnavailable) {
            _ = try await AddWorktreeSheetView.loadRepositories(using: { nil })
        }
    }

    @Test("""
@spec IOS-9.10: While the mobile Add Worktree sheet is valid and not submitting, pressing Return in a single-line field shall submit Create; Return in the optional task description shall insert a newline, and invalid or already-submitting forms shall ignore submission.
""")
    func returnSubmitPolicy() {
        #expect(AddWorktreeSheetView.shouldSubmitOnReturn(canSubmit: true, isSubmitting: false))
        #expect(!AddWorktreeSheetView.shouldSubmitOnReturn(canSubmit: false, isSubmitting: false))
        #expect(!AddWorktreeSheetView.shouldSubmitOnReturn(canSubmit: true, isSubmitting: true))
        #expect(!AddWorktreeSheetView.shouldSubmitOnReturn(canSubmit: true, isSubmitting: false, editingTaskDescription: true))
    }

    @Test("A selected branch carries to the next host only if that host has it")
    func carriedBranchClearsWhenMissing() {
        let repository = RemoteRepositoryInfo(id: "r", displayName: "r", origin: nil, defaultBranchStatus: nil, branches: [
            .init(name: "feature", source: .local, lastCommitDate: Date(timeIntervalSince1970: 1), mountedWorktreeID: nil, pullRequest: nil),
        ])
        #expect(AddWorktreeSheetView.carriedBranch("feature", existing: true, in: repository) == "feature")
        #expect(AddWorktreeSheetView.carriedBranch("gone", existing: true, in: repository) == "")
        #expect(AddWorktreeSheetView.carriedBranch("typed", existing: false, in: repository) == "typed")
    }

    @Test("Relayed existing branches preserve their advertised source")
    func relayedExistingBranchPreservesSource() {
        let branches = [
            RemoteRepositoryInfo.Branch(
                name: "local-feature",
                source: .local,
                lastCommitDate: Date(timeIntervalSince1970: 1),
                mountedWorktreeID: nil,
                pullRequest: nil
            ),
            RemoteRepositoryInfo.Branch(
                name: "remote-feature",
                source: .remoteOnly,
                lastCommitDate: Date(timeIntervalSince1970: 2),
                mountedWorktreeID: nil,
                pullRequest: nil
            ),
        ]
        let repositories = [
            RemoteRepositoryInfo(
                id: "relay-repository-token",
                displayName: "app",
                origin: nil,
                defaultBranchStatus: nil,
                branches: branches
            ),
        ]

        #expect(AddWorktreeSheetView.existingBranchSource(
            repositoryID: "relay-repository-token",
            branchName: "remote-feature",
            repositories: repositories
        ) == .remoteOnly)
        #expect(AddWorktreeSheetView.existingBranchSource(
            repositoryID: "relay-repository-token",
            branchName: "local-feature",
            repositories: repositories
        ) == .local)
        #expect(AddWorktreeSheetView.existingBranchSource(
            repositoryID: "relay-repository-token",
            branchName: "not-yet-refreshed",
            repositories: repositories
        ) == .automatic)
    }
}
#endif
