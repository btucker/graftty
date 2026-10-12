import Testing
import Foundation
import SwiftUI
@testable import Graftty
import GrafttyKit

@MainActor
@Suite("AddWorktreeFlow.beginCreate")
struct AddWorktreeFlowBeginCreateTests {
    @Test("""
    @spec GIT-5.21: CLI worktree creation shall start the first terminal backend before reporting success because no terminal view is guaranteed to mount. Native sidebar creation shall select the completed worktree and defer its first zmx attach until the terminal view has a nonzero AppKit layout, with a bounded focus retry as a fallback if the normal layout callback is missed. Web creation shall leave the hidden Mac surface deferred because the web client attaches to the returned zmx session itself.
    """)
    func terminalStartTimingMatchesCreationEntryPoint() {
        #expect(
            AddWorktreeFlow.terminalStartTiming(for: .nativeSidebar) == .afterViewLayout
        )
        #expect(AddWorktreeFlow.terminalStartTiming(for: .cli) == .immediately)
        #expect(AddWorktreeFlow.terminalStartTiming(for: .web) == .afterViewLayout)
        #expect(AddWorktreeFlow.terminalStartTiming(for: .pairedClient) == .onClientAttach)
    }

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

    @Test("@spec LAYOUT-2.149: When a worktree is added while recent activity order is selected, the application shall place its creating row first among temporary worktrees, retain its creation time across completion and relaunch, and allow later activity to move other worktrees above it.")
    func newWorktreeStartsAboveExistingActivity() throws {
        var active = WorktreeEntry(path: "/r/.worktrees/active", branch: "active")
        active.attention = Attention(text: "Done", timestamp: Date().addingTimeInterval(-60))
        var repo = RepoEntry(path: "/r", displayName: "r", worktrees: [active])
        repo.worktreeOrderMode = .recentActivity
        var state = AppState(repos: [repo])
        let binding = Binding<AppState>(get: { state }, set: { state = $0 })
        #expect(AddWorktreeFlow.beginCreate(repoPath: "/r", worktreeName: "new",
            branch: .createNew(name: "new"), appState: binding) == .success("/r/.worktrees/new"))
        #expect(SidebarHostNavigation.displayedWorktrees(in: state.repos[0]).first?.branch == "new")
        let created = try #require(state.repos[0].worktrees.last?.lastActivity)
        state.repos[0].worktrees[1].state = .running
        let restored = try JSONDecoder().decode(RepoEntry.self, from: JSONEncoder().encode(state.repos[0]))
        #expect(restored.worktrees[1].lastActivity == created)
        #expect(SidebarHostNavigation.displayedWorktrees(in: restored).first?.branch == "new")
        state.repos[0].worktrees[0].attention = Attention(text: "Later", timestamp: created.addingTimeInterval(1))
        #expect(SidebarHostNavigation.displayedWorktrees(in: state.repos[0]).first?.branch == "active")
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
