import AppKit
import CoreTransferable
import Foundation
import Testing
@testable import Graftty
import GrafttyKit

@Suite("Drag worktrees into Pinned Agents")
struct WorktreeDropPinTests {
    @Test func recentActivityAllowsTemporaryDragForPinning() {
        let fixture = makeFixture(mode: .recentActivity)
        #expect(WorktreeReorderTarget.canDrag(fixture.task, in: fixture.repo, isEnabled: true))
        #expect(!WorktreeReorderTarget.canDrag(fixture.task, in: fixture.repo, isEnabled: false))
        #expect(!WorktreeReorderTarget.canDrag(fixture.home, in: fixture.repo, isEnabled: true))
    }

    @Test("@spec LAYOUT-2.113: When a user drops an eligible temporary local worktree on the Pinned Agents header or a pinned row in its repository, the application shall pin it, reveal the section, preserve its workspace and existing peer order, and keep the default checkout first, including when temporary worktrees use recent activity order.")
    func headerDropPinsAndRevealsRoleWithoutChangingWorkspace() throws {
        for mode in [WorktreeOrderMode.manual, .recentActivity] {
            var fixture = makeFixture(mode: mode)
            fixture.repo.isPinnedCollapsed = true
            var state = AppState(repos: [fixture.repo])
            let payload = TransferableWorktreeMove(repoID: fixture.repo.id, worktreeID: fixture.task.id)
            #expect(WorktreeDropReorder.pin(payload, repoID: fixture.repo.id, to: &state))
            var expected = fixture.task
            expected.isPinned = true
            #expect(state.worktree(forPath: fixture.task.path) == expected)
            #expect(state.repos[0].worktrees.filter { $0.id != fixture.task.id }
                == fixture.repo.worktrees.filter { $0.id != fixture.task.id })
            #expect(!state.repos[0].isPinnedCollapsed)
            #expect(SidebarHostNavigation.displayedWorktrees(in: state.repos[0]).map(\.id)
                == [fixture.home.id, fixture.role.id, fixture.task.id, fixture.other.id])
            let restored = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(state))
            #expect(restored.worktree(forPath: fixture.task.path)?.isPinned == true)
            #expect(!WorktreeDropReorder.pin(payload, repoID: fixture.repo.id, to: &state))
        }
    }

    @Test func rowDropPinsAtAnEligiblePinnedPositionAndKeepsHomeFirst() {
        for targetHome in [false, true] {
            let fixture = makeFixture(mode: .recentActivity)
            var state = AppState(repos: [fixture.repo])
            let target = targetHome ? fixture.home : fixture.role
            let result = WorktreeRowDrop.worktree(.init(repoID: fixture.repo.id, worktreeID: fixture.task.id))
                .apply(repoID: fixture.repo.id, targetWorktreeID: target.id, placement: .before,
                       allowsReordering: true, to: &state)
            #expect(result == .pinned)
            #expect(state.worktree(forPath: fixture.task.path)?.isPinned == true)
            #expect(SidebarHostNavigation.displayedWorktrees(in: state.repos[0]).map(\.id)
                == [fixture.home.id, fixture.task.id, fixture.role.id, fixture.other.id])
        }
    }

    @Test func invalidSourcesAndCrossRepositoryDropsDoNotMutateState() {
        let fixture = makeFixture()
        for source in [fixture.home, fixture.role, WorktreeEntry(path: "/repo/.worktrees/stale", branch: "stale", state: .stale),
                       WorktreeEntry(path: "/repo/.worktrees/new", branch: "new", state: .creating),
                       WorktreeEntry(path: "/repo/.worktrees/old", branch: "old", state: .deleting)] {
            var repo = fixture.repo
            if !repo.worktrees.contains(where: { $0.id == source.id }) { repo.worktrees.append(source) }
            var state = AppState(repos: [repo])
            let original = state.repos
            #expect(!WorktreeDropReorder.pin(.init(repoID: repo.id, worktreeID: source.id), repoID: repo.id, to: &state))
            #expect(state.repos == original)
        }
        var state = AppState(repos: [fixture.repo])
        let original = state.repos
        for payload in [TransferableWorktreeMove(repoID: UUID(), worktreeID: fixture.task.id),
                        TransferableWorktreeMove(repoID: fixture.repo.id, worktreeID: UUID())] {
            #expect(!WorktreeDropReorder.pin(payload, repoID: fixture.repo.id, to: &state))
        }
        #expect(!WorktreeDropReorder.pin(.init(repoID: fixture.repo.id, worktreeID: fixture.task.id), repoID: UUID(), to: &state))
        #expect(state.repos == original)
    }

    @Test func appKitPayloadDecodesForTheHeaderDestination() async throws {
        let fixture = makeFixture()
        let payload = TransferableWorktreeMove(repoID: fixture.repo.id, worktreeID: fixture.task.id)
        let writer = try #require(WorktreeDragPasteboardWriter(payload))
        let data = writer.data
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: TransferableWorktreeMove.contentType.identifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        let decoded: TransferableWorktreeMove = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadTransferable(type: TransferableWorktreeMove.self) { continuation.resume(with: $0) }
        }
        var state = AppState(repos: [fixture.repo])
        #expect(WorktreeDropReorder.pin(decoded, repoID: fixture.repo.id, to: &state))
        #expect(state.worktree(forPath: fixture.task.path)?.isPinned == true)
    }

    @Test func folderAndPendingNeighborBoundariesKeepTheNewRoleAppended() {
        for pendingNeighbor in [false, true] {
            let home = WorktreeEntry(path: "/repo", branch: "trunk")
            let task = WorktreeEntry(path: pendingNeighbor ? "/repo/.worktrees/task" : "/repo/.worktrees/research/task", branch: "task")
            var neighbor = WorktreeEntry(path: pendingNeighbor ? "/repo/.worktrees/neighbor" : "/repo/.worktrees/research/lead", branch: "neighbor",
                state: pendingNeighbor ? .creating : .closed)
            neighbor.isPinned = true
            var target = WorktreeEntry(path: "/repo/.worktrees/target", branch: "target")
            target.isPinned = true
            let repo = RepoEntry(path: home.path, displayName: "Repo", worktrees: [home, task, neighbor, target])
            var state = AppState(repos: [repo])
            #expect(WorktreeRowDrop.worktree(.init(repoID: repo.id, worktreeID: task.id))
                .apply(repoID: repo.id, targetWorktreeID: target.id, placement: .before,
                       allowsReordering: true, to: &state) == .pinned)
            #expect(state.repos[0].worktrees.last?.id == task.id)
            #expect(state.repos[0].worktrees.last?.isPinned == true)
            #expect(state.repos[0].worktrees.filter { $0.id != task.id } == [home, neighbor, target])
        }
    }

    @Test func droppingBackOnTemporaryRowsDoesNotUnpin() {
        let fixture = makeFixture()
        var state = AppState(repos: [fixture.repo])
        #expect(WorktreeRowDrop.worktree(.init(repoID: fixture.repo.id, worktreeID: fixture.role.id))
            .apply(repoID: fixture.repo.id, targetWorktreeID: fixture.task.id, placement: .before,
                   allowsReordering: true, to: &state) == .rejected)
        #expect(state.repos[0] == fixture.repo)
    }

    private func makeFixture(mode: WorktreeOrderMode = .manual) -> (repo: RepoEntry, home: WorktreeEntry, task: WorktreeEntry, role: WorktreeEntry, other: WorktreeEntry) {
        let home = WorktreeEntry(path: "/repo", branch: "trunk")
        let pane = PaneSlotID()
        var task = WorktreeEntry(path: "/repo/.worktrees/task", branch: "task", state: .running, splitTree: .init(root: .leaf(pane)))
        _ = task.ensurePaneSession(for: pane)
        var role = WorktreeEntry(path: "/repo/.worktrees/reviewer", branch: "reviewer")
        role.isPinned = true
        let other = WorktreeEntry(path: "/repo/.worktrees/other", branch: "other")
        var repo = RepoEntry(path: home.path, displayName: "Repo", worktrees: [task, home, other, role])
        repo.worktreeOrderMode = mode
        return (repo, home, task, role, other)
    }
}
