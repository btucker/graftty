import Foundation
import GrafttyProtocol

/// Control messages for Git replication on an authenticated SSH connection.
/// The owning receiver must still authorize each delegation and ref operation.
/// This channel carries control requests; it does not itself transfer Git packs.
public struct AuthenticatedGitControl: Sendable {
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
