#if canImport(UIKit)
import SwiftUI
import GrafttyCommandUI
import GrafttyProtocol

struct MobileNewAgentMenu: View {
    let host: Host
    let worktree: String
    let onSelect: (String) -> Void
    var menuContent: AnyView? = nil
    var label: AnyView? = nil
    @Environment(\.remoteConnectionCoordinator) private var coordinator

    var body: some View {
        NewAgentMenu(menuContent: menuContent, label: label) { provider, operationID in
            guard let coordinator else { throw AgentLaunchError("The host connection is unavailable.") }
            let response = try await coordinator.sendWorktreeManagement(.addAgent(worktreeID: worktree,
                provider: provider, operationID: operationID), to: host)
            try Task.checkCancellation()
            switch response {
            case .created(_, let session): onSelect(session)
            case .error(_, let message, _, _): throw AgentLaunchError(message)
            default: throw AgentLaunchError("The host returned an unexpected response.")
            }
        }
    }
}
#endif
