import Foundation
import GrafttyProtocol

/// Routes worker-local stdio bridges to the exact authenticated parent channel.
/// A parent connection is not MCP authority; the parent checks its policy for
/// every request. Losing a channel never replays a request onto a replacement.
public actor MCPWorkerBridge {
    private struct Connection { let identity: RemoteMacConnectionSummary.ID; let session: TeamRPCSession }
    private var connections: [UUID: Connection] = [:]
    private var sessions: [UUID: UUID] = [:]
    private let authorize: @Sendable (RemoteMacConnectionSummary.ID) -> Bool
    public init(authorize: @escaping @Sendable (RemoteMacConnectionSummary.ID) -> Bool = { _ in true }) {
        self.authorize = authorize
    }

    public func connected(_ identity: RemoteMacConnectionSummary.ID, session: TeamRPCSession) async {
        guard authorize(identity) else { await session.close(); return }
        // A second channel may be a reconnect. Close the old one and invalidate
        // its sessions rather than transferring in-flight mutations to it.
        for (id, old) in connections where old.identity == identity {
            connections[id] = nil
            await old.session.close()
        }
        connections[session.id] = Connection(identity: identity, session: session)
    }
    public func disconnected(_ sessionID: UUID) { connections[sessionID] = nil }

    public func handle(_ bridge: MCPBridgeRequest) async -> MCPProxyResponse {
        guard authorize(bridge.parent) else { return .error(.unauthorized) }
        let id: UUID
        let connection: Connection
        switch bridge.request {
        case .open(let sessionID, _):
            id = sessionID
            guard sessions[id] == nil else { return .error(.invalidRequest) }
            guard sessions.count < 1024 else { return .error(.overloaded) }
            guard let current = connections.values.first(where: { $0.identity == bridge.parent }) else { return .error(.unavailable) }
            connection = current
            sessions[id] = current.session.id
        case .send(let sessionID, _), .receive(let sessionID), .close(let sessionID):
            id = sessionID
            guard let channelID = sessions[id], let current = connections[channelID], current.identity == bridge.parent else {
                return .error(.outcomeUnknown)
            }
            connection = current
        }
        do {
            let data = try JSONEncoder().encode(bridge.request)
            guard data.count <= 2 * MCPProxyBroker.maximumMessageBytes else { return .error(.invalidRequest) }
            let result = try await connection.session.send(data)
            return try JSONDecoder().decode(MCPProxyResponse.self, from: result)
        } catch {
            // Close all sessions on this uncertain channel. Never silently send
            // the same mutation again, even if another parent channel exists.
            connections[connection.session.id] = nil
            await connection.session.close()
            return .error(.outcomeUnknown)
        }
    }
}
