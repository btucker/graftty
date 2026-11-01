#if canImport(UIKit)
import SwiftUI
import GrafttyProtocol
import GrafttyCommandUI

struct MobileAgentConversationView: View {
    let host: Host
    let worktreePath: String
    let agent: AgentSessionInfo
    @Environment(\.remoteConnectionCoordinator) private var coordinator

    var body: some View {
        AgentConversationView(agent: agent) { action in
            guard let coordinator else {
                return .error(code: "unavailable", message: "The host connection is unavailable.", forceAllowed: false, shortStatus: nil)
            }
            return try await coordinator.sendWorktreeManagement(.agentConversation(worktreeID: worktreePath,
                agentID: agent.id, action: action), to: host)
        }
    }
}
#endif
