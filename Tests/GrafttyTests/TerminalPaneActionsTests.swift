import SwiftUI
import Testing
@testable import Graftty
@testable import GrafttyKit

/// Characterizes the local pane-callback wiring `GrafttyApp.startup()`
/// installs on `TerminalManager`, driven through `dispatchPaneCommand` the
/// way libghostty actions and the surface context menu reach it.
@MainActor
@Suite("TerminalPaneActions")
struct TerminalPaneActionsTests {
    @MainActor
    private final class StateBox {
        var state: AppState
        init(_ state: AppState) { self.state = state }
        var binding: Binding<AppState> {
            Binding(get: { self.state }, set: { self.state = $0 })
        }
    }

    private let left = PaneSlotID()
    private let right = PaneSlotID()
    private let path = "/repo/wt"

    private func makeBox(ratio: Double = 0.3) -> StateBox {
        var worktree = WorktreeEntry(path: path, branch: "wt", state: .running)
        worktree.splitTree = SplitTree(root: .split(.init(
            direction: .horizontal, ratio: ratio, left: .leaf(left), right: .leaf(right)
        )))
        worktree.workspaceLayout = .preserving(worktree.splitTree)
        worktree.paneSessions = [left: PaneSessionID(), right: PaneSessionID()]
        worktree.focusedPaneSlotID = left
        return StateBox(AppState(
            repos: [RepoEntry(
                path: "/repo", displayName: "repo", worktrees: [worktree], defaultBranchHint: "trunk"
            )],
            selectedWorktreePath: path
        ))
    }

    private func installed(
        _ box: StateBox,
        sessionRegistry: ClaudeSessionRegistry? = nil
    ) -> TerminalManager {
        let manager = TerminalManager(socketPath: "/tmp/graftty-pane-actions-test.sock")
        TerminalPaneActions.install(
            on: manager,
            appState: box.binding,
            remoteBranchStore: RemoteBranchStore(list: { _ in RemoteBranchSnapshot() }),
            sessionRegistry: sessionRegistry ?? ClaudeSessionRegistry()
        )
        return manager
    }

    private func worktree(_ box: StateBox) throws -> WorktreeEntry {
        try #require(box.state.worktree(forPath: path))
    }

    @Test("install assigns every local pane callback")
    func installAssignsEveryCallback() {
        let manager = installed(makeBox())

        #expect(manager.onSplitRequest != nil)
        #expect(manager.onOpenInEditorPane != nil)
        #expect(manager.onMovePane != nil)
        #expect(manager.currentPaneMoveContext != nil)
        #expect(manager.onCloseRequest != nil)
        #expect(manager.onSurfaceClosed != nil)
        #expect(manager.onGotoSplit != nil)
        #expect(manager.onGotoSplitOrder != nil)
        #expect(manager.onToggleZoom != nil)
        #expect(manager.onResizeSplit != nil)
        #expect(manager.onEqualizeSplits != nil)
        #expect(manager.onReloadConfig != nil)
        #expect(manager.onOpenConfig != nil)
        #expect(manager.onCommandFinished != nil)
        #expect(manager.onShellReady != nil)
    }

    @Test("dispatched focus, zoom, and equalize commands reach the pane layout")
    func layoutCommandsMutateTheSplitTree() throws {
        let box = makeBox()
        let manager = installed(box)

        manager.dispatchPaneCommand(.focus(.right), for: left)
        #expect(try worktree(box).focusedPaneSlotID == right)

        manager.dispatchPaneCommand(.focusOrder(forward: true), for: right)
        #expect(try worktree(box).focusedPaneSlotID == left)

        manager.dispatchPaneCommand(.toggleZoom, for: left)
        #expect(try worktree(box).splitTree.zoomed == left)
        #expect(try worktree(box).canvasTree.zoomed == left)
        manager.dispatchPaneCommand(.toggleZoom, for: left)
        #expect(try worktree(box).splitTree.zoomed == nil)
        #expect(try worktree(box).canvasTree.zoomed == nil)

        manager.dispatchPaneCommand(.equalize, for: left)
        guard case .split(let split) = try worktree(box).splitTree.root else {
            Issue.record("expected a split root")
            return
        }
        #expect(split.ratio == 0.5)
        #expect(try worktree(box).workspaceLayout?.visibleSplitTree == worktree(box).splitTree)
    }

    @Test("a user close removes a pane with no surface, but a surface-closed event leaves it")
    func userCloseAndSurfaceClosedStayDistinct() throws {
        let box = makeBox()
        let manager = installed(box)

        // No live surface: a late close_surface_cb after Stop must not
        // drop the leaf (TERM-5.7), while a user close removes a phantom
        // leaf (TERM-5.8).
        manager.dispatchPaneCommand(.surfaceClosed, for: right)
        #expect(try worktree(box).splitTree.containsLeaf(right))

        manager.dispatchPaneCommand(.close, for: right)
        #expect(try !worktree(box).splitTree.containsLeaf(right))
        #expect(try worktree(box).splitTree.containsLeaf(left))
    }

    @Test("a finished command badges its pane, longer for a nonzero exit")
    func commandFinishedSetsPaneAttention() throws {
        let box = makeBox()
        let manager = installed(box)

        manager.onCommandFinished?(left, 0, 0)
        let success = try #require(try worktree(box).paneAttention[left])
        #expect(success.text == "✓")
        #expect(success.clearAfter == 3)
        #expect(success.source == .commandFinished)

        manager.onCommandFinished?(right, 1, 0)
        let failure = try #require(try worktree(box).paneAttention[right])
        #expect(failure.text == "!")
        #expect(failure.clearAfter == 8)
    }

    @Test("a finished command clears its pane's agent liveness")
    func commandFinishedClearsAgentLiveness() throws {
        let box = makeBox()
        let registry = ClaudeSessionRegistry()
        let manager = installed(box, sessionRegistry: registry)
        let session = try #require(try worktree(box).paneSessions[left])
        let name = ZmxLauncher.sessionName(for: session)
        registry.recordHook(
            runtime: .claude, event: .userPromptSubmit, sessionID: "session",
            paneSessionName: name, attentionReason: nil
        )
        #expect(registry.livenessBySession[name] == .busy)

        manager.onCommandFinished?(left, 0, 0)
        #expect(registry.livenessBySession[name] == nil)
    }

    @Test("the pane-move context resolves the pane's worktree and default branches")
    func paneMoveContextResolvesFromLiveState() throws {
        let manager = installed(makeBox())

        let context = try #require(manager.currentPaneMoveContext?(left))
        #expect(context.currentWorktree.path == path)
        #expect(context.defaultBranch(for: "/repo") == "trunk")
        #expect(manager.currentPaneMoveContext?(PaneSlotID()) == nil)
    }
}
