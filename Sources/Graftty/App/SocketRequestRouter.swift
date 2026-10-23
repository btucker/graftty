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
    let statsStore: WorktreeStatsStore
    let prStatusStore: PRStatusStore
    let worktreeCreations: CLIWorktreeCreationStore
    let worktreeRemovals: CLIWorktreeRemovalStore
    let remoteBranchStore: RemoteBranchStore
    let agentRegistry: ClaudeSessionRegistry
    let remoteMacsModel: RemoteMacsModel
    let remoteTeamRouter: RemoteTeamRouter
    let teamsEnabledProvider: () -> Bool

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
        remoteTeamRouter: RemoteTeamRouter,
        teamsEnabled: @escaping () -> Bool = { AppServices.teamsEnabled }
    ) {
        self.appState = appState
        self.terminalManager = terminalManager
        self.teamInbox = teamInbox
        self.teamEventDispatcher = teamEventDispatcher
        self.worktreeMonitor = worktreeMonitor
        self.statsStore = statsStore
        self.prStatusStore = prStatusStore
        self.worktreeCreations = worktreeCreations
        self.worktreeRemovals = worktreeRemovals
        self.remoteBranchStore = remoteBranchStore
        self.agentRegistry = agentRegistry
        self.remoteMacsModel = remoteMacsModel
        self.remoteTeamRouter = remoteTeamRouter
        self.teamsEnabledProvider = teamsEnabled
    }

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
    }

    /// Fire-and-forget path (`SocketServer.onMessage`).
    func handleMessage(_ message: NotificationMessage) {
        ControlRequestCore.handleMessage(message, platform: self)
    }

    /// Request/response path (`SocketServer.onAsyncRequest`). The shared
    /// core answers attention, recap, and team messages (routing
    /// `graftty-mac:` recipients through `remoteTeamRouter`) and hands the
    /// rest to `handlePaneRequest`; team lists then gain remote members.
    func handleRequest(_ message: NotificationMessage) async -> ResponseMessage? {
        let response = await ControlRequestCore.handleRequest(message, platform: self)
        return await remoteTeamRouter.includingRemoteMembers(in: response, for: message)
    }

    /// Mac-specific dispatch for requests the shared core does not own.
    func handlePaneRequest(_ message: NotificationMessage) async -> ResponseMessage? {
        await Self.handlePaneRequest(
            message,
            appState: appState,
            terminalManager: terminalManager,
            teamInbox: teamInbox,
            teamEventDispatcher: teamEventDispatcher,
            worktreeMonitor: worktreeMonitor,
            statsStore: statsStore,
            prStatusStore: prStatusStore,
            worktreeCreations: worktreeCreations,
            worktreeRemovals: worktreeRemovals,
            remoteMacsModel: remoteMacsModel,
            remoteTeamRouter: remoteTeamRouter
        )
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
        teamEventDispatcher: TeamEventDispatcher,
        worktreeMonitor: WorktreeMonitor,
        statsStore: WorktreeStatsStore,
        prStatusStore: PRStatusStore,
        worktreeCreations: CLIWorktreeCreationStore,
        worktreeRemovals: CLIWorktreeRemovalStore,
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
                    deviceID: AppServices.localRemoteDeviceID().value,
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
                                 agentRuntime: request.agentRuntime, agentPrompt: request.agentPrompt, teamInbox: teamInbox,
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
                do {
                    let body = try reader.history(sessionName: sessionName)
                    return .paneShow(ScrollbackTail.tail(body, lines: lines))
                } catch {
                    return .error("zmx history failed: \(error.localizedDescription)")
                }
            }.value
        case .sendPane(let path, let index, let text, let pressEnter):
            return await handleSendPane(
                path: path, index: index, text: text, pressEnter: pressEnter,
                appState: appState, terminalManager: terminalManager
            )
        case .agentPromptStagingCapability, .paneAgentCapability:
            return .ok
        case .worktreeBaseCapability:
            return .ok
        case .worktreeCreateIdempotencyCapability, .remoteWorktreeCapability:
            return .ok
        case .worktreeRemoveCapability, .worktreePinnedRemovalCapability, .worktreePinCapability:
            return .ok
        case .setWorktreePinned(let path, let isPinned):
            let response = WorktreePinRequestHandler.handle(
                worktreePath: path, isPinned: isPinned, state: &appState.wrappedValue
            )
            if response == .ok { GrafttyApp.persistAppState(appState.wrappedValue) }
            return response
        case .createWorktree(let request):
            return await beginCLIWorktreeCreation(
                callerPath: request.callerWorktree,
                worktreeName: request.worktreeName,
                branchName: request.branchName,
                existing: request.existing,
                base: request.base,
                command: request.command,
                agentRuntime: request.agentRuntime,
                agentPrompt: request.agentPrompt,
                operationID: request.operationID,
                appState: appState,
                terminalManager: terminalManager,
                teamInbox: teamInbox,
                teamEventDispatcher: teamEventDispatcher,
                worktreeMonitor: worktreeMonitor,
                statsStore: statsStore,
                worktreeCreations: worktreeCreations
            )
        case .worktreeCreateStatus(let operationID):
            guard let status = worktreeCreations.status(operationID: operationID) else {
                return .error("unknown or expired worktree creation operation")
            }
            return .worktreeCreate(status)
        case .removeWorktree(let worktreePath, let force, let pinned):
            return beginCLIWorktreeRemoval(
                worktreePath: worktreePath,
                force: force,
                pinned: pinned,
                appState: appState,
                terminalManager: terminalManager,
                statsStore: statsStore,
                prStatusStore: prStatusStore,
                teamEventDispatcher: teamEventDispatcher,
                worktreeRemovals: worktreeRemovals
            )
        case .worktreeRemoveStatus(let operationID):
            guard let status = worktreeRemovals.status(operationID: operationID) else {
                return .error("unknown or expired worktree removal operation")
            }
            return .worktreeRemove(status)
        default:
            // ControlRequestCore answers attention, recap, and team
            // messages before platform dispatch.
            return .error("This request is not handled by the Mac app")
        }
    }

    @MainActor
    private static func beginCLIWorktreeRemoval(
        worktreePath: String,
        force: Bool,
        pinned: Bool,
        appState: Binding<AppState>,
        terminalManager: TerminalManager,
        statsStore: WorktreeStatsStore,
        prStatusStore: PRStatusStore,
        teamEventDispatcher: TeamEventDispatcher,
        worktreeRemovals: CLIWorktreeRemovalStore
    ) -> ResponseMessage {
        CLIWorktreeRemovalRequestHandler.begin(
            worktreePath: worktreePath,
            force: force,
            pinned: pinned,
            appState: appState,
            worktreeRemovals: worktreeRemovals,
            wakeWorktree: { terminalManager.wakeWorktree($0) },
            deleteWorktree: { path, force in
                await DeleteWorktreeFlow.delete(
                    worktreePath: path,
                    force: force,
                    appState: appState,
                    terminalManager: terminalManager,
                    statsStore: statsStore,
                    prStatusStore: prStatusStore,
                    teamEventDispatcher: teamEventDispatcher
                )
            }
        )
    }

    @MainActor
    static func beginCLIWorktreeCreation(
        callerPath: String,
        worktreeName: String,
        branchName: String,
        existing: Bool,
        base: String?,
        command: String?,
        agentRuntime: TeamHookRuntime?,
        agentPrompt: String?,
        operationID: String?,
        creationOrigin: WorktreeHistory.Origin? = nil,
        appState: Binding<AppState>,
        terminalManager: TerminalManager,
        teamInbox: TeamInbox,
        teamEventDispatcher: TeamEventDispatcher,
        worktreeMonitor: WorktreeMonitor,
        statsStore: WorktreeStatsStore,
        worktreeCreations: CLIWorktreeCreationStore
    ) async -> ResponseMessage {
        let operationID = operationID ?? UUID().uuidString.lowercased()
        if let existing = worktreeCreations.status(operationID: operationID) {
            return .worktreeCreate(existing)
        }
        defer { worktreeCreations.discardBaseCapture(operationID: operationID) }
        if let error = CLIWorktreeCreationPolicy.validationError(
            agentRuntime: agentRuntime,
            teamsEnabled: AppServices.teamsEnabled
        ) {
            return .error(error)
        }
        guard let repo = appState.wrappedValue.repos.first(where: { repo in
            repo.worktrees.contains(where: { $0.path == callerPath })
        }) else {
            return .error("caller is not inside a tracked worktree")
        }

        if let error = WorktreeCreationInput.validationError(
            worktreeName: worktreeName, branchName: branchName, existing: existing, base: base
        ) {
            return .error(error)
        }
        let resolvedBase: String?
        do {
            resolvedBase = try await worktreeCreations.captureBase(
                base, at: callerPath, operationID: operationID
            )
        } catch {
            return .error("could not resolve worktree base: \(error)")
        }
        // Ref resolution suspends this handler. A retry may have completed
        // the same preparation and started the operation in the meantime.
        if let retained = worktreeCreations.status(operationID: operationID) {
            return .worktreeCreate(retained)
        }

        if agentPrompt != nil, agentRuntime == nil {
            return .error("an agent prompt requires an agent runtime")
        }
        if let error = CLIWorktreeCreationPolicy.obsoletePromptLoaderError(
            agentRuntime: agentRuntime,
            command: command,
            agentPrompt: agentPrompt
        ) {
            return .error(error)
        }
        let launch: PreparedWorktreeAgentLaunch
        if let agentRuntime,
           CLIWorktreeCreationPolicy.shouldStageAgentPrompt(
               agentRuntime: agentRuntime,
               command: command,
               agentPrompt: agentPrompt
           ) {
            do {
                launch = try WorktreeAgentLaunchCommand.prepare(
                    agent: agentRuntime,
                    prompt: agentPrompt,
                    exactCommand: nil
                )
            } catch {
                return .error("could not stage agent prompt: \(error.localizedDescription)")
            }
        } else {
            launch = PreparedWorktreeAgentLaunch(command: command, promptFile: nil)
        }

        let branch: BranchSelection = existing
            ? .useExisting(name: branchName, source: .local)
            : .createNew(name: branchName)
        let worktreePath: String
        switch AddWorktreeFlow.beginCreate(
            repoPath: repo.path,
            worktreeName: worktreeName,
            branch: branch,
            base: base,
            creationOrigin: creationOrigin ?? .init(date: Date(), source: .worktree, worktreePath: callerPath,
                worktreeName: repo.worktrees.first(where: { $0.path == callerPath }).map {
                    SidebarWorktreeLabel.text(for: $0, inRepoAtPath: repo.path,
                        siblingPaths: repo.worktrees.map(\.path), defaultBranch: repo.defaultBranchHint)
                }),
            appState: appState
        ) {
        case .success(let path):
            worktreePath = path
        case .failure(let error):
            launch.discardPromptFile()
            return .error(error.userMessage ?? "could not begin worktree creation")
        }

        if let runtime = agentRuntime, launch.promptFile != nil,
           let index = appState.wrappedValue.indices(forWorktreePath: worktreePath) {
            appState.wrappedValue.repos[index.repo].worktrees[index.worktree]
                .expectLaunchPrompt(WorktreeAgentLaunchCommand.initialPrompt(agentPrompt), runtime: runtime)
        }

        // Persist before starting Git, so both a failed launch and a later
        // manual launch can recover the task. Retries return above before
        // reaching this write, preventing duplicate inbox copies.
        if let agentRuntime {
            do {
                try WorktreeAgentLaunchCommand.saveInitialPrompt(
                    agentPrompt, runtime: agentRuntime, repo: repo,
                    worktreePath: worktreePath, branchName: branchName, inbox: teamInbox
                )
                // A background CLI request may have no window observing state.
                // Save the launch expectation before its first hook can arrive.
                try appState.wrappedValue.save(to: AppState.defaultDirectory)
            } catch {
                appState.wrappedValue.removeWorktree(atPath: worktreePath)
                launch.discardPromptFile()
                return .error("could not save initial agent task: \(error.localizedDescription)")
            }
        }
        let initialCommand = launch.command.flatMap { value in
            value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
        }
        let status = worktreeCreations.start(
            worktreePath: worktreePath,
            messageAddress: worktreePath,
            stagedPromptFile: launch.promptFile,
            operationID: operationID
        ) {
            let result = await AddWorktreeFlow.finishCreate(
                repoPath: repo.path,
                worktreePath: worktreePath,
                branch: branch,
                base: resolvedBase,
                appState: appState,
                worktreeMonitor: worktreeMonitor,
                statsStore: statsStore,
                terminalManager: terminalManager,
                teamEventDispatcher: teamEventDispatcher,
                initialCommand: initialCommand,
                terminalStartTiming: AddWorktreeFlow.terminalStartTiming(for: .cli)
            )
            switch result {
            case .success:
                return nil
            case .failure(let error):
                // A background request may have no view persisting removal of
                // a failed placeholder or cancellation of its launch marker.
                if let index = appState.wrappedValue.indices(forWorktreePath: worktreePath) {
                    appState.wrappedValue.repos[index.repo].worktrees[index.worktree].cancelExpectedLaunch()
                }
                GrafttyApp.persistAppState(appState.wrappedValue)
                let message: String
                if case .discoveryFailed(let detail) = error {
                    message = detail
                } else {
                    message = error.userMessage ?? "worktree creation failed"
                }
                return message
            }
        }
        return .worktreeCreate(status)
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
        teamInbox: TeamInbox,
        appState: Binding<AppState>,
        terminalManager: TerminalManager
    ) async -> ResponseMessage {
        if let error = CLIWorktreeCreationPolicy.paneAddError(
            agentRuntime: agentRuntime,
            command: command,
            agentPrompt: agentPrompt,
            teamsEnabled: AppServices.teamsEnabled
        ) {
            return .error(error)
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
                launch = try WorktreeAgentLaunchCommand.prepare(agent: agentRuntime, prompt: agentPrompt, exactCommand: nil)
            } catch {
                return .error("could not stage agent prompt: \(error.localizedDescription)")
            }
            if let repo = appState.wrappedValue.repo(forWorktreePath: path),
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
                  extraInitialInput: PaneAgentLaunch.initialInput(launch.command)
              ) else {
            await abandonLaunch()
            return .error("split failed")
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
        if let agentRuntime, let index = appState.wrappedValue.indices(forWorktreePath: path) {
            appState.wrappedValue.repos[index.repo].worktrees[index.worktree]
                .expectLaunchPrompt(WorktreeAgentLaunchCommand.initialPrompt(agentPrompt), runtime: agentRuntime)
            // As in `createWorktree`: no window may be observing state.
            try? appState.wrappedValue.save(to: AppState.defaultDirectory)
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

    /// Test seam: lets the spec test exercise the `.showPane` route's
    /// read+tail logic without constructing a full `AppState`. Skips
    /// worktree lookup / state checks and goes straight to the reader.
    @MainActor
    internal static func handleShowPane_forTesting(
        path: String, index: Int, lines: Int,
        reader: ZmxHistoryReader
    ) -> ResponseMessage {
        do {
            let body = try reader.history(sessionName: "graftty-stub")
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
