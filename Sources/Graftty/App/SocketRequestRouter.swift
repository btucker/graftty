import SwiftUI
import AppKit
import GrafttyCommandUI
import GrafttyHostAgent
import GrafttyKit
import GrafttyProtocol
import GrafttyRemoteClient

/// Routes control-socket traffic from the `graftty` CLI and other local
/// clients into app state. `SocketServer` delivers every message to
/// `handleMessage(_:)` and also awaits `handleRequest(_:)` for messages that
/// expect a response, both on the main actor.
///
/// Collaborators are injected individually so tests can build a router
/// without `AppServices`, which touches the real application-support
/// directory.
@MainActor
final class SocketRequestRouter {
    private static let wakeFailure = "Could not resume worktree processes. Retry before interacting with this worktree."

    let appState: Binding<AppState>
    let terminalManager: TerminalManager
    let teamInbox: TeamInbox
    let teamEventDispatcher: TeamEventDispatcher
    let worktreeMonitor: WorktreeMonitor
    let worktreeManagement: WorktreeManagement
    let remoteBranchStore: RemoteBranchStore
    let agentRegistry: ClaudeSessionRegistry
    let remoteMacsModel: RemoteMacsModel
    let remoteTeamRouter: RemoteTeamRouter

    init(
        appState: Binding<AppState>,
        terminalManager: TerminalManager,
        teamInbox: TeamInbox,
        teamEventDispatcher: TeamEventDispatcher,
        worktreeMonitor: WorktreeMonitor,
        statsStore: WorktreeStatsStore,
        prStatusStore: PRStatusStore,
        worktreeCreations: CLIWorktreeCreationStore,
        worktreeRemovals: CLIWorktreeRemovalStore,
        remoteBranchStore: RemoteBranchStore,
        agentRegistry: ClaudeSessionRegistry,
        remoteMacsModel: RemoteMacsModel,
        remoteTeamRouter: RemoteTeamRouter
    ) {
        self.appState = appState
        self.terminalManager = terminalManager
        self.teamInbox = teamInbox
        self.teamEventDispatcher = teamEventDispatcher
        self.worktreeMonitor = worktreeMonitor
        self.worktreeManagement = WorktreeManagement(
            appState: appState, terminalManager: terminalManager, teamInbox: teamInbox,
            teamEventDispatcher: teamEventDispatcher, worktreeMonitor: worktreeMonitor,
            statsStore: statsStore, prStatusStore: prStatusStore, remoteBranchStore: remoteBranchStore,
            worktreeCreations: worktreeCreations, worktreeRemovals: worktreeRemovals
        )
        self.remoteBranchStore = remoteBranchStore
        self.agentRegistry = agentRegistry
        self.remoteMacsModel = remoteMacsModel
        self.remoteTeamRouter = remoteTeamRouter
    }

    var parentMCPConnections: MCPConnectionSupervisor?
    private var parentServerPublicKey: () -> String? = { nil }

    convenience init(
        appState: Binding<AppState>,
        terminalManager: TerminalManager,
        services: AppServices
    ) {
        self.init(
            appState: appState,
            terminalManager: terminalManager,
            teamInbox: services.teamInbox,
            teamEventDispatcher: services.teamEventDispatcher,
            worktreeMonitor: services.worktreeMonitor,
            statsStore: services.statsStore,
            prStatusStore: services.prStatusStore,
            worktreeCreations: services.cliWorktreeCreations,
            worktreeRemovals: services.cliWorktreeRemovals,
            remoteBranchStore: services.remoteBranchStore,
            agentRegistry: services.claudeSessionRegistry,
            remoteMacsModel: services.remoteMacsModel,
            remoteTeamRouter: services.remoteTeamRouter
        )
        parentMCPConnections = services.parentMCPConnections
        parentServerPublicKey = { [weak services] in services?.hostKey()?.publicKey.rawRepresentation.base64EncodedString() }
    }

    /// Fire-and-forget path (`SocketServer.onMessage`).
    func handleMessage(_ message: NotificationMessage) {
        ControlRequestCore.handleMessage(message, platform: self)
    }

