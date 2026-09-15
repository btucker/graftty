import CoreGraphics
import Foundation
import Testing
import CoreTransferable
@testable import Graftty
import GrafttyKit

@Suite("Worktree drop reorder tests")
struct WorktreeDropReorderTests {
    @Test("@spec LAYOUT-2.65: When a user drops a worktree or pane on a worktree row, the application shall accept both drag types through one destination, reorder eligible worktree siblings, and move panes only within their repository.")
    func sharedDestinationAcceptsBothDragTypes() async throws {
        let slot = PaneSlotID()
        var first = WorktreeEntry(path: "/repo/.worktrees/a", branch: "a", state: .running,
                                  splitTree: SplitTree(root: .leaf(slot)))
        _ = first.ensurePaneSession(for: slot)
        let second = WorktreeEntry(path: "/repo/.worktrees/b", branch: "b")
        let repo = RepoEntry(path: "/repo", displayName: "repo", worktrees: [first, second])
        var state = AppState(repos: [repo])
        let worktreeProvider = NSItemProvider()
        worktreeProvider.register(TransferableWorktreeMove(repoID: repo.id, worktreeID: second.id))
        let worktreeDrop: WorktreeRowDrop = try await withCheckedThrowingContinuation { continuation in
            _ = worktreeProvider.loadTransferable(type: WorktreeRowDrop.self) { continuation.resume(with: $0) }
        }
        #expect(worktreeDrop.apply(repoID: repo.id, targetWorktreeID: first.id, placement: .before,
                                  allowsReordering: true, to: &state) == .reordered)
        #expect(state.repos[0].worktrees.map(\.id) == [second.id, first.id])

        let paneProvider = NSItemProvider()
        paneProvider.register(TransferablePaneSlotID(id: slot.id))
        let paneDrop: WorktreeRowDrop = try await withCheckedThrowingContinuation { continuation in
            _ = paneProvider.loadTransferable(type: WorktreeRowDrop.self) { continuation.resume(with: $0) }
        }
        #expect(paneDrop.apply(repoID: repo.id, targetWorktreeID: second.id, placement: .after,
                              allowsReordering: false, to: &state) == .movePane(slot, second.path))
        #expect(worktreeDrop.apply(repoID: repo.id, targetWorktreeID: first.id, placement: .after,
                                   allowsReordering: false, to: &state) == .rejected)
        let other = RepoEntry(path: "/other", displayName: "Other", worktrees: [.init(path: "/other", branch: "main")])
        state.repos.append(other)
        #expect(paneDrop.apply(repoID: other.id, targetWorktreeID: other.worktrees[0].id, placement: .after,
                               allowsReordering: true, to: &state) == .rejected)
    }

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
            targetWorktreeID: repo.worktrees[1].id,
            placement: .before,
            to: &state
        )

        #expect(changed)
        #expect(state.repos[0].worktrees.map(\.branch) == ["main", "b", "a"])
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
            TransferableWorktreeMove(repoID: repo.id, worktreeID: repo.worktrees[1].id),
            targetWorktreeID: repo.worktrees[2].id,
            placement: .after,
            to: &state
        )

        #expect(changed)
        #expect(state.repos[0].worktrees.map(\.branch) == ["main", "b", "a"])
    }

    @Test("@spec LAYOUT-2.34: If a user drops a worktree row onto a worktree with a different virtual-folder parent, then the application shall reject the reorder so persisted flat order cannot disagree with the displayed hierarchy.")
    func dropsAcrossHierarchyParentsAreRejected() {
        let repo = RepoEntry(path: "/repo", displayName: "repo", worktrees: [
            WorktreeEntry(path: "/repo/.worktrees/research/lead", branch: "research/lead"),
            WorktreeEntry(path: "/repo/.worktrees/research/notes", branch: "research/notes"),
            WorktreeEntry(path: "/repo/.worktrees/solo", branch: "solo"),
        ])
        var state = AppState(repos: [repo])

        let changed = WorktreeDropReorder.apply(
            TransferableWorktreeMove(repoID: repo.id, worktreeID: repo.worktrees[0].id),
            targetWorktreeID: repo.worktrees[2].id,
            placement: .before,
            to: &state
        )

        #expect(!changed)
        #expect(state.repos[0].worktrees.map(\.branch) == ["research/lead", "research/notes", "solo"])
    }

    @Test("@spec LAYOUT-2.35: When worktree rows sharing a virtual-folder parent occupy noncontiguous persisted positions, the application shall reorder only those sibling rows within their existing positions so unrelated rows do not move.")
    func sameFolderDropPreservesUnrelatedRawPositions() {
        let lead = WorktreeEntry(
            path: "/repo/.worktrees/research/lead",
            branch: "research/lead"
        )
        let solo = WorktreeEntry(path: "/repo/.worktrees/solo", branch: "solo")
        let notes = WorktreeEntry(
            path: "/repo/.worktrees/research/notes",
            branch: "research/notes"
        )
        let repo = RepoEntry(
            path: "/repo",
            displayName: "repo",
            worktrees: [lead, solo, notes]
        )
        var state = AppState(repos: [repo])

        let changed = WorktreeDropReorder.apply(
            TransferableWorktreeMove(repoID: repo.id, worktreeID: lead.id),
            targetWorktreeID: notes.id,
            placement: .after,
            to: &state
        )

        #expect(changed)
        #expect(state.repos[0].worktrees.map(\.branch) == [
            "research/notes",
            "solo",
            "research/lead",
        ])
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

    @Test("Custom drops reject in-flight destination neighbors")
    func customDropsRejectInFlightDestinationNeighbors() {
        let repo = RepoEntry(path: "/repo", displayName: "repo", worktrees: [
            WorktreeEntry(path: "/repo", branch: "main"),
            WorktreeEntry(path: "/repo/.worktrees/moving", branch: "moving"),
            WorktreeEntry(path: "/repo/.worktrees/creating", branch: "creating", state: .creating),
            WorktreeEntry(path: "/repo/.worktrees/feature", branch: "feature"),
        ])
        var state = AppState(repos: [repo])

        let changed = WorktreeDropReorder.apply(
            TransferableWorktreeMove(repoID: repo.id, worktreeID: repo.worktrees[1].id),
            targetWorktreeID: repo.worktrees[3].id,
            placement: .before,
            to: &state
        )

        #expect(!changed)
        #expect(state.repos[0].worktrees.map(\.branch) == ["main", "moving", "creating", "feature"])
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
