import Foundation
import GrafttyKit
import GrafttyProtocol

@MainActor
enum FlowStateSignalBuilder {
    static func build(
        appState: AppState,
        statsStore: WorktreeStatsStore? = nil,
        prStatusStore: PRStatusStore? = nil,
        claudeSessionRegistry: ClaudeSessionRegistry? = nil,
        agentStateRegistry: WorktreeAgentStateRegistry? = nil,
        inputActivityRegistry: PaneInputActivityRegistry? = nil,
        activityStore: FlowStateActivityStore? = nil
    ) -> FlowExternalSignals {
        var signals = FlowExternalSignals.empty

        for repo in appState.repos {
            for worktree in repo.worktrees {
                let identity = identity(repo: repo, worktree: worktree)

                if let git = gitSnapshot(for: worktree, statsStore: statsStore) {
                    signals.gitByWorktreeRef[identity.ref] = git
                    signals.gitByWorktreeKey[identity.key] = git
                }
                if let pr = prSnapshot(for: worktree, prStatusStore: prStatusStore) {
                    signals.prByWorktreeRef[identity.ref] = pr
                    signals.prByWorktreeKey[identity.key] = pr
                }
                if let presence = agentPresence(
                    for: worktree,
                    claudeSessionRegistry: claudeSessionRegistry,
                    agentStateRegistry: agentStateRegistry
                ) {
                    signals.agentPresenceByWorktreeRef[identity.ref] = presence
                    signals.agentPresenceByWorktreeKey[identity.key] = presence
                }
                if let activity = activitySnapshot(
                    for: worktree,
                    worktreeRef: identity.ref,
                    inputActivityRegistry: inputActivityRegistry,
                    activityStore: activityStore
                ) {
                    signals.activityByWorktreeRef[identity.ref] = activity
                    signals.activityByWorktreeKey[identity.key] = activity
                }
            }
        }

        return signals
    }

    private static func identity(repo: RepoEntry, worktree: WorktreeEntry) -> (ref: String, key: String) {
        (
            FlowWorktreeIdentity.ref(
                repoDisplayName: repo.displayName,
                repoPath: repo.path,
                worktreePath: worktree.path,
                branch: worktree.branch
            ),
            FlowWorktreeIdentity.key(repoPath: repo.path, worktreePath: worktree.path)
        )
    }

    private static func gitSnapshot(
        for worktree: WorktreeEntry,
        statsStore: WorktreeStatsStore?
    ) -> FlowGitSnapshot? {
        guard let stats = statsStore?.stats[worktree.path] else { return nil }
        let changedLines = stats.insertions + stats.deletions
        let dirtyCount = stats.hasUncommittedChanges ? max(1, changedLines) : changedLines
        return FlowGitSnapshot(dirtyCount: dirtyCount, ahead: stats.ahead, behind: stats.behind)
    }

    private static func prSnapshot(
        for worktree: WorktreeEntry,
        prStatusStore: PRStatusStore?
    ) -> FlowPRSnapshot? {
        guard let info = prStatusStore?.infos[worktree.path] else { return nil }
        return FlowPRSnapshot(
            number: info.number,
            state: info.state.rawValue,
            ciConclusion: info.checks.rawValue,
            mergeState: info.mergeable.rawValue,
            urgency: urgency(for: info)
        )
    }

    private static func urgency(for info: PRInfo) -> FlowUrgency? {
        if info.state.isTerminal { return .medium }
        if info.checks == .failure || info.mergeable == .conflicting { return .critical }
        if info.checks == .pending || info.mergeable == .unknown { return .medium }
        return .low
    }

