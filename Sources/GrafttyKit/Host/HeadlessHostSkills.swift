import Foundation
import GrafttyProtocol

public extension HeadlessHostRuntime {
    /// Called only by the authenticated SSH callback. Generic management and
    /// relayed requests must never supply an owner from their payload.
    func receiveSkills(_ request: RemoteSkillTransferRequest, owner: RemoteMacConnectionSummary.ID) async -> WorktreeManagementResponse {
        do {
            guard !isShuttingDown else { throw HostRuntimeError.busy("Host is shutting down") }
            if case .begin = request, placements.drain != nil { throw HostRuntimeError.busy("Host is draining") }
            let status = try await skillTransfers.handle(request, owner: owner, repositories: Set(state.repos.map(\.path)))
            return .agentSkills(status)
        } catch { return .error(code: "skills-failed", message: String(describing: error), forceAllowed: false, shortStatus: nil) }
    }
}