    /// Request/response path (`SocketServer.onAsyncRequest`). The shared
    /// core answers attention, recap, team, capability, and worktree
    /// create/remove messages (routing `graftty-mac:` recipients through
    /// `remoteTeamRouter`) and hands the rest to `handlePaneRequest`; team
    /// lists then gain remote members.
    func handleRequest(_ message: NotificationMessage) async -> ResponseMessage? {
        let response = await ControlRequestCore.handleRequest(message, platform: self)
        return await remoteTeamRouter.includingRemoteMembers(in: response, for: message)
    }

    /// Mac-specific dispatch for requests the shared core does not own.
    func handlePaneRequest(_ message: NotificationMessage) async -> ResponseMessage? {
        if case .addProject(let path) = message {
            return await addProject(path: path)
        }
        if case .mcpConnection(let request) = message {
            guard let parentMCPConnections else { return .error("Parent MCP service is unavailable") }
            return await parentMCPConnections.handle(request)
        }
        let response = await Self.handlePaneRequest(
            message,
            appState: appState,
            terminalManager: terminalManager,
            teamInbox: teamInbox,
            remoteMacsModel: remoteMacsModel,
            remoteTeamRouter: remoteTeamRouter
        )
        if case .linuxSetupIdentity(let identity) = response {
            return .linuxSetupIdentity(.init(deviceID: identity.deviceID, displayName: identity.displayName,
                publicKey: identity.publicKey, serverPublicKey: parentServerPublicKey()))
        }
        return response
    }

    func addProject(
        path: String,
        prepare: (String) async throws -> ProjectRegistration = { try await ProjectRegistration.prepare(path: $0) },
        now: () -> ContinuousClock.Instant = { .now }
    ) async -> ResponseMessage {
        // SocketServer releases an expired request without cancelling its task.
        // Reserve time for persistence and discard slow preparation before it
        // can register a project after the CLI has reported a lost connection.
        let deadline = now() + .seconds(SocketServer.defaultRequestTimeoutSeconds - 1)
        do {
            let registration = try await prepare(path)
            try Task.checkCancellation()
            guard now() < deadline, SocketServer.requestIsActive() else {
                return .error("Project discovery timed out at \(path); retry when the directory is responsive.")
            }
            registration.apply(to: &appState.wrappedValue)
            if let repo = appState.wrappedValue.repos.first(where: { $0.path == registration.repo.path }) {
                worktreeMonitor.installRepoWatchers(repo: repo)
            }
            remoteBranchStore.refresh(repoPath: registration.repo.path)
            try await GrafttyApp.persistAppStateNow(appState.wrappedValue)
            return .ok
        } catch {
            return .error("Could not add project at \(path): \(error.localizedDescription)")
        }
    }

}

