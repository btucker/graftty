import SwiftUI
import Testing
@testable import Graftty
import GrafttyKit

@MainActor
@Suite
struct RetainedWorktreeRestoreTests {
    @Test("@spec AGENT-5.28: When launch reconciliation confirms a live zmx daemon for every leaf of a closed worktree's nonempty retained layout, the application shall restore that worktree to running with its layout and session identities intact, and suppress replay of its agent or default command. If the daemon query fails, any mapping or daemon is absent, or the worktree is stale or in flight, then the application shall preserve its state.")
    func restoresOnlyConfirmedRetainedSessions() {
        let pane = PaneSlotID()
        let session = PaneSessionID()
        var retained = WorktreeEntry(path: "/repo/retained", branch: "retained")
        retained.splitTree = SplitTree(root: .leaf(pane))
        retained.paneSessions[pane] = session
        var stale = retained
        stale.path = "/repo/stale"
        stale.state = .stale
        var creating = retained
        creating.path = "/repo/creating"
        creating.state = .creating
        var stopped = retained
        stopped.path = "/repo/stopped"
        stopped.prepareForStop()
        var orphan = retained
        orphan.path = "/repo/orphan"
        orphan.paneSessions = [PaneSlotID(): session]
        var state = AppState(repos: [RepoEntry(path: "/repo", displayName: "repo",
            worktrees: [retained, stale, creating, stopped, orphan])], selectedWorktreePath: "/repo/elsewhere")
        let binding = Binding(get: { state }, set: { state = $0 })
        let manager = TerminalManager(socketPath: "/tmp/graftty-retained-restore.sock")
        let before = state
        GrafttyApp.recoverRetainedWorktrees(appState: binding, terminalManager: manager, liveSessions: nil)
        #expect(state == before)
        GrafttyApp.recoverRetainedWorktrees(appState: binding, terminalManager: manager, liveSessions: [])
        #expect(state == before)
        GrafttyApp.recoverRetainedWorktrees(appState: binding, terminalManager: manager, liveSessions: [ZmxLauncher.sessionName(for: session)])
        #expect(state.worktree(forPath: retained.path)?.state == .running)
        #expect(state.worktree(forPath: stale.path) == stale)
        #expect(state.worktree(forPath: creating.path) == creating)
        #expect(state.worktree(forPath: stopped.path) == stopped)
        #expect(state.worktree(forPath: orphan.path) == orphan)
        #expect(state.selectedWorktreePath == before.selectedWorktreePath)
        let restored = state.repos[0].worktrees[0]
        #expect(restored.splitTree == retained.splitTree)
        #expect(restored.paneSessions == retained.paneSessions)
        #expect(restored.focusedPaneSlotID == pane)
        #expect(manager.wasRehydrated(pane))
        #expect(manager.worktreePath(forSessionName: ZmxLauncher.sessionName(for: session)) == retained.path)
        #expect(manager.isFirstPane(pane))
        #expect(defaultCommandDecision(defaultCommand: "claude", firstPaneOnly: true,
            isFirstPane: true, wasRehydrated: manager.wasRehydrated(pane), hasExplicitInitialInput: false) == .skip)
    }

    @Test("Recovery preserves all live leaves and their remembered primary pane")
    func completeMultiPaneLayoutIsRecovered() {
        let left = PaneSlotID()
        let right = PaneSlotID()
        var retained = WorktreeEntry(path: "/repo/complete", branch: "complete")
        retained.splitTree = SplitTree(root: .split(.init(direction: .horizontal, ratio: 0.3,
            left: .leaf(left), right: .leaf(right))))
        retained.paneSessions = [left: PaneSessionID(), right: PaneSessionID()]
        retained.primaryPaneSlotID = right
        var state = AppState(repos: [RepoEntry(path: "/repo", displayName: "repo", worktrees: [retained])])
        let binding = Binding(get: { state }, set: { state = $0 })
        let manager = TerminalManager(socketPath: "/tmp/graftty-complete-restore.sock")
        let recovered = GrafttyApp.recoverRetainedWorktrees(appState: binding, terminalManager: manager,
            liveSessions: Set(retained.paneSessions.values.map(ZmxLauncher.sessionName(for:))))
        #expect(recovered == [retained.path])
        let restored = state.repos[0].worktrees[0]
        #expect(restored.state == .running)
        #expect(restored.splitTree == retained.splitTree)
        #expect(restored.paneSessions == retained.paneSessions)
        #expect(restored.focusedPaneSlotID == left)
        #expect(restored.primaryPaneSlotID == right)
        #expect(manager.wasRehydrated(left))
        #expect(manager.wasRehydrated(right))
        #expect(manager.isFirstPane(right))
        #expect(!manager.isFirstPane(left))
    }

    @Test("Cold recovery leaves a partially surviving layout closed without creating replacement shells")
    func partialLayoutIsNotAutomaticallyRecovered() {
        let livePane = PaneSlotID()
        let missingPane = PaneSlotID()
        let liveSession = PaneSessionID()
        var retained = WorktreeEntry(path: "/repo/partial", branch: "partial")
        retained.splitTree = SplitTree(root: .split(.init(direction: .horizontal, ratio: 0.5,
            left: .leaf(livePane), right: .leaf(missingPane))))
        retained.paneSessions = [livePane: liveSession, missingPane: PaneSessionID()]
        var state = AppState(repos: [RepoEntry(path: "/repo", displayName: "repo", worktrees: [retained])],
            selectedWorktreePath: retained.path)
        let binding = Binding(get: { state }, set: { state = $0 })
        let manager = TerminalManager(socketPath: "/tmp/graftty-partial-restore.sock")
        GrafttyApp.recoverRetainedWorktrees(appState: binding, terminalManager: manager,
            liveSessions: [ZmxLauncher.sessionName(for: liveSession)])
        #expect(state.repos[0].worktrees[0] == retained)
        #expect(manager.handle(for: livePane) == nil)
        #expect(manager.handle(for: missingPane) == nil)
        #expect(!manager.wasRehydrated(livePane))
    }

    @Test("Reopening a retained pane marks it rehydrated before surface creation")
    func reopeningRetainedPaneSuppressesDefaultReplay() {
        let pane = PaneSlotID()
        let session = PaneSessionID()
        var retained = WorktreeEntry(path: "/repo/retained", branch: "retained")
        retained.splitTree = SplitTree(root: .leaf(pane))
        retained.paneSessions[pane] = session
        var state = AppState(repos: [RepoEntry(path: "/repo", displayName: "repo", worktrees: [retained])])
        let binding = Binding(get: { state }, set: { state = $0 })
        let manager = TerminalManager(socketPath: "/tmp/graftty-retained-open.sock")
        #expect(GrafttyApp.startWorktree(path: retained.path, appState: binding, terminalManager: manager) == .started)
        #expect(manager.wasRehydrated(pane))
        #expect(state.repos[0].worktrees[0].paneSessions[pane] == session)
    }
}
