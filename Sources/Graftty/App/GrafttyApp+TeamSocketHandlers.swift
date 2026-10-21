import SwiftUI
import AppKit
import GrafttyCommandUI
import GrafttyHostAgent
import GrafttyKit
import GrafttyProtocol
import GrafttyRemoteClient

extension GrafttyApp {
    @MainActor
    static func handleTeamReply(
        _ message: NotificationMessage,
        appState: Binding<AppState>,
        router: RemoteTeamRouter,
        inbox: TeamInbox,
        dispatcher: TeamEventDispatcher
    ) async -> ResponseMessage {
        guard case .teamReply(let caller, let agent, let id, let text, let priority, let fallback) = message else {
            return .error("Expected a team reply")
        }
        let repos = appState.wrappedValue.repos
        let enabled = UserDefaults.standard.bool(forKey: SettingsKeys.agentTeamsEnabled)
        do {
            let request = try await OffMainIO.run {
                try TeamReplyResolver(inbox: inbox).resolve(
                    callerWorktree: caller, callerAgentID: agent, messageID: id,
                    fallback: fallback, text: text, priority: priority,
                    repos: repos, teamsEnabled: enabled
                )
            }
            if let response = await handleRemoteTeamSend(request, appState: appState, router: router) {
                return response
            }
            guard case .teamSend(_, _, let recipient, _, _) = request else {
                return .error("Invalid reply destination")
            }
            return await handleTeamSend(
                callerPath: caller, callerAgentID: agent, recipient: recipient,
                text: text, priority: priority, appState: appState,
                teamInbox: inbox, teamEventDispatcher: dispatcher
            )
        } catch {
            return .error(String(describing: error))
        }
    }

    @MainActor
    static func handleRemoteTeamSend(
        _ message: NotificationMessage,
        appState: Binding<AppState>,
        router: RemoteTeamRouter
    ) async -> ResponseMessage? {
        let caller: String
        let agentID: String?
        let recipient: String
        let text: String
        let priority: TeamInboxPriority
        switch message {
        case .teamSend(let path, let agent, let address, let body, let urgency):
            (caller, agentID, recipient, text, priority) = (path, agent, address, body, urgency)
        case .teamMessage(let path, let address, let body):
            (caller, agentID, recipient, text, priority) = (path, nil, address, body, .normal)
        default: return nil
        }
        guard recipient.hasPrefix("graftty-mac:") else { return nil }
        guard UserDefaults.standard.bool(forKey: SettingsKeys.agentTeamsEnabled) else {
            return .error(TeamInboxRequestError.teamModeDisabled.description)
        }
        guard appState.wrappedValue.worktree(forPath: caller) != nil else {
            return .error(TeamInboxRequestError.callerNotTracked.description)
        }
        return await router.send(callerWorktree: caller, callerAgentID: agentID, recipient: recipient, text: text, priority: priority)
    }

    @MainActor
    static func handleTeamSend(
        callerPath: String,
        callerAgentID: String?,
        recipient: String,
        text: String,
        priority: TeamInboxPriority,
        appState: Binding<AppState>,
        teamInbox: TeamInbox,
        teamEventDispatcher: TeamEventDispatcher
    ) async -> ResponseMessage {
        do {
            let handler = teamInboxRequestHandler(inbox: teamInbox, dispatcher: teamEventDispatcher)
            let repos = appState.wrappedValue.repos
            let teamsEnabled = UserDefaults.standard.bool(forKey: SettingsKeys.agentTeamsEnabled)
            // ATTN-2.19: the append happens off the main actor so inbox
            // file contention cannot wedge the control socket.
            _ = try await OffMainIO.run {
                try handler.send(
                    callerWorktree: callerPath,
                    callerAgentID: callerAgentID,
                    recipient: recipient,
                    text: text,
                    priority: priority,
                    repos: repos,
                    teamsEnabled: teamsEnabled
                )
            }
            return .ok
        } catch let error as TeamInboxRequestError {
            return .error(error.description)
        } catch {
            return .error("failed to write team inbox message: \(error)")
        }
    }

