import Foundation

/// A control-socket feature the CLI checks before relying on it, so an older
/// running app refuses a newer CLI's request instead of half-applying it.
public enum ControlCapability: String, CaseIterable, Sendable {
    case agentPromptStaging = "agent_prompt_staging"
    case paneAgent = "pane_agent"
    case worktreeBase = "worktree_base"
    case worktreeCreateIdempotency = "worktree_create_idempotency"
    case remoteWorktree = "remote_worktree"
    case worktreeRemove = "worktree_remove"
    case worktreePinnedRemoval = "worktree_pinned_removal"
    case worktreePin = "worktree_pin"
    case projectAdd = "project_add"

    /// The capability an older single-capability probe asks about.
    init?(legacyProbe: NotificationMessage) {
        guard let capability = Self.allCases.first(where: { $0.legacyProbe == legacyProbe }) else { return nil }
        self = capability
    }

    /// The single-capability request apps before `capabilities` answer with
    /// `.ok`.
    public var legacyProbe: NotificationMessage {
        switch self {
        case .agentPromptStaging: .agentPromptStagingCapability
        case .paneAgent: .paneAgentCapability
        case .worktreeBase: .worktreeBaseCapability
        case .worktreeCreateIdempotency: .worktreeCreateIdempotencyCapability
        case .remoteWorktree: .remoteWorktreeCapability
        case .worktreeRemove: .worktreeRemoveCapability
        case .worktreePinnedRemoval: .worktreePinnedRemovalCapability
        case .projectAdd: .projectAddCapability
        case .worktreePin: .worktreePinCapability
        }
    }
}
