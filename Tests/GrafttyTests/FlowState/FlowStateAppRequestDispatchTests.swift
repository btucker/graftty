import Foundation
import SwiftUI
import Testing
import GrafttyProtocol
@testable import Graftty
@testable import GrafttyKit

@MainActor
@Suite("FlowStateAppRequestDispatch")
struct FlowStateAppRequestDispatchTests {
    @Test("@spec FLOW-4.10: Flow State app request dispatch shall route context through app-built external signals where available.")
    func flowContextIncludesAppBuiltSignals() async throws {
        let root = try temporaryDirectory()
        let store = FlowStateStore(rootDirectory: root)
        let activityStore = FlowStateActivityStore(rootDirectory: root)
        let worktree = WorktreeEntry(path: "/repo/.worktrees/feature", branch: "feature", state: .running)
        let repo = RepoEntry(path: "/repo", displayName: "repo", worktrees: [worktree])
        let worktreeRef = FlowWorktreeIdentity.ref(
            repoDisplayName: "repo",
            repoPath: "/repo",
            worktreePath: worktree.path,
            branch: worktree.branch
        )
        let statsStore = WorktreeStatsStore(compute: { _, _, _, _ in
            WorktreeStatsStore.ComputeResult(
                defaultBranch: "main",
                stats: WorktreeStats(ahead: 3, behind: 2, insertions: 5, deletions: 1, hasUncommittedChanges: true)
            )
        })
        statsStore.refresh(worktreePath: worktree.path, repoPath: repo.path, branch: worktree.branch)
        try await waitUntil { statsStore.stats[worktree.path] != nil }

        let prStatusStore = PRStatusStore()
        prStatusStore.applyInfoForTesting(
            worktreePath: worktree.path,
            info: PRInfo(
                number: 42,
                title: "Feature",
                url: URL(string: "https://example.com/pr/42")!,
                state: .open,
                checks: .failure,
                mergeable: .conflicting,
                fetchedAt: Date(timeIntervalSince1970: 90)
            )
        )
        let flowMessageAt = Date(timeIntervalSince1970: 80)
        try activityStore.append(.init(
            createdAt: flowMessageAt,
            kind: .statusRequestSent,
            message: "asked",
            worktreeRef: worktreeRef
        ))
        let inputRegistry = PaneInputActivityRegistry(now: { Date(timeIntervalSince1970: 70) })
        let paneID = UUID(uuidString: "00000000-0000-0000-0000-000000000111")!
        inputRegistry.recordKeystroke(paneID: paneID)
        var withPane = worktree
        let paneSlot = PaneSlotID(id: paneID)
        withPane.focusedPaneSlotID = paneSlot
        withPane.paneSessions[paneSlot] = PaneSessionID(id: paneID)
        let paneAppState = AppState(repos: [RepoEntry(path: repo.path, displayName: repo.displayName, worktrees: [withPane])])

        let response = FlowStateAppRequestDispatcher.handle(
            .flowContext,
            appState: paneAppState,
            store: store,
            activityStore: activityStore,
            statsStore: statsStore,
            prStatusStore: prStatusStore,
            claudeSessionRegistry: nil,
            agentStateRegistry: nil,
            inputActivityRegistry: inputRegistry,
            statusProvider: nil,
            now: { Date(timeIntervalSince1970: 100) }
        )

        if case .flowContext(let context) = response {
            let snapshot = try #require(context.worktrees.first)
            #expect(snapshot.git?.dirtyCount == 6)
            #expect(snapshot.git?.ahead == 3)
            #expect(snapshot.git?.behind == 2)
            #expect(snapshot.pr?.number == 42)
            #expect(snapshot.pr?.ciConclusion == "failure")
            #expect(snapshot.pr?.mergeState == "conflicting")
            #expect(snapshot.pr?.urgency == .critical)
            #expect(snapshot.scoring.riskUrgency == .critical)
            #expect(snapshot.lastFlowMessageAt == flowMessageAt)
            #expect(snapshot.lastUserActivityAt == Date(timeIntervalSince1970: 70))
        } else {
            Issue.record("Expected flowContext response")
        }
    }

    @Test("@spec FLOW-4.11: Flow State app request dispatch shall preserve the last valid recommendation when a later publish is invalid.")
    func flowPublishPreservesValidRecommendationOnInvalidPublish() throws {
        let root = try temporaryDirectory()
        let store = FlowStateStore(rootDirectory: root)
        let activityStore = FlowStateActivityStore(rootDirectory: root)
        let valid = """
        {"schemaVersion":1,"generatedAt":"2026-07-03T19:00:00Z","primary":{"intent":"none","title":"Keep","reason":"Idle","confidence":"low"}}
        """
        let invalid = """
        {"schemaVersion":1,"generatedAt":"2026-07-03T19:00:00Z","primary":{"intent":"teleport","title":"Bad","reason":"Bad","confidence":"low"}}
        """

        #expect(FlowStateAppRequestDispatcher.handle(
            .flowPublish(rawJSON: valid),
            appState: AppState(),
            store: store,
            activityStore: activityStore
        ) == .ok)

        if case .error = FlowStateAppRequestDispatcher.handle(
            .flowPublish(rawJSON: invalid),
            appState: AppState(),
            store: store,
            activityStore: activityStore
        ) {
            #expect(try store.recommendation()?.primary.title == "Keep")
        } else {
            Issue.record("Expected invalid publish error")
        }
    }

    @Test("@spec FLOW-4.12: Flow State app request dispatch shall use an injected status provider.")
    func flowStatusUsesInjectedProvider() throws {
        let response = FlowStateAppRequestDispatcher.handle(
            .flowStatus,
            appState: AppState(),
            store: FlowStateStore(rootDirectory: try temporaryDirectory()),
            activityStore: FlowStateActivityStore(rootDirectory: try temporaryDirectory()),
            statusProvider: { FlowStatus(enabled: true, running: true, message: "Running") }
        )

        #expect(response == .flowStatus(FlowStatus(enabled: true, running: true, message: "Running")))
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @MainActor @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                Issue.record("Timed out waiting for condition")
                return
            }
            await Task.yield()
        }
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-flow-state-app-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