extension SocketRequestRouter {
    /// Dispatcher for request-style messages from the CLI. Returns a
    /// `ResponseMessage` the server writes back to the client. Must run
    /// on the main actor because it touches `appState` and `terminalManager`.
    @MainActor
    static func handlePaneRequest(
        _ message: NotificationMessage,
        appState: Binding<AppState>,
        terminalManager: TerminalManager,
        teamInbox: TeamInbox,
        remoteMacsModel: RemoteMacsModel,
        remoteTeamRouter: RemoteTeamRouter
    ) async -> ResponseMessage? {
        switch message {
        case .offerResource(let path, _, let session), .previewImage(let path, _, let session), .previewFiles(let path, _, let session):
            guard let worktree = OpenResourceRouting.worktree(path: path, paneSessionName: session, state: appState.wrappedValue) else {
                return .error("The originating pane is unavailable. Run graftty open from a tracked worktree.")
            }
            guard terminalManager.wakeWorktree(worktree.path) else { return .error(Self.wakeFailure) }
        case .addPane(let request):
            guard terminalManager.wakeWorktree(request.path) else { return .error(Self.wakeFailure) }
        case .closePane(let path, _), .showPane(let path, _, _), .sendPane(let path, _, _, _):
            guard terminalManager.wakeWorktree(path) else { return .error(Self.wakeFailure) }
        default: break
        }
        switch message {
        case .linuxSetupIdentity:
            do {
                let store = ClientIdentityStore(directory: ClientIdentityStore.defaultDirectory)
                let key = try store.loadOrGenerateAndPersist()
                return .linuxSetupIdentity(LinuxHostTrustRequest(
                    deviceID: try AppServices.localRemoteDeviceID().value,
                    displayName: AppServices.localHostDisplayName(),
                    publicKey: key.publicKey.rawRepresentation.base64EncodedString()
                ))
            } catch { return .error(LinuxHostSetupError.message(for: error)) }
        case .completeLinuxSetup(let result):
            do {
                // Load persisted identities before checking for conflicting pins.
                await remoteMacsModel.loadSavedRemotes()
                try Task.checkCancellation()
                let controller = LinuxHostSetupConnectionController(
                    pinnedHostStore: PinnedHostStore(directory: PinnedHostStore.defaultDirectory)
                )
                let saved = try controller.save(result, model: remoteMacsModel)
                // Socket handlers have a five-second limit. Connection progress
                // and failures are reflected by the model after acknowledging save.
                Task { _ = try? await remoteMacsModel.connect(to: saved) }
                return .ok
            } catch { return .error(LinuxHostSetupError.message(for: error)) }
        case let .previewFiles(path, targets, paneSessionName):
            return await FilePreviewRequest.handle(path: path, targets: targets, paneSessionName: paneSessionName,
                                                   state: { appState.wrappedValue }, terminalManager: terminalManager)
        case let .previewImage(path, target, paneSessionName):
            return await ImagePreviewRequest.handle(path: path, target: target, paneSessionName: paneSessionName,
                                                    state: { appState.wrappedValue }, terminalManager: terminalManager)
        case let .offerResource(path, target, paneSessionName):
            guard let worktree = OpenResourceRouting.worktree(path: path, paneSessionName: paneSessionName, state: appState.wrappedValue) else {
                return .error("Run graftty open from a tracked worktree.")
            }
            do {
                let url = try OpenResourceTarget.resolve(target)
                let destination: OpenResourceRouting.Destination
                if let ownershipStore = terminalManager.displayOwnershipStore {
                    destination = OpenResourceRouting.destination(
                        paneSessionName: paneSessionName,
                        belongsToWorktree: paneSessionName.flatMap { worktree.paneSlot(forSessionName: $0) } != nil,
                        ownershipStore: ownershipStore
                    )
                } else {
                    destination = .mac
                }
                switch destination {
                case .mobile:
                    let ownerClientID = paneSessionName.flatMap {
                        terminalManager.displayOwnershipStore?.snapshot(sessionName: $0).ownerClientID
                    }
                    _ = try await RemoteOpenStore.shared.offer(
                        file: url, worktree: worktree.path, browserOwnerClientID: ownerClientID,
                        paneSessionName: paneSessionName
                    )
                case .mac:
                    guard NSWorkspace.shared.open(url) else {
                        return .error("macOS could not open this resource.")
                    }
                }
                return .ok
            } catch {
                return .error(error.localizedDescription)
            }

        case .remoteSkills(let host, let request):
            return await remoteMacsModel.transferSkills(on: host, request: request)
        case .remotePlacement(let host, let request):
            return await remoteMacsModel.place(on: host, request: request)
        case .listRemoteHosts:
            return .remoteHosts(await remoteMacsModel.remoteMacConnectionSummaries())
        case .reconnectRemoteMac(let target):
            return await remoteMacsModel.reconnectRemoteMac(target: target)
        case .remoteWorktree(let target, let request):
            return await remoteTeamRouter.worktree(target: target, request: request, repos: appState.wrappedValue.repos)
        case .reconnectRemoteClient(let target):
            return await remoteTeamRouter.reconnectClient(target: target)
        case .listPanes(let path):
            return listPanes(path: path, appState: appState, terminalManager: terminalManager)
        case .addPane(let request):
            return await addPane(path: request.path, direction: request.direction, command: request.command,
                                 agentRuntime: request.agentRuntime, agentPrompt: request.agentPrompt, managedAgent: request.managedAgent, teamInbox: teamInbox,
                                 appState: appState, terminalManager: terminalManager)
        case .closePane(let path, let index):
            return closePaneByIndex(path: path, index: index,
                                    appState: appState, terminalManager: terminalManager)
        case .showPane(let path, let index, let lines):
            guard let launcher = terminalManager.zmxLauncher else {
                return .error("zmx unavailable")
            }
            guard let wt = appState.wrappedValue.worktree(forPath: path) else {
                return .error("not tracked")
            }
            guard wt.state == .running else {
                return .error("worktree not running")
            }
            guard let terminalID = wt.splitTree.leaf(atPaneID: index) else {
                return .error("no pane with id \(index) in this worktree")
            }
            guard let sessionID = wt.paneSessions[terminalID] else {
                return .error("pane has no session")
            }
            let reader = ZmxHistorySubprocessReader(launcher: launcher)
            let sessionName = ZmxLauncher.sessionName(for: sessionID)
            return await Task.detached(priority: .utility) {
                showPaneResponse(sessionName: sessionName, lines: lines, reader: reader)
            }.value
        case .sendPane(let path, let index, let text, let pressEnter):
            return await handleSendPane(
                path: path, index: index, text: text, pressEnter: pressEnter,
                appState: appState, terminalManager: terminalManager
            )
        case .setWorktreePinned(let path, let isPinned):
            let response = WorktreePinRequestHandler.handle(
                worktreePath: path, isPinned: isPinned, state: &appState.wrappedValue
            )
            if response == .ok { GrafttyApp.persistAppState(appState.wrappedValue) }
            return response
        default:
            // ControlRequestCore answers attention, recap, team,
            // capability, and worktree create/remove messages before
            // platform dispatch.
            return .error("This request is not handled by the Mac app")
        }
    }

