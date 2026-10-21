import Foundation
import SwiftUI
import Testing
@testable import Graftty
@testable import GrafttyKit

/// Characterization tests that pin the control-socket router's current
/// behavior so it can be moved and restructured without regressions
/// (issue #478). They exercise `GrafttyApp.handleNotification` (the
/// fire-and-forget `onMessage` path) and the side-effect-free branches of
/// `GrafttyApp.handlePaneRequest` (the request/response path).
@MainActor
@Suite("Socket router characterization")
struct SocketRouterCharacterizationTests {
    private static let worktreePath = "/repo/feature"

    private final class StateBox {
        var state: AppState
        init(_ state: AppState) { self.state = state }
        var binding: Binding<AppState> {
            Binding(get: { self.state }, set: { self.state = $0 })
        }
        var worktree: WorktreeEntry { state.repos[0].worktrees[0] }
    }

    /// One running worktree with two panes, each bound to a zmx session.
    private static func fixture(
        state worktreeState: WorktreeState = .running
    ) -> (box: StateBox, panes: [PaneSlotID], sessions: [String]) {
        let first = PaneSlotID()
        let second = PaneSlotID()
        let firstSession = PaneSessionID()
        let secondSession = PaneSessionID()
        var worktree = WorktreeEntry(path: worktreePath, branch: "feature", state: worktreeState)
        worktree.splitTree = SplitTree(root: .split(.init(
            direction: .horizontal,
            ratio: 0.5,
            left: .leaf(first),
            right: .leaf(second)
        )))
        worktree.paneSessions = [first: firstSession, second: secondSession]
        let state = AppState(
            repos: [RepoEntry(path: "/repo", displayName: "repo", worktrees: [worktree])],
            selectedWorktreePath: worktreePath
        )
        return (
            StateBox(state),
            [first, second],
            [ZmxLauncher.sessionName(for: firstSession), ZmxLauncher.sessionName(for: secondSession)]
        )
    }

    private static func notify(_ message: NotificationMessage, _ box: StateBox) {
        GrafttyApp.handleNotification(
            message,
            appState: box.binding,
            terminalManager: TerminalManager(socketPath: "/tmp/graftty-router-characterization.sock")
        )
    }

    // MARK: - handleNotification

    @Test("notify without a pane session sets worktree-scoped user attention")
    func notifySetsWorktreeAttention() {
        let (box, _, _) = Self.fixture()
        Self.notify(.notify(path: Self.worktreePath, text: "Build done"), box)
        #expect(box.worktree.attention?.text == "Build done")
        #expect(box.worktree.attention?.source == .userNotify)
        #expect(box.worktree.attention?.clearAfter == nil)
        #expect(box.worktree.paneAttention.isEmpty)
    }

    @Test("notify clamps the requested auto-clear to the server maximum")
    func notifyClampsClearAfter() {
        let (box, _, _) = Self.fixture()
        Self.notify(.notify(path: Self.worktreePath, text: "Later", clearAfter: 1_000_000), box)
        #expect(box.worktree.attention?.clearAfter == Attention.clearAfterMaxSeconds)
    }

    @Test("notify treats a non-positive auto-clear as no auto-clear")
    func notifyDropsNonPositiveClearAfter() {
        let (box, _, _) = Self.fixture()
        Self.notify(.notify(path: Self.worktreePath, text: "Now", clearAfter: 0), box)
        #expect(box.worktree.attention?.text == "Now")
        #expect(box.worktree.attention?.clearAfter == nil)
    }

    @Test("notify with whitespace-only text leaves state unchanged")
    func notifyRejectsBlankText() {
        let (box, _, _) = Self.fixture()
        let before = box.state
        Self.notify(.notify(path: Self.worktreePath, text: "  \n\t "), box)
        #expect(box.state == before)
    }

    @Test("notify for an untracked path leaves state unchanged")
    func notifyIgnoresUntrackedPath() {
        let (box, _, _) = Self.fixture()
        let before = box.state
        Self.notify(.notify(path: "/elsewhere", text: "Hello"), box)
        #expect(box.state == before)
    }

