import Foundation
import GrafttyProtocol

/// Shared callbacks for peer-scoped RPC over authenticated SSH. Each subsystem
/// independently enforces its permissions and current delegation or MCP grant.
public struct AuthenticatedPeerControl: Sendable {
    public typealias Handler = @Sendable (RemoteMacConnectionSummary.ID, Data) async -> Data
    public typealias OnConnect = @Sendable (RemoteMacConnectionSummary.ID, TeamRPCSession) async -> Void
    public typealias OnDisconnect = @Sendable (RemoteMacConnectionSummary.ID, UUID) async -> Void
    public let handler: Handler
    public let onConnect: OnConnect
    public let onDisconnect: OnDisconnect
    public init(handler: @escaping Handler, onConnect: @escaping OnConnect = { _, _ in },
                onDisconnect: @escaping OnDisconnect = { _, _ in }) {
        self.handler = handler; self.onConnect = onConnect; self.onDisconnect = onDisconnect
    }
}

public typealias AuthenticatedGitControl = AuthenticatedPeerControl
public typealias AuthenticatedMCPControl = AuthenticatedPeerControl