    @MainActor
    private static func listPanes(
        path: String,
        appState: Binding<AppState>,
        terminalManager: TerminalManager
    ) -> ResponseMessage {
        guard let wt = appState.wrappedValue.worktree(forPath: path) else {
            return .error("not tracked")
        }
        // Symmetric with `addPane` / `closePaneByIndex`: a .closed worktree
        // has no panes by construction, and returning an empty `.paneList`
        // looks like a silent success to scripts. Surface the state
        // explicitly instead (ATTN-3.5).
        guard wt.state == .running else {
            return .error("worktree not running")
        }
        let leaves = wt.splitTree.allLeaves
        let panes = leaves.enumerated().map { (i, terminalID) -> PaneInfo in
            // Use the derived label (title → PWD basename → nil) so the
            // CLI sees the same fallback chain the sidebar renders. Map
            // the view-level empty sentinel back to nil for the CLI
            // contract "title is nil when unknown".
            let display = terminalManager.displayTitle(for: terminalID)
            return PaneInfo(
                id: i + 1,
                title: display.isEmpty ? nil : display,
                focused: terminalID == wt.focusedPaneSlotID
            )
        }
        return .paneList(panes)
    }

    @MainActor
    private static func addPane(
        path: String,
        direction: PaneSplit,
        command: String?,
        agentRuntime: TeamHookRuntime?,
        agentPrompt: String?,
        managedAgent: ManagedAgent?,
        teamInbox: TeamInbox,
        appState: Binding<AppState>,
        terminalManager: TerminalManager
    ) async -> ResponseMessage {
        if let error = CLIWorktreeCreationPolicy.paneAddError(
            agentRuntime: agentRuntime,
            command: command,
            agentPrompt: agentPrompt
        ) {
            return .error(error)
        }
        if managedAgent != nil, appState.wrappedValue.worktree(forPath: path)?.state == .closed {
            _ = PaneCommands.startWorktree(path: path, appState: appState, terminalManager: terminalManager)
        }
        func splitTargetError() -> String? {
            guard let wt = appState.wrappedValue.worktree(forPath: path) else { return "not tracked" }
            guard wt.state == .running else { return "worktree not running" }
            return wt.firstPane == nil ? "no panes to split" : nil
        }
        if let error = splitTargetError() {
            return .error(error)
        }
        var launch = PreparedWorktreeAgentLaunch(command: command, promptFile: nil)
        var savedTask: TeamInboxMessage?
        // A durable task saved for an agent that never launches would reach
        // the next agent of that runtime, possibly the implementer.
        func abandonLaunch() async {
            launch.discardPromptFile()
            if let savedTask {
                _ = await OffMainIO.run { try? PaneAgentLaunch.withdrawInitialPrompt(savedTask, inbox: teamInbox) }
            }
        }
        if let agentRuntime {
            do {
                launch = try WorktreeAgentLaunchCommand.prepare(agent: agentRuntime, prompt: agentPrompt, exactCommand: nil, managedAgent: managedAgent)
            } catch {
                return .error("could not stage agent prompt: \(error.localizedDescription)")
            }
            if managedAgent == nil, let repo = appState.wrappedValue.repo(forWorktreePath: path),
               let branch = appState.wrappedValue.worktree(forPath: path)?.branch {
                // Map pane sessions on the main actor; read presence inside the
                // off-main save, after its pending-task check (AGENT-6.57).
                let paneSessionNames = terminalManager.paneSessionNames
                let liveness = AppTeamDeliveryLiveness(
                    livePaneSession: { paneSessionNames.contains($0) },
                    processStartTimeMicroseconds: { ProcessIdentityReader.startTimeMicroseconds(ofPID: $0) }
                )
                do {
                    // ATTN-2.19: presence and inbox access are file I/O.
                    savedTask = try await OffMainIO.run {
                        try PaneAgentLaunch.saveInitialPrompt(
                            agentPrompt, runtime: agentRuntime, repo: repo, worktreePath: path,
                            branchName: branch, inbox: teamInbox,
                            presenceRecords: {
                                try TeamPresenceStorage(rootDirectory: TeamPresenceStorage.defaultRoot()).list(
                                    teamID: TeamLookup.id(forRepoPath: repo.path), worktree: path, runtime: agentRuntime
                                )
                            },
                            liveness: liveness
                        )
                    }
                } catch {
                    launch.discardPromptFile()
                    return .error("could not save initial agent task: \(error.localizedDescription)")
                }
                // The worktree can stop while the file I/O is suspended.
                if let error = splitTargetError() {
                    await abandonLaunch()
                    return .error(error)
                }
            }
        }
        // ATTN-1.25: hand the command to surface creation, which runs it
        // once the shell is ready; typing after the split could arrive first.
        guard let targetID = appState.wrappedValue.worktree(forPath: path)?.firstPane,
              let newPaneID = PaneCommands.splitPane(
                  appState: appState,
                  terminalManager: terminalManager,
                  targetID: targetID,
                  split: direction,
                  extraInitialInput: PaneAgentLaunch.initialInput(launch.command),
                  reservedSlot: managedAgent?.paneSlotID,
                  reservedSession: managedAgent?.paneSessionID
              ) else {
            await abandonLaunch()
            return .error("split failed")
        }
        if let managedAgent, let index = appState.wrappedValue.indices(forWorktreePath: path),
           let ai = appState.wrappedValue.repos[index.repo].worktrees[index.worktree].agents.firstIndex(where: { $0.id == managedAgent.id }) {
            appState.wrappedValue.repos[index.repo].worktrees[index.worktree].agents[ai].paneSlotID = newPaneID
            do { try GrafttyApp.persistAppStateSynchronously(appState.wrappedValue) }
            catch {
                PaneCommands.removeEndedPane(appState: appState, terminalManager: terminalManager, targetID: newPaneID, userInitiated: true)
                await abandonLaunch()
                return .error("Could not save agent session: \(error.localizedDescription)")
            }
        }
        // ATTN-1.28: destroying the pane removes a prompt file its loader never
        // ran and withdraws the durable task. Both are no-ops once the agent
        // has started and taken its task.
        if agentRuntime != nil {
            // Like `worktree add`, start the agent even if the worktree's
            // views never mount; otherwise it waits until someone opens it.
            terminalManager.handle(for: newPaneID)?.startForBackgroundLaunch()
            let staged = launch
            let task = savedTask
            terminalManager.trackStagedLaunch(for: newPaneID) {
                staged.discardPromptFile()
                if let task {
                    Task { _ = await OffMainIO.run { try? PaneAgentLaunch.withdrawInitialPrompt(task, inbox: teamInbox) } }
                }
            }
        }
        if managedAgent == nil, let agentRuntime, let index = appState.wrappedValue.indices(forWorktreePath: path) {
            appState.wrappedValue.repos[index.repo].worktrees[index.worktree]
                .expectLaunchPrompt(WorktreeAgentLaunchCommand.initialPrompt(agentPrompt), runtime: agentRuntime)
            // As in `createWorktree`: no window may be observing state.
            try? GrafttyApp.persistAppStateSynchronously(appState.wrappedValue)
        }
        return .ok
    }

