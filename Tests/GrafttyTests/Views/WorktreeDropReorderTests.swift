import CoreGraphics
import Foundation
import Testing
@testable import Graftty
import GrafttyKit

@Suite("Worktree drop reorder tests")
struct WorktreeDropReorderTests {
    @Test("Pane and worktree drags advertise distinct content types")
    func paneAndWorktreeDragPayloadsUseDistinctContentTypes() {
        #expect(TransferablePaneSlotID.contentType != TransferableWorktreeMove.contentType)
    }

    @Test("Row drop location maps upper half before and lower half after")
    func rowDropLocationMapsToPlacement() {
        #expect(WorktreeDropPlacement.fromRowDropLocation(CGPoint(x: 0, y: 18), rowHeight: 44) == .before)
        #expect(WorktreeDropPlacement.fromRowDropLocation(CGPoint(x: 0, y: 24), rowHeight: 44) == .after)
        #expect(WorktreeDropPlacement.fromRowDropLocation(CGPoint(x: 0, y: 10), rowHeight: 24) == .before)
        #expect(WorktreeDropPlacement.fromRowDropLocation(CGPoint(x: 0, y: 14), rowHeight: 24) == .after)
    }

    @Test("Dropping a worktree on a sibling moves it to the sibling's current index")
    func droppingWorktreeOnSiblingMovesToTargetIndex() {
        let repo = RepoEntry(path: "/repo", displayName: "repo", worktrees: [
            WorktreeEntry(path: "/repo", branch: "main"),
            WorktreeEntry(path: "/repo/.worktrees/a", branch: "a"),
            WorktreeEntry(path: "/repo/.worktrees/b", branch: "b"),
        ])
        var state = AppState(repos: [repo])

        let changed = WorktreeDropReorder.apply(
            TransferableWorktreeMove(repoID: repo.id, worktreeID: repo.worktrees[2].id),
            targetWorktreeID: repo.worktrees[0].id,
            placement: .before,
            to: &state
        )

        #expect(changed)
        #expect(state.repos[0].worktrees.map(\.branch) == ["b", "main", "a"])
    }

    @Test("Dropping a worktree after a lower sibling moves it downward")
    func droppingWorktreeAfterLowerSiblingMovesDownward() {
        let repo = RepoEntry(path: "/repo", displayName: "repo", worktrees: [
            WorktreeEntry(path: "/repo", branch: "main"),
            WorktreeEntry(path: "/repo/.worktrees/a", branch: "a"),
            WorktreeEntry(path: "/repo/.worktrees/b", branch: "b"),
        ])
        var state = AppState(repos: [repo])

        let changed = WorktreeDropReorder.apply(
            TransferableWorktreeMove(repoID: repo.id, worktreeID: repo.worktrees[0].id),
            targetWorktreeID: repo.worktrees[2].id,
            placement: .after,
            to: &state
        )

        #expect(changed)
        #expect(state.repos[0].worktrees.map(\.branch) == ["a", "b", "main"])
    }

    @Test("Drops from another repo are ignored")
    func crossRepoDropIsIgnored() {
        let first = RepoEntry(path: "/repo-a", displayName: "repo-a", worktrees: [
            WorktreeEntry(path: "/repo-a", branch: "main"),
        ])
        let second = RepoEntry(path: "/repo-b", displayName: "repo-b", worktrees: [
            WorktreeEntry(path: "/repo-b", branch: "main"),
            WorktreeEntry(path: "/repo-b/.worktrees/feature", branch: "feature"),
        ])
        var state = AppState(repos: [first, second])

        let changed = WorktreeDropReorder.apply(
            TransferableWorktreeMove(repoID: second.id, worktreeID: second.worktrees[1].id),
            targetWorktreeID: first.worktrees[0].id,
            placement: .before,
            to: &state
        )

        #expect(!changed)
        #expect(state.repos[0].worktrees.map(\.branch) == ["main"])
        #expect(state.repos[1].worktrees.map(\.branch) == ["main", "feature"])
    }

