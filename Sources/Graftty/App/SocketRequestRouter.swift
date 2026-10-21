import SwiftUI
import AppKit
import GrafttyCommandUI
import GrafttyHostAgent
import GrafttyKit
import GrafttyProtocol
import GrafttyRemoteClient

/// Routes control-socket traffic from the `graftty` CLI and other local
/// clients into app state. `SocketServer` delivers fire-and-forget messages
/// to `handleMessage(_:)` and request/response messages to
/// `handleRequest(_:)`, both on the main actor.
///
/// Collaborators are injected individually so tests can build a router
/// without `AppServices`, which touches the real application-support
/// directory.
@MainActor
final class SocketRequestRouter {
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
        self.statsStore = statsStore
        self.prStatusStore = prStatusStore
        self.worktreeCreations = worktreeCreations
        self.worktreeRemovals = worktreeRemovals
        self.remoteBranchStore = remoteBranchStore
        self.agentRegistry = agentRegistry
        self.remoteMacsModel = remoteMacsModel
        self.remoteTeamRouter = remoteTeamRouter
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
        Self.handleNotification(
            message,
            appState: appState,
            terminalManager: terminalManager
        )
    }

    /// Request/response path (`SocketServer.onAsyncRequest`). Remote
    /// worktree, client-reconnect, and team-reply messages are routed
    /// before pane dispatch; the rest go through `handlePaneRequest`.
    func handleRequest(_ message: NotificationMessage) async -> ResponseMessage? {
        let binding = appState
        if case .remoteWorktree(let target, let request) = message {
            return await remoteTeamRouter.worktree(target: target, request: request, repos: binding.wrappedValue.repos)
        }
        if case .reconnectRemoteClient(let target) = message {
            return await remoteTeamRouter.reconnectClient(target: target)
        }
        if case .teamReply = message {
            return await GrafttyApp.handleTeamReply(
                message, appState: binding, router: remoteTeamRouter,
                inbox: teamInbox, dispatcher: teamEventDispatcher
            )
        }
        if let response = await GrafttyApp.handleRemoteTeamSend(
            message, appState: binding, router: remoteTeamRouter
        ) { return response }
        let response = await Self.handlePaneRequest(
            message,
            appState: binding,
            terminalManager: terminalManager,
            teamInbox: teamInbox,
            teamEventDispatcher: teamEventDispatcher,
            worktreeMonitor: worktreeMonitor,
            statsStore: statsStore,
            prStatusStore: prStatusStore,
            worktreeCreations: worktreeCreations,
            worktreeRemovals: worktreeRemovals,
            remoteBranchStore: remoteBranchStore,
            agentRegistry: agentRegistry,
            remoteMacsModel: remoteMacsModel
        )
        return await remoteTeamRouter.includingRemoteMembers(in: response, for: message)
    }
}