    @MainActor
    static func handleTeamBroadcast(
        callerPath: String,
        callerAgentID: String?,
        text: String,
        priority: TeamInboxPriority,
        appState: Binding<AppState>,
        teamInbox: TeamInbox,
        teamEventDispatcher: TeamEventDispatcher
    ) async -> ResponseMessage {
        do {
            let handler = teamInboxRequestHandler(inbox: teamInbox, dispatcher: teamEventDispatcher)
            let repos = appState.wrappedValue.repos
            let teamsEnabled = UserDefaults.standard.bool(forKey: SettingsKeys.agentTeamsEnabled)
            // ATTN-2.19: see handleTeamSend.
            _ = try await OffMainIO.run {
                try handler.broadcast(
                    callerWorktree: callerPath,
                    callerAgentID: callerAgentID,
                    text: text,
                    priority: priority,
                    repos: repos,
                    teamsEnabled: teamsEnabled
                )
            }
            return .ok
        } catch let error as TeamInboxRequestError {
            return .error(error.description)
        } catch {
            return .error("failed to write team inbox broadcast: \(error)")
        }
    }

    /// Hooks that exist only to carry attention signals. Codex PostToolUse
    /// belongs here too: Codex has no PostToolUse context channel, so the
    /// team handler would only ever render `{}` for it after scanning
    /// presence on every tool call.
    nonisolated static func isAttentionOnlyTeamHook(
        runtime: TeamHookRuntime,
        event: TeamHookEvent
    ) -> Bool {
        switch event {
        case .preToolUse, .permissionRequest, .userPromptSubmit, .postToolUseFailure:
            return true
        case .postToolUse:
            return runtime == .codex
        case .sessionStart, .stop:
            return false
        }
    }

