import Foundation

public enum FlowActionRequirement: String, Codable, Sendable, Equatable {
    case autonomousAllowed
    case confirmationRequired
    case explicitOptInOnly
    case unsupported
}

public enum FlowStateActionPolicy {
    public static let statusRequestTemplate = "[Flow State] Please reply with status, blocker, next action, tests/PR state, and whether you need the human."

    public static func effectiveRequirement(for action: FlowProposedAction) -> FlowActionRequirement {
        switch action.kind {
        case .teamStatusRequest:
            return isAutonomousStatusRequest(action) ? .autonomousAllowed : .confirmationRequired
        case .teamMessage, .focusWorktree, .restartAgent:
            return .confirmationRequired
        case .paneCommand:
            return .explicitOptInOnly
        }
    }

    private static func isAutonomousStatusRequest(_ action: FlowProposedAction) -> Bool {
        guard let target = action.target?.trimmingCharacters(in: .whitespacesAndNewlines),
              !target.isEmpty,
              let body = action.body?.trimmingCharacters(in: .whitespacesAndNewlines),
              !body.isEmpty
        else { return false }

        return body == statusRequestTemplate
    }
}