    @Test("notify with a resolvable pane session sets only that pane's attention")
    func notifySetsPaneAttention() {
        let (box, panes, sessions) = Self.fixture()
        Self.notify(.notify(path: Self.worktreePath, text: "Pane two", paneSessionName: sessions[1]), box)
        #expect(box.worktree.attention == nil)
        #expect(box.worktree.paneAttention[panes[1]]?.text == "Pane two")
        #expect(box.worktree.paneAttention[panes[1]]?.source == .userNotify)
        #expect(box.worktree.paneAttention[panes[0]] == nil)
    }

    @Test("notify with an unresolvable pane session falls back to worktree attention")
    func notifyUnknownPaneFallsBackToWorktree() {
        let (box, _, _) = Self.fixture()
        Self.notify(.notify(path: Self.worktreePath, text: "Fallback", paneSessionName: "graftty-gone"), box)
        #expect(box.worktree.attention?.text == "Fallback")
        #expect(box.worktree.paneAttention.isEmpty)
    }

    @Test("pane-scoped clear removes only that pane's attention")
    func clearPaneAttention() {
        let (box, panes, sessions) = Self.fixture()
        Self.notify(.notify(path: Self.worktreePath, text: "Worktree"), box)
        Self.notify(.notify(path: Self.worktreePath, text: "One", paneSessionName: sessions[0]), box)
        Self.notify(.notify(path: Self.worktreePath, text: "Two", paneSessionName: sessions[1]), box)

        Self.notify(.clear(path: Self.worktreePath, paneSessionName: sessions[0]), box)

        #expect(box.worktree.paneAttention[panes[0]] == nil)
        #expect(box.worktree.paneAttention[panes[1]]?.text == "Two")
        #expect(box.worktree.attention?.text == "Worktree")
    }

    @Test("clear with an unresolvable pane session clears worktree attention")
    func clearUnknownPaneFallsBackToWorktree() {
        let (box, panes, sessions) = Self.fixture()
        Self.notify(.notify(path: Self.worktreePath, text: "Worktree"), box)
        Self.notify(.notify(path: Self.worktreePath, text: "One", paneSessionName: sessions[0]), box)

        Self.notify(.clear(path: Self.worktreePath, paneSessionName: "graftty-gone"), box)

        #expect(box.worktree.attention == nil)
        #expect(box.worktree.paneAttention[panes[0]]?.text == "One")
    }

    @Test("worktree-scoped clear removes worktree attention")
    func clearWorktreeAttention() {
        let (box, _, _) = Self.fixture()
        Self.notify(.notify(path: Self.worktreePath, text: "Worktree"), box)
        Self.notify(.clear(path: Self.worktreePath), box)
        #expect(box.worktree.attention == nil)
    }

    @Test("request-style messages are no-ops on the fire-and-forget path")
    func requestMessagesIgnoredByNotificationPath() {
        let (box, _, _) = Self.fixture()
        let before = box.state
        Self.notify(.listPanes(path: Self.worktreePath), box)
        Self.notify(.closePane(path: Self.worktreePath, index: 1), box)
        Self.notify(.worktreeBaseCapability, box)
        #expect(box.state == before)
    }

    // MARK: - handlePaneRequest

    @MainActor
    private struct RequestRouter {
        let directory: URL
        let terminalManager = TerminalManager(socketPath: "/tmp/graftty-router-characterization.sock")
        let teamInbox: TeamInbox
        let dispatcher: TeamEventDispatcher
        let remoteBranchStore = RemoteBranchStore()
        let creations = CLIWorktreeCreationStore()
        let removals = CLIWorktreeRemovalStore()
        let remoteMacsModel: RemoteMacsModel

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("socket-router-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            teamInbox = TeamInbox(rootDirectory: directory.appendingPathComponent("inbox"))
            dispatcher = TeamEventDispatcher(
                inbox: teamInbox,
                preferencesProvider: { TeamEventRoutingPreferences() },
                templateProvider: { "" }
            )
            remoteMacsModel = RemoteMacsModel(
                store: RemoteMacStore(storeURL: directory.appendingPathComponent("remotes.json"))
            )
        }