    @MainActor
    static func handleTeamHook(
        callerPath: String,
        callerAgentID: String?,
        runtime: TeamHookRuntime,
        event: TeamHookEvent,
        sessionID: String?,
        paneSessionName: String?,
        attentionReason: AgentHookAttentionReason?,
        stopHookActive: Bool,
        appState: Binding<AppState>,
        teamInbox: TeamInbox,
        teamEventDispatcher: TeamEventDispatcher,
        terminalManager: TerminalManager,
        remoteBranchStore: RemoteBranchStore,
        agentRegistry: ClaudeSessionRegistry
    ) async -> ResponseMessage {
        if let paneSessionName,
           appState.wrappedValue.worktree(forPath: callerPath)?.paneSlot(forSessionName: paneSessionName) != nil {
            agentRegistry.recordHook(runtime: runtime, event: event, sessionID: sessionID ?? callerAgentID,
                                     paneSessionName: paneSessionName, attentionReason: attentionReason)
        }
        switch AgentHookAttentionTransition.action(event: event, reason: attentionReason) {
        case .recordStoppedTurn:
            let outcome = AttentionRecapCoordinator.shared.stop(
                worktree: callerPath,
                agentID: callerAgentID,
                stopHookActive: stopHookActive
            )
            if outcome == .requestRecap {
                return .teamHookOutput(TeamHookRenderer.requestRecap())
            }
            guard case .record(let recap) = outcome else { return .teamHookOutput("{}") }
            recordStoppedTurn(
                callerPath: callerPath, runtime: runtime,
                callerAgentID: callerAgentID, sessionID: sessionID,
                paneSessionName: paneSessionName, recap: recap,
                stoppedAt: Date(), appState: appState,
                terminalManager: terminalManager
            )
        case .record(let reason):
            recordAgentAttention(
                callerPath: callerPath,
                callerAgentID: callerAgentID,
                runtime: runtime,
                reason: reason,
                sessionID: sessionID,
                paneSessionName: paneSessionName,
                appState: appState
            )
        case .clear:
            clearAgentAttention(
                callerPath: callerPath,
                callerAgentID: callerAgentID,
                runtime: runtime,
                sessionID: sessionID,
                appState: appState
            )
        case .none:
            break
        }

        // Attention-only hooks must return quickly and must not depend on the
        // team feature being enabled. They carry no inbox or instruction data.
        if isAttentionOnlyTeamHook(runtime: runtime, event: event) {
            return .teamHookOutput("{}")
        }

        do {
            let teamsEnabled = UserDefaults.standard.bool(forKey: SettingsKeys.agentTeamsEnabled)
            if event == .sessionStart, !teamsEnabled {
                return .teamHookOutput(try TeamHookRenderer.sessionStart(runtime: runtime))
            }
            // Snapshotted before the instruction render's `await`; the
            // ownership decision below therefore reads presence as it stood
            // at hook entry, not as it stands when the decision runs. That
            // was already true of any await on this path — the render only
            // widens the window — and a stale snapshot at worst hands
            // delivery to a pane that has just gone away.
            // ATTN-2.19: the presence read is file I/O, so it runs off the
            // main actor like the inbox work below.
            let presenceRecords = await OffMainIO.run {
                (try? TeamPresenceStorage(
                    rootDirectory: TeamPresenceStorage.defaultRoot()
                ).listAll()) ?? []
            }
            let repos = appState.wrappedValue.repos
            // The wrapper-launched CLI knows its own canonical identity
            // (GRAFTTY_AGENT_ID / pane presence), so a caller-supplied agent
            // ID wins; the session-based resolver covers older CLIs, and the
            // handler's hash fallback remains behind both.
            let currentAgentID = callerAgentID
                ?? TeamLookup.team(for: callerPath, in: repos).flatMap { team in
                    TeamAgentSessionIdentityResolver.agentID(
                        records: presenceRecords,
                        teamID: TeamLookup.id(of: team),
                        worktree: callerPath,
                        runtime: runtime,
                        sessionID: sessionID,
                        paneSessionName: paneSessionName
                    )
                }
            let liveSessionNames = Self.livePaneSessionNamesForAutomaticDelivery(
                records: presenceRecords,
                terminalManager: terminalManager
            )
            let instructions: String
            if event == .sessionStart,
               teamsEnabled,
               let team = TeamLookup.team(
                   for: callerPath,
                   in: appState.wrappedValue.repos
               ),
               let viewer = team.members.first(where: { $0.worktreePath == callerPath }) {
                instructions = await InstructionSessionText.render(
                    team: team,
                    viewer: viewer,
                    defaultBranch: remoteBranchStore.resolvedDefaultBranch(
                        forRepoAt: team.repoPath,
                        hint: appState.wrappedValue
                            .repo(forWorktreePath: callerPath)?.defaultBranchHint
                    )
                )
            } else {
                instructions = ""
            }
            let hookDeliveryLiveness = AppTeamDeliveryLiveness(
                livePaneSession: { liveSessionNames.contains($0) },
                processStartTimeMicroseconds: { ProcessIdentityReader.startTimeMicroseconds(ofPID: $0) }
            )
            let handler = teamInboxRequestHandler(
                inbox: teamInbox,
                dispatcher: teamEventDispatcher,
                automaticDeliveryOwner: { teamID, worktree, runtime, paneSessionName in
                    let resolver = TeamDeliveryOwnershipResolver(
                        records: { presenceRecords },
                        liveness: hookDeliveryLiveness
                    )
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
                    TeamAgentReachability.isReachableForNativeDelivery(
                        record,
                        liveness: hookDeliveryLiveness
                    )
                }
            )
            // ATTN-2.19: hook delivery parses the full inbox history and
            // can wait on the inter-process watermark lock; it fires on
            // every PostToolUse of every agent, so on the main actor it
            // wedged the control socket under agent activity.
            let output = try await OffMainIO.run {
                try handler.hook(
                    callerWorktree: callerPath,
                    runtime: runtime,
                    event: event,
                    sessionID: sessionID,
                    paneSessionName: paneSessionName,
                    repos: repos,
                    teamsEnabled: teamsEnabled,
                    instructions: instructions,
                    agentID: currentAgentID
                )
            }
            return .teamHookOutput(output)
        } catch let error as TeamInboxRequestError {
            // The CLI decides whether an unrendered SessionStart still gets
            // skill guidance (AGENT-6.49): only inside a Graftty terminal.
            return .error(error.description)
        } catch {
            return .error("failed to render team hook context: \(error)")
        }
    }

