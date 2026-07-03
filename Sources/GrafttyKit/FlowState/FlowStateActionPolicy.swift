import Foundation

public enum FlowActionRequirement: String, Codable, Sendable, Equatable {
    case autonomousAllowed
    case confirmationRequired
    case explicitOptInOnly
    case unsupported
}

public enum FlowStateActionPolicy {
    private static let mutationVerbs: Set<String> = [
        "run", "push", "merge", "rebase", "restart", "close", "delete"
    ]

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

        let normalized = body.lowercased()
        guard body.contains("[Flow State]"),
              normalized.contains("status"),
              normalized.contains("blocker"),
              normalized.contains("next action"),
              normalized.contains("need"),
              normalized.contains("human")
        else { return false }

        return !containsMutationVerb(normalized)
    }

    private static func containsMutationVerb(_ normalizedBody: String) -> Bool {
        let words = normalizedBody.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return words.contains { mutationVerbs.contains($0) }
    }
}