        func route(_ message: NotificationMessage, _ box: StateBox) async -> ResponseMessage? {
            await GrafttyApp.handlePaneRequest(
                message,
                appState: box.binding,
                terminalManager: terminalManager,
                teamInbox: teamInbox,
                teamEventDispatcher: dispatcher,
                worktreeMonitor: WorktreeMonitor(),
                statsStore: WorktreeStatsStore(),
                prStatusStore: PRStatusStore(remoteBranchStore: remoteBranchStore),
                worktreeCreations: creations,
                worktreeRemovals: removals,
                remoteBranchStore: remoteBranchStore,
                agentRegistry: ClaudeSessionRegistry(),
                remoteMacsModel: remoteMacsModel
            )
        }
    }

    @Test("fire-and-forget messages produce no request response")
    func fireAndForgetMessagesReturnNil() async throws {
        let router = try RequestRouter()
        let (box, _, _) = Self.fixture()
        #expect(await router.route(.notify(path: Self.worktreePath, text: "Hi"), box) == nil)
        #expect(await router.route(.clear(path: Self.worktreePath), box) == nil)
        // The request path must not apply the notification itself.
        #expect(box.worktree.attention == nil)
    }

    @Test("capability probes answer ok")
    func capabilityProbesAnswerOK() async throws {
        let router = try RequestRouter()
        let (box, _, _) = Self.fixture()
        for probe: NotificationMessage in [
            .agentPromptStagingCapability, .worktreeBaseCapability,
            .worktreeCreateIdempotencyCapability, .remoteWorktreeCapability,
            .worktreeRemoveCapability, .worktreePinnedRemovalCapability, .worktreePinCapability,
        ] {
            #expect(await router.route(probe, box) == .ok)
        }
    }

    @Test("listPanes reports untracked and non-running worktrees as errors")
    func listPanesErrors() async throws {
        let router = try RequestRouter()
        let (running, _, _) = Self.fixture()
        #expect(await router.route(.listPanes(path: "/elsewhere"), running) == .error("not tracked"))
        let (closed, _, _) = Self.fixture(state: .closed)
        #expect(await router.route(.listPanes(path: Self.worktreePath), closed) == .error("worktree not running"))
    }

    @Test("listPanes numbers panes in tree order and marks focus")
    func listPanesReportsPanes() async throws {
        let router = try RequestRouter()
        let (box, panes, _) = Self.fixture()
        box.state.repos[0].worktrees[0].focusedPaneSlotID = panes[1]
        guard case .paneList(let list)? = await router.route(.listPanes(path: Self.worktreePath), box) else {
            Issue.record("expected a pane list")
            return
        }
        #expect(list.map(\.id) == [1, 2])
        #expect(list.map(\.focused) == [false, true])
    }

    @Test("routes the dispatcher does not own report unavailability")
    func unownedRoutesReportUnavailable() async throws {
        let router = try RequestRouter()
        let (box, _, _) = Self.fixture()
        #expect(await router.route(
            .teamReply(callerWorktree: Self.worktreePath, messageID: "m", text: "t", priority: .normal), box
        ) == .error("Team reply routing is unavailable"))
    }

    @Test("unknown worktree operation IDs report expiry")
    func unknownOperationStatusErrors() async throws {
        let router = try RequestRouter()
        let (box, _, _) = Self.fixture()
        #expect(await router.route(.worktreeCreateStatus(operationID: "missing"), box)
            == .error("unknown or expired worktree creation operation"))
        #expect(await router.route(.worktreeRemoveStatus(operationID: "missing"), box)
            == .error("unknown or expired worktree removal operation"))
    }
}
