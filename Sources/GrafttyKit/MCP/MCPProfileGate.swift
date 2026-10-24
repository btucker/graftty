import Foundation
import GrafttyProtocol

/// A socket is an additional local restriction, never the source of parent
/// authority. The parent still checks current policy on every operation.
@MainActor public final class MCPProfileGate {
    private let configurations: [MCPBridgeConfiguration]
    private let send: @Sendable (MCPBridgeRequest) async -> MCPProxyResponse
    private var sessions: [UUID: RemoteMacConnectionSummary.ID] = [:]
    private var active: Set<UUID> = []
    private var opening: Set<UUID> = []
    private var stopped = false
    public init(configurations: [MCPBridgeConfiguration], send: @escaping @Sendable (MCPBridgeRequest) async -> MCPProxyResponse) {
        self.configurations = configurations; self.send = send
    }
    public func handle(_ message: NotificationMessage) async -> ResponseMessage {
        guard case .mcpBridge(let bridge) = message else { return .error("This socket only serves this profile's MCP grants") }
        guard !stopped else { return .mcpProxy(.error(.unavailable)) }
        switch bridge.request {
        case .open(let id, let scope):
            guard configurations.contains(where: { $0.parent == bridge.parent && $0.scope == scope }) else {
                return .mcpProxy(.error(.unauthorized))
            }
            guard sessions[id] == nil, sessions.count < 1024, active.count + opening.count < 32 else { return .mcpProxy(.error(.overloaded)) }
            // Reserve before suspending; the endpoint retains tombstones.
            sessions[id] = bridge.parent
            opening.insert(id)
        case .send(let id, _), .receive(let id), .close(let id):
            guard active.contains(id), sessions[id] == bridge.parent else { return .mcpProxy(.error(.unauthorized)) }
        }
        let response = await send(bridge)
        switch bridge.request {
        case .close(let id): active.remove(id)
        case .open(let id, _):
            opening.remove(id)
            if response == .opened && !stopped { active.insert(id) }
        default: break
        }
        // A placement can be deleted while opening an upstream process.
        if stopped {
            if response == .opened, case .open(let id, _) = bridge.request { _ = await send(.init(parent: bridge.parent, request: .close(sessionID: id))) }
            return .mcpProxy(.error(.unavailable))
        }
        return .mcpProxy(response)
    }
    public func stop() async {
        guard !stopped else { return }
        stopped = true
        let closing = sessions.filter { active.contains($0.key) }; sessions = [:]; active = []
        await withTaskGroup(of: Void.self) { group in
            for (id, parent) in closing {
                group.addTask { [send] in _ = await send(.init(parent: parent, request: .close(sessionID: id))) }
            }
        }
    }
}
