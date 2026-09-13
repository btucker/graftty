import Foundation
import GrafttyKit
import GrafttyProtocol

/// Routes only directly connected peers. Each peer answers from its local
/// roster, so paired Macs cannot recursively rediscover or relay each other.
@MainActor
final class RemoteTeamRouter {
    typealias Sender = @Sendable (Data) async throws -> Data
    typealias Handler = @MainActor @Sendable (RemoteDeviceID, Data) async -> Data

    private struct Route: Sendable {
        let id: UUID
        let label: String
        let order: UInt64
        let send: Sender
    }

    private var routes: [RemoteDeviceID: [UUID: Route]] = [:]
    private var sequence: UInt64 = 0
    var handler: Handler = { _, _ in
        (try? JSONEncoder().encode(RemoteTeamResponse.error("Team messaging is not ready"))) ?? Data()
    }

    func register(deviceID: RemoteDeviceID, connectionID: UUID, label: String, send: @escaping Sender) {
        sequence &+= 1
        routes[deviceID, default: [:]][connectionID] = Route(id: connectionID, label: label, order: sequence, send: send)
    }

    func unregister(deviceID: RemoteDeviceID, connectionID: UUID) {
        routes[deviceID]?[connectionID] = nil
        if routes[deviceID]?.isEmpty == true { routes[deviceID] = nil }
    }

    func receive(from deviceID: RemoteDeviceID, data: Data) async -> Data {
        await handler(deviceID, data)
    }

    func send(callerWorktree: String, callerAgentID: String?, recipient: String, text: String, priority: TeamInboxPriority) async -> ResponseMessage {
        guard let address = RemoteTeamAddress(rawValue: recipient) else {
            return .error("Invalid remote team address")
        }
        guard let route = preferredRoute(for: address.deviceID) else {
            return .error("Remote Mac is disconnected or does not support team messaging; connect it and update Graftty on both Macs")
        }
        do {
            let request = RemoteTeamRequest.send(
                senderWorktree: callerWorktree,
                senderAgentID: callerAgentID,
                recipientWorktree: address.worktreePath,
                recipientSuffix: address.suffix,
                text: text,
                priority: priority
            )
            let data = try await route.send(JSONEncoder().encode(request))
            switch try JSONDecoder().decode(RemoteTeamResponse.self, from: data) {
            case .ok: return .ok
            case .error(let message): return .error(message)
            case .members: return .error("Unexpected response to remote team send")
            }
        } catch {
            // Never retry a send automatically: the peer may have persisted
            // the row before its acknowledgement was lost.
            return .error("Remote team send was not acknowledged; delivery may have occurred: \(error)")
        }
    }

    func includingRemoteMembers(
        in response: ResponseMessage?,
        for request: NotificationMessage
    ) async -> ResponseMessage? {
        guard case .teamList(let name, let localMembers) = response else { return response }
        switch request {
        case .teamList, .teamMembers(_, worktree: nil, repo: nil):
            return .teamList(teamName: name, members: localMembers + (await members()))
        default:
            return response
        }
    }

    func members() async -> [TeamListMember] {
        let selected = routes.keys.compactMap { device -> (RemoteDeviceID, Route)? in
            preferredRoute(for: device).map { (device, $0) }
        }
        let responses = await withTaskGroup(of: (RemoteDeviceID, Route, [TeamListMember]).self) { group in
            for (device, route) in selected {
                group.addTask {
                    do {
                        let data = try await route.send(JSONEncoder().encode(RemoteTeamRequest.list))
                        if case .members(let members) = try JSONDecoder().decode(RemoteTeamResponse.self, from: data) {
                            return (device, route, members)
                        }
                    } catch { }
                    return (device, route, [])
                }
            }
            var result: [(RemoteDeviceID, Route, [TeamListMember])] = []
            for await response in group { result.append(response) }
            return result
        }
        return responses.sorted { $0.0.value < $1.0.value }.flatMap { device, route, members in
            guard routes[device]?[route.id] != nil else { return [TeamListMember]() }
            return members.compactMap { member in
                guard let address = try? RemoteTeamAddress(deviceID: device, worktreePath: member.worktreePath) else { return nil }
                return TeamListMember(
                    name: "\(route.label)/\(member.name)",
                    branch: member.branch,
                    worktreePath: address.rawValue,
                    isMainWorktree: member.isMainWorktree,
                    isRunning: member.isRunning,
                    agents: member.agents.compactMap { agent in
                        guard let identity = TeamAgentIdentity(rawValue: agent.id),
                              identity.runtime == agent.runtime,
                              let qualified = try? RemoteTeamAddress(deviceID: device, worktreePath: member.worktreePath, suffix: agent.id) else { return nil }
                        return TeamListAgent(id: agent.id, address: qualified.rawValue, runtime: agent.runtime, displayName: agent.displayName, isReachable: agent.isReachable, paneSessionName: agent.paneSessionName)
                    }
                )
            }
        }
    }

    private func preferredRoute(for device: RemoteDeviceID) -> Route? {
        routes[device]?.values.max { $0.order < $1.order }
    }
}
