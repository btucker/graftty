import Foundation
import GrafttyProtocol

/// The headless host's side of `ControlRequestCore`. Team mode is always
/// on, state persists after each core mutation, and there is no
/// notification center, so stopped-turn notifications are dropped.
@MainActor
final class HeadlessControlPlatform: ControlPlatform, ControlRemoteTeamRouting {
    unowned let runtime: HeadlessHostRuntime
    let teamEventDispatcher: TeamEventDispatcher

    init(runtime: HeadlessHostRuntime) {
        self.runtime = runtime
        teamEventDispatcher = TeamEventDispatcher(inbox: runtime.inbox, preferencesProvider: { TeamEventRoutingPreferences() },
                                                  templateProvider: { "" })
    }

    var state: AppState {
        get { runtime.state }
        set { runtime.state = newValue }
    }
    var teamsEnabled: Bool { true }
    var teamInbox: TeamInbox { runtime.inbox }
    var teamPresence: TeamPresenceStorage { runtime.presence }
    var attentionRecaps: AttentionRecapCoordinator { runtime.recaps }
    var remoteTeamRouting: (any ControlRemoteTeamRouting)? { runtime.remoteTeamSender == nil ? nil : self }
    var instructionsDirectory: URL { runtime.configuration.stateDirectory }

    func stateDidChange() throws { try runtime.save() }
    func providerActivity(path: String, paneSessionName: String?, sessionID: String?,
                          activity: ProviderSleepActivity, runtime: TeamHookRuntime) {}
    func recordHookLiveness(runtime provider: TeamHookRuntime, event: TeamHookEvent, sessionID: String?,
                            paneSessionName: String, attentionReason: AgentHookAttentionReason?) {
        runtime.agentLiveness.recordHook(runtime: provider, event: event, sessionID: sessionID,
                                         paneSessionName: paneSessionName, attentionReason: attentionReason)
    }
    func instructionsDefaultBranch(repoPath: String, hint: String?) -> String? {
        runtime.repositoryBranches[repoPath]?.defaultBranch ?? hint
    }
    func paneTitle(for slot: PaneSlotID, in worktree: WorktreeEntry) -> String? {
        worktree.paneTitleMetadata[slot]?.title
    }
    func postAgentNotification(_ content: AgentStopNotificationContent, worktreePath: String) {}
    func hookDeliveryPolicy(presence: [TeamPresenceRecord]) -> TeamHookDeliveryPolicy { TeamHookDeliveryPolicy() }
    /// This host cannot launch an agent in an added pane, and it has no
    /// paired-Mac transport for remote worktree creation.
    var controlCapabilities: Set<ControlCapability> {
        Set(ControlCapability.allCases).subtracting([.paneAgent, .remoteWorktree])
    }

    func handlePlatformRequest(_ message: NotificationMessage) async -> ResponseMessage? {
        await runtime.hostRequest(message)
    }

    func send(callerWorktree: String, callerAgentID: String?, recipient: String,
              text: String, priority: TeamInboxPriority) async -> ResponseMessage {
        guard let sender = runtime.remoteTeamSender else { return .error("remote team connection is unavailable") }
        return await sender(TeamSendRequest(callerWorktree: callerWorktree, callerAgentID: callerAgentID,
                                            recipient: recipient, text: text, priority: priority))
    }
}
