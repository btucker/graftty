import Foundation
import SwiftUI
import Testing
@testable import Graftty
@testable import GrafttyKit
import GrafttyProtocol

/// Characterization tests that pin the control-socket router's current
/// behavior so it can be moved and restructured without regressions
/// (issues #478, #481). They exercise `SocketRequestRouter.handleMessage` (the
/// fire-and-forget `onMessage` path) and the side-effect-free branches of
/// `SocketRequestRouter.handleRequest` (the request/response path), both of
/// which now run through the shared `ControlRequestCore`.
@MainActor
@Suite("Socket router characterization")
struct SocketRouterCharacterizationTests {
    private static let worktreePath = "/repo/feature"

    @MainActor
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
        // swiftlint:disable:next force_try
        try! RequestRouter().router(for: box).handleMessage(message)
    }

    // MARK: - handleMessage

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

    @Test("notify with a pane session and auto-clear sets clearing pane attention")
    func notifySetsClearingPaneAttention() {
        let (box, panes, sessions) = Self.fixture()
        Self.notify(.notify(path: Self.worktreePath, text: "Soon", clearAfter: 30, paneSessionName: sessions[0]), box)
        #expect(box.worktree.attention == nil)
        #expect(box.worktree.paneAttention[panes[0]]?.text == "Soon")
        #expect(box.worktree.paneAttention[panes[0]]?.clearAfter == 30)
        #expect(box.worktree.paneAttention[panes[0]]?.source == .userNotify)
        #expect(box.worktree.paneAttention[panes[1]] == nil)
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
    private final class RequestRouter {
        let directory: URL
        let terminalManager = TerminalManager(socketPath: "/tmp/graftty-router-characterization.sock")
        let teamInbox: TeamInbox
        let dispatcher: TeamEventDispatcher
        let remoteBranchStore = RemoteBranchStore()
        let creations = CLIWorktreeCreationStore()
        let removals = CLIWorktreeRemovalStore()
        let remoteMacsModel: RemoteMacsModel
        let remoteTeamRouter = RemoteTeamRouter()

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

        deinit {
            try? FileManager.default.removeItem(at: directory)
        }

        func router(for box: StateBox) -> SocketRequestRouter {
            SocketRequestRouter(
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
                remoteMacsModel: remoteMacsModel,
                remoteTeamRouter: remoteTeamRouter
            )
        }

        /// Routes through the production entry point: the shared core,
        /// then Mac platform dispatch, then remote-member enrichment.
        func route(_ message: NotificationMessage, _ box: StateBox) async -> ResponseMessage? {
            await router(for: box).handleRequest(message)
        }

        /// Calls Mac platform dispatch directly, bypassing the shared core.
        func paneDispatch(_ message: NotificationMessage, _ box: StateBox) async -> ResponseMessage? {
            await router(for: box).handlePaneRequest(message)
        }
    }

    private static let remoteWorktreeStatus = NotificationMessage.remoteWorktree(
        target: "mac", request: .status(operationID: "op")
    )

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
        #expect(await router.route(.capabilities, box)
            == .capabilities(ControlCapability.allCases.map(\.rawValue)))
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

    @Test("Mac platform dispatch answers remote routing itself and leaves team replies to the shared core")
    func platformDispatchHasNoRoutingStubs() async throws {
        let router = try RequestRouter()
        let (box, _, _) = Self.fixture()
        #expect(await router.paneDispatch(.reconnectRemoteClient(target: "mac"), box)
            == .error("Unknown or disconnected viewing Mac 'mac'. Connected clients: none"))
        #expect(await router.paneDispatch(Self.remoteWorktreeStatus, box)
            == .error("Unknown or disconnected Mac 'mac'. Connected Macs: none"))
        #expect(await router.paneDispatch(
            .teamReply(callerWorktree: Self.worktreePath, messageID: "m", text: "t", priority: .normal), box
        ) == .error("This request is not handled by the Mac app"))
    }

    @Test("the router answers remote and reply messages through the production path")
    func routerPreRoutesBeforePaneDispatch() async throws {
        let router = try RequestRouter()
        let (box, _, _) = Self.fixture()
        #expect(await router.route(.reconnectRemoteClient(target: "mac"), box)
            == .error("Unknown or disconnected viewing Mac 'mac'. Connected clients: none"))
        #expect(await router.route(Self.remoteWorktreeStatus, box)
            == .error("Unknown or disconnected Mac 'mac'. Connected Macs: none"))
        // The reply handler rejects an unknown message whether or not team
        // mode is enabled; only the error text depends on that setting.
        guard case .error(let replyError)? = await router.route(
            .teamReply(callerWorktree: Self.worktreePath, messageID: "m", text: "t", priority: .normal), box
        ) else {
            Issue.record("expected the team reply handler to reject an unknown message")
            return
        }
        #expect(replyError != "This request is not handled by the Mac app")
    }

    /// A connected peer that records forwarded sends and lists one member.
    @MainActor
    private final class FakePeer {
        let device = RemoteDeviceID(value: "peer-device")
        var sent: [RemoteTeamRequest] = []

        func connect(_ router: RemoteTeamRouter) {
            router.register(deviceID: device, connectionID: UUID(), label: "Studio") { [self] data in
                let request = try JSONDecoder().decode(RemoteTeamRequest.self, from: data)
                let response: RemoteTeamResponse
                if case .list = request {
                    response = .members([TeamListMember(name: "api", branch: "main", worktreePath: "/Users/peer/api",
                                                        isMainWorktree: true, isRunning: true)])
                } else {
                    await MainActor.run { sent.append(request) }
                    response = .ok
                }
                return try JSONEncoder().encode(response)
            }
        }
    }

    @Test("graftty-mac team sends and messages forward to the connected peer through the shared core")
    func remoteTeamSendForwardsToPeer() async throws {
        let router = try RequestRouter()
        let peer = FakePeer()
        peer.connect(router.remoteTeamRouter)
        let (box, _, _) = Self.fixture()
        let address = "graftty-mac://peer-device/Users/peer/api"
        #expect(await router.route(.teamSend(callerWorktree: Self.worktreePath, callerAgentID: "codex-test",
            recipient: address, text: "hello", priority: .urgent), box) == .ok)
        #expect(await router.route(.teamSend(callerWorktree: Self.worktreePath, recipient: address, text: "hi", priority: .normal), box) == .ok)
        #expect(peer.sent == [
            .send(senderWorktree: Self.worktreePath, senderAgentID: "codex-test", recipientWorktree: "/Users/peer/api",
                  recipientSuffix: nil, text: "hello", priority: .urgent),
            .send(senderWorktree: Self.worktreePath, senderAgentID: nil, recipientWorktree: "/Users/peer/api",
                  recipientSuffix: nil, text: "hi", priority: .normal),
        ])
    }

    @Test("@spec TEAM-1.1: When Graftty starts, the application shall make Agent Teams available without an enable switch, including for users who previously disabled them.")
    func legacyAgentTeamsOptOutIsIgnored() async throws {
        let legacyKey = "agentTeamsEnabled"
        let previous = UserDefaults.standard.object(forKey: legacyKey)
        UserDefaults.standard.set(false, forKey: legacyKey)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: legacyKey)
            } else {
                UserDefaults.standard.removeObject(forKey: legacyKey)
            }
        }
        let router = try RequestRouter()
        let (box, _, _) = Self.fixture()
        guard case .teamList(_, let members)? = await router.route(.teamList(callerWorktree: Self.worktreePath), box) else {
            Issue.record("a saved Agent Teams opt-out must not disable team requests")
            return
        }
        #expect(members.contains { $0.worktreePath == Self.worktreePath })
    }

    @Test("team lists through the router include the connected peer's members")
    func teamListIncludesRemoteMembers() async throws {
        let router = try RequestRouter()
        FakePeer().connect(router.remoteTeamRouter)
        let (box, _, _) = Self.fixture()
        guard case .teamList(_, let members)? = await router.route(.teamList(callerWorktree: Self.worktreePath), box) else {
            Issue.record("expected a team list")
            return
        }
        #expect(members.map(\.name).contains("Studio/api"))
        #expect(members.contains { $0.worktreePath == Self.worktreePath })
        // A scoped member query is not enriched.
        guard case .teamList(_, let scoped)? = await router.route(
            .teamMembers(callerWorktree: Self.worktreePath, worktree: Self.worktreePath, repo: nil), box
        ) else {
            Issue.record("expected a scoped team list")
            return
        }
        #expect(!scoped.map(\.name).contains("Studio/api"))
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
