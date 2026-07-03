import Testing
@testable import Graftty
@testable import GrafttyKit

@Suite("Flow State sidebar selection")
struct SidebarFlowStateTests {
    @Test("Selecting Flow State preserves the current worktree path.")
    func selectingFlowStateDoesNotMutateWorktreePath() {
        let transition = MainWindowSelectionTransition.selectFlowState(
            currentWorktreePath: "/repo/worktrees/feature"
        )

        #expect(transition.selection == .flowState)
        #expect(transition.selectedWorktreePath == "/repo/worktrees/feature")
    }

    @Test("Selecting a worktree leaves Flow State mode.")
    func selectingWorktreeClearsFlowStateMode() {
        let transition = MainWindowSelectionTransition.selectWorktree("/repo/worktrees/fix")

        #expect(transition.selection == .worktree("/repo/worktrees/fix"))
        #expect(transition.selectedWorktreePath == "/repo/worktrees/fix")
    }

    @Test("@spec FLOW-7.4: Confirmed Flow State focus actions shall resolve collision-resistant worktree refs to worktree paths before changing the selected worktree.")
    func focusActionTargetsResolveWorktreeRefs() {
        let feature = WorktreeEntry(path: "/repo/.worktrees/feature", branch: "feature", state: .running)
        let repo = RepoEntry(path: "/repo", displayName: "repo", worktrees: [
            WorktreeEntry(path: "/repo", branch: "main", state: .running),
            feature
        ])
        let ref = FlowWorktreeIdentity.ref(
            repoDisplayName: repo.displayName,
            repoPath: repo.path,
            worktreePath: feature.path,
            branch: feature.branch
        )

        #expect(MainWindowSelectionTransition.resolveWorktreePath(target: ref, repos: [repo]) == feature.path)
    }

    @Test("@spec FLOW-7.5: Confirmed Flow State focus actions shall refuse ambiguous display/member aliases instead of focusing the first sanitized-name match.")
    func focusActionTargetsRejectAmbiguousAliases() {
        let repo = RepoEntry(path: "/repo", displayName: "repo", worktrees: [
            WorktreeEntry(path: "/repo", branch: "main", state: .running),
            WorktreeEntry(path: "/repo/.worktrees/foo-bar", branch: "foo-bar", state: .running),
            WorktreeEntry(path: "/repo/.worktrees/foo--bar", branch: "foo--bar", state: .running)
        ])

        #expect(MainWindowSelectionTransition.resolveWorktreePath(target: "foo-bar", repos: [repo]) == nil)
    }
}