    @Test("In-flight source and target worktrees are ignored")
    func inFlightSourceAndTargetDropsAreIgnored() {
        let repo = RepoEntry(path: "/repo", displayName: "repo", worktrees: [
            WorktreeEntry(path: "/repo", branch: "main"),
            WorktreeEntry(path: "/repo/.worktrees/creating", branch: "creating", state: .creating),
            WorktreeEntry(path: "/repo/.worktrees/deleting", branch: "deleting", state: .deleting),
            WorktreeEntry(path: "/repo/.worktrees/feature", branch: "feature"),
        ])
        var sourceState = AppState(repos: [repo])
        var targetState = AppState(repos: [repo])

        let sourceChanged = WorktreeDropReorder.apply(
            TransferableWorktreeMove(repoID: repo.id, worktreeID: repo.worktrees[1].id),
            targetWorktreeID: repo.worktrees[0].id,
            placement: .before,
            to: &sourceState
        )
        let targetChanged = WorktreeDropReorder.apply(
            TransferableWorktreeMove(repoID: repo.id, worktreeID: repo.worktrees[3].id),
            targetWorktreeID: repo.worktrees[2].id,
            placement: .before,
            to: &targetState
        )

        #expect(!sourceChanged)
        #expect(!targetChanged)
        #expect(sourceState.repos[0].worktrees.map(\.branch) == ["main", "creating", "deleting", "feature"])
        #expect(targetState.repos[0].worktrees.map(\.branch) == ["main", "creating", "deleting", "feature"])
    }

    @Test("Native list moves use the same in-flight guards")
    func nativeListMovesUseInFlightGuards() {
        let repo = RepoEntry(path: "/repo", displayName: "repo", worktrees: [
            WorktreeEntry(path: "/repo", branch: "main"),
            WorktreeEntry(path: "/repo/.worktrees/creating", branch: "creating", state: .creating),
            WorktreeEntry(path: "/repo/.worktrees/feature", branch: "feature"),
        ])
        var sourceState = AppState(repos: [repo])
        var targetState = AppState(repos: [repo])

        let sourceChanged = WorktreeDropReorder.applyListMove(
            inRepoID: repo.id,
            fromOffsets: IndexSet(integer: 1),
            toOffset: 0,
            to: &sourceState
        )
        let targetChanged = WorktreeDropReorder.applyListMove(
            inRepoID: repo.id,
            fromOffsets: IndexSet(integer: 2),
            toOffset: 1,
            to: &targetState
        )

        #expect(!sourceChanged)
        #expect(!targetChanged)
        #expect(sourceState.repos[0].worktrees.map(\.branch) == ["main", "creating", "feature"])
        #expect(targetState.repos[0].worktrees.map(\.branch) == ["main", "creating", "feature"])
    }

    @Test("Custom drops use the native list-move in-flight destination guard")
    func customDropsUseListMoveInFlightDestinationGuard() {
        let repo = RepoEntry(path: "/repo", displayName: "repo", worktrees: [
            WorktreeEntry(path: "/repo", branch: "main"),
            WorktreeEntry(path: "/repo/.worktrees/creating", branch: "creating", state: .creating),
            WorktreeEntry(path: "/repo/.worktrees/feature", branch: "feature"),
        ])
        var state = AppState(repos: [repo])

        let changed = WorktreeDropReorder.apply(
            TransferableWorktreeMove(repoID: repo.id, worktreeID: repo.worktrees[0].id),
            targetWorktreeID: repo.worktrees[2].id,
            placement: .before,
            to: &state
        )

        #expect(!changed)
        #expect(state.repos[0].worktrees.map(\.branch) == ["main", "creating", "feature"])
    }

    @Test("Dropping a worktree on itself is ignored")
    func selfDropIsIgnored() {
        let repo = RepoEntry(path: "/repo", displayName: "repo", worktrees: [
            WorktreeEntry(path: "/repo", branch: "main"),
            WorktreeEntry(path: "/repo/.worktrees/a", branch: "a"),
        ])
        var state = AppState(repos: [repo])

        let changed = WorktreeDropReorder.apply(
            TransferableWorktreeMove(repoID: repo.id, worktreeID: repo.worktrees[1].id),
            targetWorktreeID: repo.worktrees[1].id,
            placement: .before,
            to: &state
        )

        #expect(!changed)
        #expect(state.repos[0].worktrees.map(\.branch) == ["main", "a"])
    }
}
