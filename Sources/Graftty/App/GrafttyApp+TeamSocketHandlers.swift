import SwiftUI
import AppKit
import GrafttyKit
import GrafttyProtocol

/// Mac entry points into the attention state shared with the headless host
/// (`ControlRequestCore` and `AppState+ControlAttention`) for callers
/// outside the control socket: the provider file handoff and tests.
extension GrafttyApp {
    /// Native reply bridges resolve replies outside the control socket.
    @MainActor
    static func handleTeamReply(
        _ reply: TeamReplyRequest,
        appState: Binding<AppState>,
        router: RemoteTeamRouter,
        inbox: TeamInbox,
        dispatcher: TeamEventDispatcher
    ) async -> ResponseMessage {
        await ControlRequestCore.teamReply(reply, platform: MacTeamPlatform(
            appState: appState, teamInbox: inbox, teamEventDispatcher: dispatcher, router: router
        ))
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
        guard let notification = appState.wrappedValue.recordStoppedTurn(
            callerPath: callerPath, runtime: runtime, callerAgentID: callerAgentID, sessionID: sessionID,
            paneSessionName: paneSessionName, recap: recap, stoppedAt: stoppedAt,
            paneTitle: { slot, _ in paneTitle(for: slot, terminalManager: terminalManager) }
        ) else { return }
        postAgentNotification(notification, worktreePath: callerPath, appState: appState, post: postNotification)
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
        appState.wrappedValue.clearAgentAttention(
            callerPath: callerPath, callerAgentID: callerAgentID, runtime: runtime,
            sessionID: sessionID, progressedAt: progressedAt
        )
    }

    @MainActor
    static func paneTitle(for slot: PaneSlotID, terminalManager: TerminalManager) -> String? {
        let title = terminalManager.displayTitle(for: slot)
        return title.isEmpty ? nil : title
    }

    /// Stamps the project identity onto an agent notification and posts it,
    /// or hands it to `post` when a caller captures notifications.
    @MainActor
    static func postAgentNotification(
        _ content: AgentStopNotificationContent,
        worktreePath: String,
        appState: Binding<AppState>,
        post: (@MainActor (AgentStopNotificationContent) -> Void)? = nil
    ) {
        guard let repo = appState.wrappedValue.repo(forWorktreePath: worktreePath),
              let worktree = repo.worktrees.first(where: { $0.path == worktreePath }) else { return }
        var notification = content
        ProjectNotificationIdentity.apply(to: &notification, worktree: worktree, repo: repo)
        if let post { return post(notification) }
        AgentNotificationRouter.shared.post(notification, resolving: { notification in
            await ProjectNotificationIdentity.resolved(notification, currentRepo: {
                appState.wrappedValue.repo(forWorktreePath: worktreePath)
            })
        })
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
}

/// Team messaging for callers that hold the app's collaborators directly
/// rather than through a `SocketRequestRouter`.
@MainActor
private final class MacTeamPlatform: ControlTeamPlatform {
    let appState: Binding<AppState>
    let teamInbox: TeamInbox
    let teamEventDispatcher: TeamEventDispatcher
    let router: RemoteTeamRouter

    init(appState: Binding<AppState>, teamInbox: TeamInbox, teamEventDispatcher: TeamEventDispatcher, router: RemoteTeamRouter) {
        self.appState = appState
        self.teamInbox = teamInbox
        self.teamEventDispatcher = teamEventDispatcher
        self.router = router
    }

    var state: AppState {
        get { appState.wrappedValue }
        set { appState.wrappedValue = newValue }
    }
    var teamPresence: TeamPresenceStorage { TeamPresenceStorage(rootDirectory: TeamPresenceStorage.defaultRoot()) }
    var remoteTeamRouting: (any ControlRemoteTeamRouting)? { router }
}
