import Foundation
import GrafttyProtocol

/// The headless host's side of `ControlRequestCore`. State persists after
/// each core mutation, and there is no notification center, so
/// stopped-turn notifications are dropped.
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

    var worktreeCreation: any CLIWorktreeCreationPlatform { HeadlessWorktreeLifecycle(runtime: runtime) }
    var worktreeRemoval: any CLIWorktreeRemovalPlatform { HeadlessWorktreeLifecycle(runtime: runtime) }

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

/// `graftty worktree add` / `remove` effects. Unlike the platform, which
/// the runtime owns, this retains the runtime until background Git work
/// finishes.
@MainActor
final class HeadlessWorktreeLifecycle: CLIWorktreeCreationPlatform, CLIWorktreeRemovalPlatform {
    let runtime: HeadlessHostRuntime

    init(runtime: HeadlessHostRuntime) { self.runtime = runtime }

    var state: AppState {
        get { runtime.state }
        set { runtime.state = newValue }
    }
    var teamInbox: TeamInbox { runtime.inbox }
    var worktreeCreations: CLIWorktreeCreationStore { runtime.worktreeCreations }
    var worktreeRemovals: CLIWorktreeRemovalStore { runtime.worktreeRemovals }
    var agentPromptDirectory: URL {
        runtime.configuration.stateDirectory.appendingPathComponent("agent-launch-prompts", isDirectory: true)
    }

    func stateDidChange() throws { try runtime.save() }
    func saveStateNow() throws { try runtime.save() }
    func creationDestinationError(worktreePath: String, repo: RepoEntry) -> String? {
        runtime.creationDestinationError(worktreePath: worktreePath, repo: repo)
    }
    func finishWorktreeCreation(_ plan: CLIWorktreeCreationPlan) async -> String? {
        do {
            _ = try await runtime.finishCreatingWorktree(plan)
            return nil
        } catch let error as GitWorktreeAdd.Error {
            return WorktreeCreationError(gitAddFailure: error).operationFailureMessage
        } catch {
            return String(describing: error)
        }
    }
    /// Headless panes never sleep.
    func wakeWorktree(_ path: String) -> Bool { true }
    /// The Mac's `DeleteWorktreeFlow` results, from the runtime's raw errors.
    func removeWorktree(_ path: String, force: Bool) async -> Result<WorktreeRemovalOutcome, WorktreeRemovalError> {
        do {
            return .success(try await runtime.removeWorktree(path, force: force, pruneVanished: true))
        } catch GitWorktreeRemove.Error.gitFailed(_, let stderr) {
            if force { return .failure(.gitFailedFinal(stderr.isEmpty ? "git worktree remove --force failed" : stderr)) }
            return .failure(.gitFailedForceable(stderr: stderr.isEmpty ? "git worktree remove failed" : stderr,
                                                shortStatus: await GitStatusCapture.shortStatus(at: path)))
        } catch {
            return .failure(.gitFailedFinal(String(describing: error)))
        }
    }
}
