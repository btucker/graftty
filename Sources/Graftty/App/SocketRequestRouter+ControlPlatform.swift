import Foundation
import GrafttyKit
import GrafttyProtocol

/// The Mac app's side of `ControlRequestCore`. State persists through the
/// app's observers, so `stateDidChange` has nothing to do.
extension SocketRequestRouter: ControlPlatform {
    var state: AppState {
        get { appState.wrappedValue }
        set { appState.wrappedValue = newValue }
    }

    var teamPresence: TeamPresenceStorage { TeamPresenceStorage(rootDirectory: TeamPresenceStorage.defaultRoot()) }
    var attentionRecaps: AttentionRecapCoordinator { .shared }
    var remoteTeamRouting: (any ControlRemoteTeamRouting)? { remoteTeamRouter }
    var instructionsDirectory: URL { InstructionStore.defaultApplicationSupportDirectory }

    func stateDidChange() { GrafttyApp.persistAppState(appState.wrappedValue) }

    func providerActivity(path: String, paneSessionName: String?, sessionID: String?,
                          activity: ProviderSleepActivity, runtime: TeamHookRuntime) {
        terminalManager.autoSleep.providerActivity(path: path, session: paneSessionName, sessionID: sessionID,
                                                   activity: activity, runtime: runtime)
    }

    func recordHookLiveness(runtime: TeamHookRuntime, event: TeamHookEvent, sessionID: String?,
                            paneSessionName: String, attentionReason: AgentHookAttentionReason?) {
        agentRegistry.recordHook(runtime: runtime, event: event, sessionID: sessionID,
                                 paneSessionName: paneSessionName, attentionReason: attentionReason)
    }

    func instructionsDefaultBranch(repoPath: String, hint: String?) -> String? {
        remoteBranchStore.resolvedDefaultBranch(forRepoAt: repoPath, hint: hint)
    }

    func paneTitle(for slot: PaneSlotID, in worktree: WorktreeEntry) -> String? {
        GrafttyApp.paneTitle(for: slot, terminalManager: terminalManager)
    }

    func postAgentNotification(_ content: AgentStopNotificationContent, worktreePath: String) {
        GrafttyApp.postAgentNotification(content, worktreePath: worktreePath, appState: appState)
    }

    func hookDeliveryPolicy(presence: [TeamPresenceRecord]) -> TeamHookDeliveryPolicy {
        let liveSessionNames = GrafttyApp.livePaneSessionNamesForAutomaticDelivery(
            records: presence, terminalManager: terminalManager
        )
        let liveness = AppTeamDeliveryLiveness(
            livePaneSession: { liveSessionNames.contains($0) },
            processStartTimeMicroseconds: { ProcessIdentityReader.startTimeMicroseconds(ofPID: $0) }
        )
        return TeamHookDeliveryPolicy(
            automaticDeliveryOwner: { teamID, worktree, runtime, paneSessionName in
                let resolver = TeamDeliveryOwnershipResolver(records: { presence }, liveness: liveness)
                let key = TeamDeliveryOwnerKey(teamID: teamID, worktree: worktree, runtime: runtime)
                guard let owner = resolver.owner(for: key) else {
                    // Preserve direct-shell / registration-failure fallback:
                    // only suppress a hook when another live pane is a
                    // positively identified owner.
                    return true
                }
                return owner.paneSessionName == paneSessionName
            },
            agentReachability: { record in
                // Same shared predicate as both native delivery services,
                // so the hook-side default-agent computation
                // (acceptsUntargeted) agrees with them about which agent
                // owns an untargeted head row.
                TeamAgentReachability.isReachableForNativeDelivery(record, liveness: liveness)
            }
        )
    }

    var controlCapabilities: Set<ControlCapability> { Set(ControlCapability.allCases) }

    /// All local destructive pane entry points share this interception, including remote controls.
    func installManagedPaneClose() {
        terminalManager.managedSessionMissing = { [weak self] slot in
            guard let self, let worktree = self.state.repos.flatMap(\.worktrees).first(where: {
                $0.agents.contains { $0.paneSlotID == slot && $0.status != .closed }
            }) else { return }
            try AgentControl.sessionEnded(path: worktree.path, slot: slot,
                reason: "Terminal process was absent after restart", platform: self)
        }
        terminalManager.managedPaneClose = { [weak self] slot, userInitiated in
            guard let self, let worktree = self.state.repos.flatMap(\.worktrees).first(where: {
                $0.agents.contains { $0.paneSlotID == slot && $0.status != .closed }
            }) else { return false }
            Task { @MainActor in
                do {
                    if userInitiated {
                        try await AgentControl.interruptSession(path: worktree.path, slot: slot, platform: self)
                    } else if try await !self.agentSessionIsAlive(worktree: worktree.path, slot: slot) {
                        try AgentControl.sessionEnded(path: worktree.path, slot: slot, reason: "Terminal process exited", platform: self)
                        PaneCommands.removeEndedPane(appState: self.appState, terminalManager: self.terminalManager,
                            targetID: slot, activateReplacement: false)
                        await AgentControl.reconcileOutbox(platform: self)
                    }
                    // A dead attachment with a live daemon is not a provider exit.
                } catch {
                    NSLog("[Graftty] Managed terminal close remains retryable: %@", error.localizedDescription)
                }
            }
            return true
        }
    }

    func agentSessionNames() async throws -> Set<String> {
        guard let launcher = terminalManager.zmxLauncher, launcher.isAvailable else { throw AgentControlError.unavailable }
        return try await OffMainIO.run { try launcher.listSessions() }
    }

    func agentSessionIsAlive(worktree path: String, slot: PaneSlotID) async throws -> Bool {
        guard let session = state.worktree(forPath: path)?.paneSessions[slot], let launcher = terminalManager.zmxLauncher else { return false }
        return try await OffMainIO.run { try launcher.listSessions().contains(ZmxLauncher.sessionName(for: session)) }
    }

    func closeAgentSession(worktree path: String, slot: PaneSlotID) async throws {
        guard let worktree = state.worktree(forPath: path),
              let session = worktree.paneSessions[slot] else { return }
        guard let launcher = terminalManager.zmxLauncher, launcher.isAvailable else {
            throw AgentControlError.unavailable
        }
        let name = ZmxLauncher.sessionName(for: session)
        let history = try await OffMainIO.run {
            guard try launcher.listSessions().contains(name) else { return nil as String? }
            return try ZmxHistorySubprocessReader(launcher: launcher).history(sessionName: name) as String?
        }
        if let history {
            try await AgentControl.archiveTranscript(history, path: path, slot: slot, session: session, platform: self)
        }
        try await OffMainIO.run {
            if try launcher.listSessions().contains(name) {
                let result = try ZmxRunner.captureAll(executable: launcher.executable, args: ["kill", "--force", name],
                    env: launcher.subprocessEnv(from: ProcessInfo.processInfo.environment), timeout: 2)
                guard try !launcher.listSessions().contains(name) else {
                    throw NSError(domain: "AgentCleanup", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Could not end agent session: \(result.stderr)"])
                }
            }
        }
        // A slot is immutable. Do not resolve a pane index after the subprocess await.
        PaneCommands.removeEndedPane(appState: appState, terminalManager: terminalManager, targetID: slot,
                                    userInitiated: true, activateReplacement: false)
        try GrafttyApp.persistAppStateSynchronously(state)
    }

    func handlePlatformRequest(_ message: NotificationMessage) async -> ResponseMessage? {
        await handlePaneRequest(message)
    }
}

extension RemoteTeamRouter: ControlRemoteTeamRouting {}
