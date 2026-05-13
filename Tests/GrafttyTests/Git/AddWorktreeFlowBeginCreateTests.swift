import Testing
import Foundation
import SwiftUI
@testable import Graftty
import GrafttyKit

@MainActor
@Suite("AddWorktreeFlow.beginCreate")
struct AddWorktreeFlowBeginCreateTests {
    @Test("@spec GIT-5.11: useExisting on a mounted branch returns .branchAlreadyMounted")
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
}