    private static func agentPresence(
        for worktree: WorktreeEntry,
        claudeSessionRegistry: ClaudeSessionRegistry?,
        agentStateRegistry: WorktreeAgentStateRegistry?
    ) -> FlowAgentPresenceSnapshot? {
        let claudeLiveness = worktree.paneSessions.values.compactMap { sessionID -> AgentLiveness? in
            let sessionName = ZmxLauncher.sessionName(for: sessionID)
            return claudeSessionRegistry?.livenessBySession[sessionName]
        }
        if claudeLiveness.contains(.busy) {
            return FlowAgentPresenceSnapshot(runtime: "claude", present: true, busy: true, waiting: false)
        }
        if claudeLiveness.contains(.idle) {
            return FlowAgentPresenceSnapshot(runtime: "claude", present: true, busy: false, waiting: true)
        }

        guard let agentStateRegistry else {
            if hasAgentStopAttention(worktree) {
                return FlowAgentPresenceSnapshot(runtime: nil, present: true, busy: false, waiting: true)
            }
            return nil
        }
        let codex = agentStateRegistry.state(worktree: worktree.path, runtime: "codex")
        let claude = agentStateRegistry.state(worktree: worktree.path, runtime: "claude")
        let states = [("codex", codex), ("claude", claude)].filter { $0.1 != .unknown }
        guard let first = states.first else {
            if hasAgentStopAttention(worktree) {
                return FlowAgentPresenceSnapshot(runtime: nil, present: true, busy: false, waiting: true)
            }
            return nil
        }
        let busy = states.contains { $0.1 == .active }
        let waiting = states.contains { $0.1 == .idle || $0.1 == .user_engaged } || hasAgentStopAttention(worktree)
        return FlowAgentPresenceSnapshot(runtime: first.0, present: true, busy: busy, waiting: waiting)
    }

    private static func hasAgentStopAttention(_ worktree: WorktreeEntry) -> Bool {
        worktree.attention?.source == .agentStop || worktree.paneAttention.values.contains { $0.source == .agentStop }
    }

    private static func activitySnapshot(
        for worktree: WorktreeEntry,
        worktreeRef: String,
        inputActivityRegistry: PaneInputActivityRegistry?,
        activityStore: FlowStateActivityStore?
    ) -> FlowActivitySnapshot? {
        let lastInput = latestInput(in: worktree, inputActivityRegistry: inputActivityRegistry)
        let lastActivityMessage = latestFlowMessage(worktreeRef: worktreeRef, activityStore: activityStore)
        let lastCooldown = try? activityStore?.lastStatusRequestAt(worktreeRef: worktreeRef)
        let lastFlow = [lastActivityMessage, lastCooldown].compactMap { $0 }.max()
        guard lastInput != nil || lastFlow != nil else { return nil }
        return FlowActivitySnapshot(lastUserActivityAt: lastInput, lastAgentActivityAt: nil, lastFlowMessageAt: lastFlow)
    }

    private static func latestInput(
        in worktree: WorktreeEntry,
        inputActivityRegistry: PaneInputActivityRegistry?
    ) -> Date? {
        guard let inputActivityRegistry else { return nil }
        return worktree.paneSessions.keys.compactMap { slot in
            inputActivityRegistry.lastInputAt(paneID: slot.id)
        }.max()
    }

    private static func latestFlowMessage(
        worktreeRef: String,
        activityStore: FlowStateActivityStore?
    ) -> Date? {
        guard let rows = try? activityStore?.recent(limit: 200) else { return nil }
        return rows.lazy
            .filter { $0.worktreeRef == worktreeRef && $0.kind.contributesToLastFlowMessage }
            .map(\.createdAt)
            .max()
    }
}

private extension FlowStateActivity.Kind {
    var contributesToLastFlowMessage: Bool {
        switch self {
        case .statusRequestSent, .actionExecuted:
            return true
        case .publishError, .publishAccepted, .statusRequestSkipped, .actionRequiresConfirmation, .actionSkipped:
            return false
        }
    }
}