    @MainActor
    private static func closePaneByIndex(
        path: String,
        index: Int,
        appState: Binding<AppState>,
        terminalManager: TerminalManager
    ) -> ResponseMessage {
        guard let wt = appState.wrappedValue.worktree(forPath: path) else {
            return .error("not tracked")
        }
        // Symmetric with `addPane`. A .closed worktree's splitTree is
        // empty; the "no pane with id N" error would technically be
        // correct but misleads about the root cause (ATTN-3.5).
        guard wt.state == .running else {
            return .error("worktree not running")
        }
        guard let targetID = wt.splitTree.leaf(atPaneID: index) else {
            return .error("no pane with id \(index) in this worktree")
        }
        PaneCommands.closePane(
            appState: appState,
            terminalManager: terminalManager,
            targetID: targetID,
            userInitiated: true
        )
        return .ok
    }

    /// The `.showPane` route's read-and-tail step, after the worktree and
    /// pane guards have resolved `sessionName`. Nonisolated so the route can
    /// run it off the main actor while the reader spawns `zmx history`.
    nonisolated static func showPaneResponse(
        sessionName: String, lines: Int,
        reader: ZmxHistoryReader
    ) -> ResponseMessage {
        do {
            let body = try reader.history(sessionName: sessionName)
            return .paneShow(ScrollbackTail.tail(body, lines: lines))
        } catch {
            return .error("zmx history failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    fileprivate static func handleSendPane(
        path: String,
        index: Int,
        text: String,
        pressEnter: Bool,
        appState: Binding<AppState>,
        terminalManager: TerminalManager
    ) async -> ResponseMessage {
        guard let wt = appState.wrappedValue.worktree(forPath: path) else {
            return .error("not tracked")
        }
        guard wt.state == .running else {
            return .error("worktree not running")
        }
        guard let terminalID = wt.splitTree.leaf(atPaneID: index) else {
            return .error("no pane with id \(index) in this worktree")
        }
        if let handle = terminalManager.handle(for: terminalID) {
            return handleSendPane_forTesting(
                text: text,
                pressEnter: pressEnter,
                sink: SurfaceHandlePaneInputSink(handle: handle)
            )
        }

        guard let sessionID = wt.paneSessions[terminalID] else {
            return .error("pane has no session")
        }
        guard let launcher = terminalManager.zmxLauncher else {
            return .error("pane has no surface and zmx is unavailable")
        }
        let sessionName = ZmxLauncher.sessionName(for: sessionID)
        guard terminalManager.autoSleep.coordinator.wakeForInput(session: sessionName) else {
            return .error("pane could not be resumed")
        }
        let writer = ZmxPaneInputSubprocessWriter(launcher: launcher)
        return await Task.detached(priority: .utility) {
            handleSendPaneWithoutSurface_forTesting(
                text: text,
                pressEnter: pressEnter,
                sessionName: sessionName,
                writer: writer
            )
        }.value
    }

    /// Test seam: lets the spec test exercise acknowledged delivery without
    /// driving a libghostty surface. Production callers
    /// go through `handleSendPane` which performs worktree/pane validation
    /// before constructing a `SurfaceHandlePaneInputSink`.
    @MainActor
    internal static func handleSendPane_forTesting(
        text: String,
        pressEnter: Bool,
        sink: PaneInputSink
    ) -> ResponseMessage {
        guard sink.send(text: text, pressEnter: pressEnter) else {
            return .error("pane input was not accepted")
        }
        return .ok
    }

    nonisolated internal static func handleSendPaneWithoutSurface_forTesting(
        text: String,
        pressEnter: Bool,
        sessionName: String,
        writer: ZmxPaneInputWriter
    ) -> ResponseMessage {
        do {
            try writer.send(
                sessionName: sessionName,
                text: text + (pressEnter ? "\r" : "")
            )
            return .ok
        } catch {
            return .error("zmx send failed: \(error.localizedDescription)")
        }
    }
}