extension SocketRequestRouter {
    @MainActor
    static func handleNotification(
        _ message: NotificationMessage,
        appState: Binding<AppState>,
        terminalManager: TerminalManager
    ) {
        switch message {
        case let .providerActivity(path, runtime, sessionID, paneSessionName, activity):
            terminalManager.autoSleep.providerActivity(path: path, session: paneSessionName, sessionID: sessionID, activity: activity, runtime: runtime)
        case .notify(let path, let text, let clearAfter, let paneSessionName):
            // Defense-in-depth behind the CLI's ATTN-1.7 guard: reject
            // empty / whitespace-only text silently so a raw socket
            // client (`nc -U`, custom script, web surface) can't write
            // an invisible red capsule Andy can't read or dismiss.
            guard Attention.isValidText(text) else { return }
            // Normalize the requested auto-clear duration against the
            // server's contract: ≤0 → nil (STATE-2.8), >24h → clamped
            // to 24h (STATE-2.9). A non-CLI socket client can still
            // send ridiculous values; `effectiveClearAfter` makes the
            // server a single source of truth for what actually
            // schedules.
            let effectiveClearAfter = Attention.effectiveClearAfter(clearAfter)
            // AGENT-4.1/4.2: when the message carries a pane session name,
            // resolve it to a pane slot within the targeted worktree and
            // write pane-scoped attention. Reuse `setAttentionForTerminal`
            // for the auto-clear path; for the no-clear case write the slot
            // directly. Falls through to worktree-scoped if it resolves no
            // live pane (e.g. the session ended).
            if let paneSessionName {
                for repoIdx in appState.wrappedValue.repos.indices {
                    for wtIdx in appState.wrappedValue.repos[repoIdx].worktrees.indices
                        where appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].path == path {
                        guard let slot = appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                            .paneSlot(forSessionName: paneSessionName) else { continue }
                        if let effectiveClearAfter {
                            GrafttyApp.setAttentionForTerminal(
                                appState: appState,
                                terminalID: slot,
                                text: text,
                                clearAfter: effectiveClearAfter,
                                source: .userNotify
                            )
                        } else {
                            appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                                .setAttention(
                                    Attention(text: text, timestamp: Date(), source: .userNotify),
                                    pane: slot
                                )
                        }
                        return
                    }
                }
            }
            // Pin the timestamp the attention carries AND the auto-clear
            // timer closes over, so the timer can verify it's still OUR
            // notification when it fires (cf. WorktreeEntry.clearAttentionIfTimestamp).
            let stamp = Date()
            for repoIdx in appState.wrappedValue.repos.indices {
                for wtIdx in appState.wrappedValue.repos[repoIdx].worktrees.indices {
                    if appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].path == path {
                        appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].setAttention(
                            Attention(
                                text: text,
                                timestamp: stamp,
                                clearAfter: effectiveClearAfter,
                                source: .userNotify
                            ),
                            pane: nil
                        )

                        if let effectiveClearAfter {
                            DispatchQueue.main.asyncAfter(deadline: .now() + effectiveClearAfter) {
                                for ri in appState.wrappedValue.repos.indices {
                                    for wi in appState.wrappedValue.repos[ri].worktrees.indices {
                                        if appState.wrappedValue.repos[ri].worktrees[wi].path == path {
                                            appState.wrappedValue.repos[ri].worktrees[wi].clearAttentionIfTimestamp(stamp)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        case .clear(let path, let paneSessionName):
            // AGENT-4.x: a pane-scoped clear targets just that pane's
            // attention slot; resolve the session name within the worktree
            // and fall through to worktree-scoped clear if unresolved.
            if let paneSessionName {
                for repoIdx in appState.wrappedValue.repos.indices {
                    for wtIdx in appState.wrappedValue.repos[repoIdx].worktrees.indices
                        where appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].path == path {
                        if let slot = appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                            .paneSlot(forSessionName: paneSessionName) {
                            appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                                .paneAttention[slot] = nil
                            return
                        }
                    }
                }
            }
            for repoIdx in appState.wrappedValue.repos.indices {
                for wtIdx in appState.wrappedValue.repos[repoIdx].worktrees.indices {
                    if appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].path == path {
                        appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].attention = nil
                    }
                }
            }
        case .previewFiles, .previewImage, .offerResource, .listPanes, .addPane, .closePane, .showPane, .sendPane, .teamMessage, .teamSend, .teamReply,
             .teamBroadcast, .teamHook, .teamInbox, .teamInboxAdvance, .teamMembers, .teamList,
             .createWorktree, .agentPromptStagingCapability, .worktreeBaseCapability,
             .worktreeCreateIdempotencyCapability, .remoteWorktreeCapability,
             .worktreeCreateStatus, .removeWorktree, .worktreeRemoveCapability, .worktreePinnedRemovalCapability,
             .worktreePinCapability, .setWorktreePinned,
             .worktreeRemoveStatus, .reconnectRemoteMac, .reconnectRemoteClient, .remoteWorktree,
             .attentionReport, .linuxSetupIdentity, .completeLinuxSetup:
            // Request-style messages are handled by handlePaneRequest via
            // the SocketServer.onRequest callback; they are no-ops on the
            // fire-and-forget onMessage path.
            break
        }
    }

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
        remoteBranchStore: RemoteBranchStore,
        agentRegistry: ClaudeSessionRegistry,
        remoteMacsModel: RemoteMacsModel
    ) async -> ResponseMessage? {
        switch message {
        case .offerResource(let path, _, let session), .previewImage(let path, _, let session), .previewFiles(let path, _, let session):
            guard let worktree = OpenResourceRouting.worktree(path: path, paneSessionName: session, state: appState.wrappedValue) else {
                return .error("The originating pane is unavailable. Run graftty open from a tracked worktree.")
            }
            guard terminalManager.wakeWorktree(worktree.path) else { return .error("Could not resume worktree processes. Retry before interacting with this worktree.") }
        case .addPane(let path, _, _), .closePane(let path, _),
             .showPane(let path, _, _), .sendPane(let path, _, _, _):
            guard terminalManager.wakeWorktree(path) else { return .error("Could not resume worktree processes. Retry before interacting with this worktree.") }
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
        case .remoteWorktree:
            return .error("Remote worktree routing is unavailable")
        case .reconnectRemoteClient:
            return .error("Client reconnect routing is unavailable")
        case .listPanes(let path):
            return listPanes(path: path, appState: appState, terminalManager: terminalManager)
        case .teamReply:
            // The socket dispatcher routes replies through the local and
            // remote team handlers before entering pane dispatch.
            return .error("Team reply routing is unavailable")
        case .addPane(let path, let direction, let command):
            return addPane(path: path, direction: direction, command: command,
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
        case .teamMessage(let callerPath, let recipient, let text):
            return await GrafttyApp.handleTeamSend(
                callerPath: callerPath,
                callerAgentID: nil,
                recipient: recipient,
                text: text,
                priority: .normal,
                appState: appState,
                teamInbox: teamInbox,
                teamEventDispatcher: teamEventDispatcher
            )
        case .teamSend(let callerPath, let callerAgentID, let recipient, let text, let priority):
            return await GrafttyApp.handleTeamSend(
                callerPath: callerPath,
                callerAgentID: callerAgentID,
                recipient: recipient,
                text: text,
                priority: priority,
                appState: appState,
                teamInbox: teamInbox,
                teamEventDispatcher: teamEventDispatcher
            )
        case .teamBroadcast(let callerPath, let callerAgentID, let text, let priority):
            return await GrafttyApp.handleTeamBroadcast(
                callerPath: callerPath,
                callerAgentID: callerAgentID,
                text: text,
                priority: priority,
                appState: appState,
                teamInbox: teamInbox,
                teamEventDispatcher: teamEventDispatcher
            )
        case .teamHook(
            let callerPath,
            let callerAgentID,
            let runtime,
            let event,
            let sessionID,
            let paneSessionName,
            let attentionReason,
            let stopHookActive,
            let providerSleepActivity
        ):
            terminalManager.autoSleep.providerActivity(path: callerPath, session: paneSessionName, sessionID: sessionID, activity: providerSleepActivity ?? .unknown, runtime: runtime)
            return await GrafttyApp.handleTeamHook(
                callerPath: callerPath,
                callerAgentID: callerAgentID,
                runtime: runtime,
                event: event,
                sessionID: sessionID,
                paneSessionName: paneSessionName,
                attentionReason: attentionReason,
                stopHookActive: stopHookActive,
                appState: appState,
                teamInbox: teamInbox,
                teamEventDispatcher: teamEventDispatcher,
                terminalManager: terminalManager,
                remoteBranchStore: remoteBranchStore,
                agentRegistry: agentRegistry
            )
        case .attentionReport(let callerPath, let callerAgentID, let recap):
            guard recap.isValid, appState.wrappedValue.worktree(forPath: callerPath) != nil else {
                return .error("invalid attention recap or unknown worktree")
            }
            AttentionRecapCoordinator.shared.report(recap, worktree: callerPath, agentID: callerAgentID)
            return .ok
        case .teamInbox(let request):
            return await GrafttyApp.handleTeamInbox(
                request: request,
                appState: appState,
                teamInbox: teamInbox,
                teamEventDispatcher: teamEventDispatcher
            )
        case .teamInboxAdvance(let callerPath, let callerAgentID, let throughID):
            return await GrafttyApp.handleTeamInboxAdvance(
                callerPath: callerPath,
                callerAgentID: callerAgentID,
                throughID: throughID,
                appState: appState,
                teamInbox: teamInbox,
                teamEventDispatcher: teamEventDispatcher
            )
        case .teamMembers(let callerPath, let worktree, let repo):
            return GrafttyApp.handleTeamMembers(
                callerPath: callerPath,
                worktree: worktree,
                repo: repo,
                appState: appState,
                teamInbox: teamInbox,
                teamEventDispatcher: teamEventDispatcher
            )
        case .teamList(let callerPath):
            return GrafttyApp.handleTeamMembers(
                callerPath: callerPath,
                worktree: nil,
                repo: nil,
                appState: appState,
                teamInbox: teamInbox,
                teamEventDispatcher: teamEventDispatcher
            )
        case .agentPromptStagingCapability:
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
        case .createWorktree(
            let callerPath,
            let worktreeName,
            let branchName,
            let existing,
            let base,
            let command,
            let agentRuntime,
            let agentPrompt,
            let operationID
        ):
            return await beginCLIWorktreeCreation(
                callerPath: callerPath,
                worktreeName: worktreeName,
                branchName: branchName,
                existing: existing,
                base: base,
                command: command,
                agentRuntime: agentRuntime,
                agentPrompt: agentPrompt,
                operationID: operationID,
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
        case .notify, .clear, .providerActivity:
            // Fire-and-forget cases — no response. `onMessage` already handled them.
            return nil
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
            teamsEnabled: UserDefaults.standard.bool(forKey: SettingsKeys.agentTeamsEnabled)
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
        appState: Binding<AppState>,
        terminalManager: TerminalManager
    ) -> ResponseMessage {
        guard let wt = appState.wrappedValue.worktree(forPath: path) else {
            return .error("not tracked")
        }
        guard wt.state == .running else {
            return .error("worktree not running")
        }
        guard let targetID = wt.firstPane else {
            return .error("no panes to split")
        }
        guard let newID = GrafttyApp.splitPane(
            appState: appState,
            terminalManager: terminalManager,
            targetID: targetID,
            split: direction
        ) else {
            return .error("split failed")
        }
        if let command, !command.isEmpty {
            // splitPane's `command` is automation, not a user keystroke
            // on the newly-created surface — keep IOS-12.1's silent
            // gate closed.
            terminalManager.handle(for: newID)?.typeText(command + "\r", claimEngagement: false)
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
        GrafttyApp.closePane(
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