    @MainActor
    static func recordStoppedTurn(
        callerPath: String,
        runtime: TeamHookRuntime,
        callerAgentID: String?,
        sessionID: String?,
        paneSessionName: String?,
        recap: AttentionRecap?,
        stoppedAt: Date,
        appState: Binding<AppState>,
        terminalManager: TerminalManager,
        postNotification: (@MainActor (AgentStopNotificationContent) -> Void)? = nil
    ) {
        let paneSlot = paneSessionName
            .flatMap { appState.wrappedValue.worktree(forPath: callerPath)?.paneSlot(forSessionName: $0) }
        let paneTitle = paneSlot
            .map { terminalManager.displayTitle(for: $0) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let stop = SidebarAgentStop(
            agentName: AgentStopNotification.displayName(runtime),
            stoppedAt: stoppedAt,
            recap: recap,
            paneTitle: paneTitle,
            paneSlotID: paneSlot?.id.uuidString,
            providerSessionKey: AgentHookAttentionIdentity.key(
                runtime: runtime, sessionID: sessionID, callerAgentID: callerAgentID
            )
        )
        if let key = stop.providerSessionKey,
           let progressedAt = appState.wrappedValue.worktree(forPath: callerPath)?.agentProgressTimes[key],
           progressedAt > stop.timestamp { return }
        if let previous = appState.wrappedValue.worktree(forPath: callerPath)?.lastAgentStop {
            if previous.timestamp > stop.timestamp { return }
            if previous.timestamp == stop.timestamp, previous.providerSessionKey == stop.providerSessionKey,
               previous.recap == stop.recap { return }
        }
        SidebarHostNavigation.adoptReportedEmoji(recap, worktreePath: callerPath, in: &appState.wrappedValue.repos)
        for ri in appState.wrappedValue.repos.indices {
            if let wi = appState.wrappedValue.repos[ri].worktrees.firstIndex(where: { $0.path == callerPath }) {
                appState.wrappedValue.repos[ri].worktrees[wi].recordAgentStop(stop)
                let worktree = appState.wrappedValue.repos[ri].worktrees[wi]
                if let notification = AgentStopNotification.stoppedTurnContent(
                    runtime: runtime, worktreeName: WorktreeNameSanitizer.sanitize(worktree.branch),
                    worktreePath: callerPath, sessionID: sessionID ?? callerAgentID ?? "",
                    paneSessionName: paneSessionName, stop: stop,
                    emoji: worktree.effectiveEmoji(in: appState.wrappedValue.repos[ri]),
                    purposeTitle: worktree.brief?.title
                ) {
                    var notification = notification
                    ProjectNotificationIdentity.apply(to: &notification, worktree: worktree, repo: appState.wrappedValue.repos[ri])
                    if let postNotification { postNotification(notification) }
                    else {
                        AgentNotificationRouter.shared.post(notification, resolving: { notification in
                            await ProjectNotificationIdentity.resolved(notification, currentRepo: {
                                appState.wrappedValue.repo(forWorktreePath: callerPath)
                            })
                        })
                    }
                }
                break
            }
        }
    }

    @MainActor
    private static func recordAgentAttention(
        callerPath: String,
        callerAgentID: String?,
        runtime: TeamHookRuntime,
        reason: AgentHookAttentionReason,
        sessionID: String?,
        paneSessionName: String?,
        appState: Binding<AppState>
    ) {
        guard let providerSessionKey = AgentHookAttentionIdentity.key(
            runtime: runtime,
            sessionID: sessionID,
            callerAgentID: callerAgentID
        ) else {
            return
        }
        let timestamp = Date()
        for repoIndex in appState.wrappedValue.repos.indices {
            for worktreeIndex in appState.wrappedValue.repos[repoIndex].worktrees.indices
                where appState.wrappedValue.repos[repoIndex].worktrees[worktreeIndex].path == callerPath {
                let worktree = appState.wrappedValue.repos[repoIndex].worktrees[worktreeIndex]
                let worktreeName = WorktreeNameSanitizer.sanitize(worktree.branch)
                let resolvedSessionID = sessionID ?? "\(runtime.rawValue):\(worktreeName):\(callerPath)"
                let attentionText = AgentStopNotification.attentionText(
                    runtime: runtime,
                    reason: reason
                )
                let attention = Attention(
                    text: attentionText,
                    timestamp: timestamp,
                    source: .agentStop,
                    providerSessionKey: providerSessionKey
                )
                let pane: PaneSlotID?
                switch AgentStopAttentionTarget.resolve(worktree: worktree, paneSessionName: paneSessionName) {
                case .pane(let slot): pane = slot
                case .worktree: pane = nil
                }
                guard appState.wrappedValue.repos[repoIndex].worktrees[worktreeIndex]
                    .setAgentStopAttentionIfAbsent(attention, pane: pane) else {
                    return
                }
                var notification = AgentStopNotification.content(
                        runtime: runtime,
                        worktreeName: worktreeName,
                        worktreePath: callerPath,
                        sessionID: resolvedSessionID,
                        paneSessionName: paneSessionName,
                        reason: reason,
                        timestamp: timestamp
                    )
                ProjectNotificationIdentity.apply(to: &notification, worktree: worktree, repo: appState.wrappedValue.repos[repoIndex])
                AgentNotificationRouter.shared.post(notification, resolving: { notification in
                    await ProjectNotificationIdentity.resolved(notification, currentRepo: {
                        appState.wrappedValue.repo(forWorktreePath: callerPath)
                    })
                })
                return
            }
        }
    }

    @MainActor
    static func clearAgentAttention(
        callerPath: String,
        callerAgentID: String?,
        runtime: TeamHookRuntime,
        sessionID: String?,
        progressedAt: Date = Date(),
        appState: Binding<AppState>
    ) {
        let providerSessionKey = AgentHookAttentionIdentity.key(
            runtime: runtime,
            sessionID: sessionID,
            callerAgentID: callerAgentID
        )
        appState.wrappedValue.clearAgentStopAttention(
            worktreePath: callerPath,
            providerSessionKey: providerSessionKey,
            progressedAt: progressedAt
        )
    }

    /// AGENT-3.3: the pane to focus when an agent-stop notification is
    /// activated — the pane whose session produced it (resolved by the
    /// same `AgentStopAttentionTarget` rule the post path uses to place
    /// the attention capsule, so focus and capsule can't disagree),
    /// falling back to the worktree's first pane when it no longer
    /// resolves (e.g. the agent's pane was closed, or it was a
    /// worktree-scoped ping).
    static func agentStopFocusTarget(
        worktree: WorktreeEntry,
        paneSessionName: String?
    ) -> PaneSlotID? {
        switch AgentStopAttentionTarget.resolve(
            worktree: worktree, paneSessionName: paneSessionName) {
        case .pane(let slot): return slot
        case .worktree: return worktree.firstPane
        }
    }

    @MainActor
    static func handleTeamInbox(
        request: TeamInboxPageRequest,
        appState: Binding<AppState>,
        teamInbox: TeamInbox,
        teamEventDispatcher: TeamEventDispatcher
    ) async -> ResponseMessage {
        do {
            let handler = teamInboxRequestHandler(inbox: teamInbox, dispatcher: teamEventDispatcher)
            let repos = appState.wrappedValue.repos
            let teamsEnabled = UserDefaults.standard.bool(forKey: SettingsKeys.agentTeamsEnabled)
            // ATTN-2.19: the inbox page parses the full message history
            // off the main actor.
            let page = try await OffMainIO.run {
                try handler.diagnosticPage(
                    callerWorktree: request.callerWorktree,
                    callerAgentID: request.callerAgentID,
                    consuming: request.consuming,
                    worktree: request.worktree,
                    repo: request.repo,
                    member: request.member,
                    unread: request.unread,
                    all: request.all,
                    beforeID: request.beforeID,
                    afterID: request.afterID,
                    snapshotThroughID: request.snapshotThroughID,
                    forwardPagination: request.forwardPagination,
                    limit: request.limit,
                    repos: repos,
                    teamsEnabled: teamsEnabled
                )
            }
            return .teamInbox(
                messages: page.messages,
                nextBeforeID: page.nextBeforeID,
                nextAfterID: page.nextAfterID,
                snapshotThroughID: page.snapshotThroughID
            )
        } catch let error as TeamInboxRequestError {
            return .error(error.description)
        } catch {
            return .error("failed to read team inbox: \(error)")
        }
    }

    @MainActor
    static func handleTeamInboxAdvance(
        callerPath: String,
        callerAgentID: String?,
        throughID: String,
        appState: Binding<AppState>,
        teamInbox: TeamInbox,
        teamEventDispatcher: TeamEventDispatcher
    ) async -> ResponseMessage {
        do {
            let handler = teamInboxRequestHandler(
                inbox: teamInbox,
                dispatcher: teamEventDispatcher
            )
            let repos = appState.wrappedValue.repos
            let teamsEnabled = UserDefaults.standard.bool(
                forKey: SettingsKeys.agentTeamsEnabled
            )
            try await OffMainIO.run {
                try handler.advanceRead(
                    callerWorktree: callerPath,
                    callerAgentID: callerAgentID,
                    throughID: throughID,
                    repos: repos,
                    teamsEnabled: teamsEnabled
                )
            }
            return .ok
        } catch let error as TeamInboxRequestError {
            return .error(error.description)
        } catch let error as TeamInboxError {
            return .error(error.description)
        } catch {
            return .error("failed to advance team inbox: \(error)")
        }
    }

    @MainActor
    static func handleTeamMembers(
        callerPath: String?,
        worktree: String?,
        repo: String?,
        appState: Binding<AppState>,
        teamInbox: TeamInbox,
        teamEventDispatcher: TeamEventDispatcher
    ) -> ResponseMessage {
        do {
            let result = try teamInboxRequestHandler(inbox: teamInbox, dispatcher: teamEventDispatcher).members(
                callerWorktree: callerPath,
                worktree: worktree,
                repo: repo,
                repos: appState.wrappedValue.repos,
                teamsEnabled: UserDefaults.standard.bool(forKey: SettingsKeys.agentTeamsEnabled)
            )
            return .teamList(teamName: result.teamName, members: result.members)
        } catch let error as TeamInboxRequestError {
            return .error(error.description)
        } catch {
            return .error("failed to list team members: \(error)")
        }
    }

    private static func teamInboxRequestHandler(
        inbox: TeamInbox,
        dispatcher: TeamEventDispatcher,
        automaticDeliveryOwner: (@Sendable (
            _ teamID: String,
            _ worktree: String,
            _ runtime: TeamHookRuntime,
            _ paneSessionName: String?
        ) -> Bool)? = nil,
        agentReachability: @escaping @Sendable (TeamPresenceRecord) -> Bool = { record in
            TeamAgentReachability.isReachable(record)
        }
    ) -> TeamInboxRequestHandler {
        TeamInboxRequestHandler(
            inbox: inbox,
            dispatcher: dispatcher,
            automaticDeliveryOwner: automaticDeliveryOwner,
            agentRecords: {
                (try? TeamPresenceStorage(
                    rootDirectory: TeamPresenceStorage.defaultRoot()
                ).listAll()) ?? []
            },
            agentReachability: agentReachability
        )
    }
}