@MainActor
enum FlowStateAppRequestDispatcher {
    static func handle(
        _ message: NotificationMessage,
        appState: AppState,
        store: FlowStateStore,
        activityStore: FlowStateActivityStore,
        teamInbox: TeamInbox? = nil,
        teamEventDispatcher: TeamEventDispatcher? = nil,
        teamsEnabled: Bool = UserDefaults.standard.bool(forKey: SettingsKeys.agentTeamsEnabled),
        statsStore: WorktreeStatsStore? = nil,
        prStatusStore: PRStatusStore? = nil,
        claudeSessionRegistry: ClaudeSessionRegistry? = nil,
        agentStateRegistry: WorktreeAgentStateRegistry? = nil,
        inputActivityRegistry: PaneInputActivityRegistry? = nil,
        statusProvider: (() -> FlowStatus)? = nil,
        now: @escaping () -> Date = Date.init
    ) -> ResponseMessage? {
        if case .flowRequestStatus(let worktreeRef, let explicit) = message {
            guard let teamInbox, let teamEventDispatcher else {
                return .error("flow state team messenger unavailable")
            }
            let executor = FlowStateActionExecutor(
                activityStore: activityStore,
                teamMessenger: FlowStateTeamMessenger(
                    appState: appState,
                    teamInbox: teamInbox,
                    teamEventDispatcher: teamEventDispatcher,
                    teamsEnabled: teamsEnabled
                ),
                permissionMode: permissionMode(),
                now: now
            )
            do {
                try executor.requestStatus(worktreeRef: worktreeRef, explicit: explicit)
                return .ok
            } catch {
                return .error("failed to request flow status: \(error)")
            }
        }

        let signals = FlowStateSignalBuilder.build(
            appState: appState,
            statsStore: statsStore,
            prStatusStore: prStatusStore,
            claudeSessionRegistry: claudeSessionRegistry,
            agentStateRegistry: agentStateRegistry,
            inputActivityRegistry: inputActivityRegistry,
            activityStore: activityStore
        )
        let handler = FlowStateRequestHandler(
            store: store,
            activityStore: activityStore,
            appState: appState,
            signals: signals,
            status: statusProvider?() ?? FlowStatus(enabled: false, running: false, message: nil),
            now: now
        )
        do {
            let response = try handler.handle(message)
            if response == .ok, case .flowPublish = message,
               let recommendation = try store.recommendation(),
               let teamInbox,
               let teamEventDispatcher {
                let executor = FlowStateActionExecutor(
                    activityStore: activityStore,
                    teamMessenger: FlowStateTeamMessenger(
                        appState: appState,
                        teamInbox: teamInbox,
                        teamEventDispatcher: teamEventDispatcher,
                        teamsEnabled: teamsEnabled
                    ),
                    permissionMode: permissionMode(),
                    now: now
                )
                try executor.executeAutonomousActions(recommendation.proposedActions)
            }
            return response
        } catch {
            return .error("failed to handle flow request: \(error)")
        }
    }

    private static func permissionMode() -> FlowStatePermissionMode {
        let raw = UserDefaults.standard.string(forKey: SettingsKeys.flowStatePermissionMode) ?? ""
        return FlowStatePermissionMode(rawValue: raw) ?? .conservative
    }
}

private final class FlowStateTeamMessenger: FlowTeamMessaging {
    private let appState: AppState
    private let teamInbox: TeamInbox
    private let teamEventDispatcher: TeamEventDispatcher
    private let teamsEnabled: Bool

    init(
        appState: AppState,
        teamInbox: TeamInbox,
        teamEventDispatcher: TeamEventDispatcher,
        teamsEnabled: Bool
    ) {
        self.appState = appState
        self.teamInbox = teamInbox
        self.teamEventDispatcher = teamEventDispatcher
        self.teamsEnabled = teamsEnabled
    }

    func sendStatusRequest(target: String, body: String) throws {
        guard teamsEnabled else {
            throw FlowTeamMessagingError.skipped("Flow State status request skipped: teams are disabled")
        }
        guard let resolved = resolveTarget(target) else {
            throw FlowTeamMessagingError.skipped("Flow State status request skipped: unresolved worktree \(target)")
        }
        guard let team = TeamView.team(for: resolved, in: appState.repos, teamsEnabled: true) else {
            throw FlowTeamMessagingError.skipped("Flow State status request skipped: target has no team")
        }
        guard let recipient = team.members.first(where: { $0.worktreePath == resolved.path }) else {
            throw FlowTeamMessagingError.skipped("Flow State status request skipped: target is not a team member")
        }
        let caller = team.lead

        let handler = TeamInboxRequestHandler(inbox: teamInbox, dispatcher: teamEventDispatcher)
        _ = try handler.send(
            callerWorktree: caller.worktreePath,
            recipient: recipient.name,
            text: body,
            priority: .normal,
            repos: appState.repos,
            teamsEnabled: true
        )
    }

    func sendMessage(target: String, body: String) throws {
        throw FlowTeamMessagingError.skipped("Flow State team messages require confirmation in the app UI")
    }

    private func resolveTarget(_ target: String) -> WorktreeEntry? {
        for repo in appState.repos {
            for worktree in repo.worktrees {
                let key = FlowWorktreeIdentity.key(repoPath: repo.path, worktreePath: worktree.path)
                let ref = FlowWorktreeIdentity.ref(
                    repoDisplayName: repo.displayName,
                    repoPath: repo.path,
                    worktreePath: worktree.path,
                    branch: worktree.branch
                )
                let memberName = WorktreeNameSanitizer.sanitize(worktree.branch)
                let displayRef = "\(repo.displayName):\(memberName)"
                if [ref, key, displayRef, memberName, worktree.path].contains(target) {
                    return worktree
                }
            }
        }
        return nil
    }
}
