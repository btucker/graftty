import Testing
import Foundation
import SwiftUI
@testable import Graftty
import GrafttyKit

@MainActor
@Suite("AddWorktreeFlow.beginCreate")
struct AddWorktreeFlowBeginCreateTests {
    @Test("@spec GIT-5.11: When BranchSelection.useExisting is submitted and the same repo already has the branch mounted in another worktree, the application shall reject the create with branchAlreadyMounted(at:) before invoking git.")
    func mountedBranchRejected() async throws {
        var wt = WorktreeEntry(path: "/r/.worktrees/feat", branch: "feat")
        wt.state = .running
        var state = AppState(repos: [
            RepoEntry(path: "/r", displayName: "r", worktrees: [wt])
        ])
        let binding = Binding<AppState>(
            get: { state },
            set: { state = $0 }
        )
        let result = AddWorktreeFlow.beginCreate(
            repoPath: "/r",
            worktreeName: "feat-copy",
            branch: .useExisting(name: "feat", source: .local),
            appState: binding
        )
        switch result {
        case .failure(.branchAlreadyMounted(let at)):
            #expect(at == "/r/.worktrees/feat")
        default:
            Issue.record("expected .branchAlreadyMounted, got \(result)")
        }
    }

    @Test("Raw clients cannot escape the repository's .worktrees directory")
    func traversalNameRejected() {
        var state = AppState(repos: [
            RepoEntry(path: "/r", displayName: "r", worktrees: [
                WorktreeEntry(path: "/r", branch: "main")
            ])
        ])
        let binding = Binding<AppState>(get: { state }, set: { state = $0 })
        let result = AddWorktreeFlow.beginCreate(
            repoPath: "/r",
            worktreeName: "../outside",
            branch: .createNew(name: "safe-branch"),
            appState: binding
        )
        guard case .failure(.invalidInput(let message)) = result else {
            Issue.record("expected invalidInput, got \(result)")
            return
        }
        #expect(message.contains("invalid path component"))
        #expect(state.repos[0].worktrees.count == 1)
    }

    @Test("Existing Git refs bypass the worktree-name sanitizer")
    func existingBranchNameIsPreserved() {
        var state = AppState(repos: [
            RepoEntry(path: "/r", displayName: "r", worktrees: [
                WorktreeEntry(path: "/r", branch: "main")
            ])
        ])
        let binding = Binding<AppState>(get: { state }, set: { state = $0 })

        let result = AddWorktreeFlow.beginCreate(
            repoPath: "/r",
            worktreeName: "release-2",
            branch: .useExisting(name: "release@2", source: .local),
            appState: binding
        )

        #expect(result == .success("/r/.worktrees/release-2"))
        #expect(state.repos[0].worktrees.last?.branch == "release@2")
    }
}
