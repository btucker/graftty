import Foundation
import GrafttyProtocol

/// Host-specific effects behind `ControlRequestCore`. The Mac app and the
/// headless host each provide one; the core owns every state mutation and
/// control-socket response that both hosts share.
@MainActor
public protocol ControlPlatform: ControlTeamPlatform {
    var attentionRecaps: AttentionRecapCoordinator { get }
    var instructionsDirectory: URL { get }

    /// Called after the core mutates `state`. The Mac schedules a coalesced
    /// save here, since no window may be observing state; the headless host
    /// saves immediately.
    func stateDidChange() throws
    func providerActivity(path: String, paneSessionName: String?, sessionID: String?,
                          activity: ProviderSleepActivity, runtime: TeamHookRuntime)
    /// Provider hook busy/idle state for a pane tracked in the caller's worktree.
    func recordHookLiveness(runtime: TeamHookRuntime, event: TeamHookEvent, sessionID: String?,
                            paneSessionName: String, attentionReason: AgentHookAttentionReason?)
    func instructionsDefaultBranch(repoPath: String, hint: String?) -> String?
    func paneTitle(for slot: PaneSlotID, in worktree: WorktreeEntry) -> String?
    func postAgentNotification(_ content: AgentStopNotificationContent, worktreePath: String)
    /// Automatic-delivery ownership and reachability for one team hook,
    /// evaluated against the presence snapshot taken at hook entry.
    func hookDeliveryPolicy(presence: [TeamPresenceRecord]) -> TeamHookDeliveryPolicy
    /// What this host's dispatcher supports, answered by `capabilities`.
    var controlCapabilities: Set<ControlCapability> { get }
    /// `graftty worktree add` / `remove` effects. Each finishes in the
    /// background, so it must keep the host alive until it does.
    var worktreeCreation: any CLIWorktreeCreationPlatform { get }
    var worktreeRemoval: any CLIWorktreeRemovalPlatform { get }
    /// Requests the core does not own: panes, previews, pins, and
    /// host-specific setup.
    func handlePlatformRequest(_ message: NotificationMessage) async -> ResponseMessage?
}

/// What team send, reply, inbox, and member requests need. Callers outside
/// the control socket (native reply bridges) can provide just this.
@MainActor
public protocol ControlTeamPlatform: AnyObject {
    /// The host's live model. The core reads and writes it synchronously and
    /// never holds a mutation across a suspension, so concurrent requests
    /// that land during an `await` are preserved.
    var state: AppState { get set }
    var teamInbox: TeamInbox { get }
    var teamEventDispatcher: TeamEventDispatcher { get }
    var teamPresence: TeamPresenceStorage { get }
    /// Routes `graftty-mac:` recipients to a paired peer; nil when this host
    /// has no peer transport.
    var remoteTeamRouting: (any ControlRemoteTeamRouting)? { get }
}

@MainActor
public protocol ControlRemoteTeamRouting: AnyObject {
    func send(callerWorktree: String, callerAgentID: String?, recipient: String,
              text: String, priority: TeamInboxPriority) async -> ResponseMessage
}

public struct TeamHookDeliveryPolicy: Sendable {
    public typealias Owner = @Sendable (
        _ teamID: String, _ worktree: String, _ runtime: TeamHookRuntime, _ paneSessionName: String?
    ) -> Bool

    public var automaticDeliveryOwner: Owner?
    public var agentReachability: @Sendable (TeamPresenceRecord) -> Bool

    public init(automaticDeliveryOwner: Owner? = nil,
                agentReachability: @escaping @Sendable (TeamPresenceRecord) -> Bool = { TeamAgentReachability.isReachable($0) }) {
        self.automaticDeliveryOwner = automaticDeliveryOwner
        self.agentReachability = agentReachability
    }
}
