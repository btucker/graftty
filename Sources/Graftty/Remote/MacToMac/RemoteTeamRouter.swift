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
        let closeForReconnect: (@Sendable () async -> Void)?
    }

    private var routes: [RemoteDeviceID: [UUID: Route]] = [:]
    private var worktreeTargets: [String: (device: RemoteDeviceID, lastUsed: Date)] = [:]
    private var sequence: UInt64 = 0
    private var reconnectsInFlight: Set<UUID> = []
    var handler: Handler = { _, _ in
        (try? JSONEncoder().encode(RemoteTeamResponse.error("Team messaging is not ready"))) ?? Data()
    }

    func register(
        deviceID: RemoteDeviceID, connectionID: UUID, label: String,
        closeForReconnect: (@Sendable () async -> Void)? = nil,
        send: @escaping Sender
    ) {
        sequence &+= 1
        routes[deviceID, default: [:]][connectionID] = Route(
            id: connectionID, label: label, order: sequence, send: send,
            closeForReconnect: closeForReconnect
        )
    }

    func reconnectClient(target: String) async -> ResponseMessage {
        // Only host-side routes represent viewers. An outgoing connection
        // to the same device must never substitute for a missing viewer.
        let clients = routes.compactMap { device, connections -> (RemoteDeviceID, Route)? in
            connections.values.filter { $0.closeForReconnect != nil }
                .max { $0.order < $1.order }.map { (device, $0) }
        }
        let ids = clients.filter { $0.0.value == target }
        let matches = ids.isEmpty ? clients.filter { $0.1.label == target } : ids
        guard matches.count == 1 else {
            let choices = clients.map { "\($0.1.label): \($0.0.value)" }.sorted().joined(separator: ", ")
            let reason = matches.isEmpty ? "Unknown or disconnected" : "Ambiguous"
            return .error("\(reason) viewing Mac '\(target)'. Connected clients: \(choices.isEmpty ? "none" : choices)")
        }
        let (device, route) = matches[0]
        guard reconnectsInFlight.insert(route.id).inserted else {
            return .error("A reconnect request for \(route.label) is already in progress")
        }
        defer { reconnectsInFlight.remove(route.id) }
        do {
            let data = try await route.send(JSONEncoder().encode(RemoteTeamRequest.prepareReconnect))
            switch try JSONDecoder().decode(RemoteTeamResponse.self, from: data) {
            case .ok:
                guard routes[device]?[route.id] != nil else {
                    return .error("The viewing Mac's connection changed during the reconnect request; check its status")
                }
                // The viewer has acknowledged and armed reconnect. Closing
                // this exact subsystem is the commit signal, so teardown
                // cannot consume the acknowledgement or close a replacement.
                unregister(deviceID: device, connectionID: route.id)
                await route.closeForReconnect?()
                return .ok
            case .error(let message):
                return .error(message)
            case .members, .worktreeCreate:
                return .error("Unexpected response to client reconnect; update Graftty on both Macs")
            }
        } catch {
            return .error("Client reconnect was not acknowledged; the client may still reconnect. Check its status before retrying: \(error)")
        }
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
            case .members, .worktreeCreate: return .error("Unexpected response to remote team send")
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

    func worktree(
        target: String, request: RemoteWorktreeRequest, repos: [RepoEntry],
        readOrigin: GitRepositoryOrigin.Loader? = nil
    ) async -> ResponseMessage {
        let cutoff = Date().addingTimeInterval(-60 * 60)
        worktreeTargets = worktreeTargets.filter { $0.value.lastUsed > cutoff }
        let device: RemoteDeviceID
        if let pinned = worktreeTargets[request.operationID] {
            device = pinned.device
        } else {
            let selected = routes.keys.compactMap { device in
                preferredRoute(for: device).map { (device, $0) }
            }
            let ids = selected.filter { $0.0.value == target }
            let matches = ids.isEmpty ? selected.filter { $0.1.label == target } : ids
            guard matches.count == 1 else {
                let choices = selected.map { "\($0.1.label): \($0.0.value)" }.sorted().joined(separator: ", ")
                return .error("\(matches.isEmpty ? "Unknown or disconnected" : "Ambiguous") Mac '\(target)'. Connected Macs: \(choices.isEmpty ? "none" : choices)")
            }
            device = matches[0].0
        }
        // Pin before reading Git metadata, which suspends this actor too.
        worktreeTargets[request.operationID] = (device, Date())
        let outgoing: RemoteWorktreeRequest
        do {
            switch request {
            case .create(let creation): outgoing = .create(try await creation.resolvingSourceProject(in: repos, readOrigin: readOrigin))
            case .status: outgoing = request
            }
        } catch { return .error(String(describing: error)) }
        guard let route = preferredRoute(for: device) else {
            return .error("Destination Mac \(device.value) is disconnected; operation \(request.operationID) may still finish. Check that Mac before creating another worktree")
        }
        do {
            let data = try await route.send(JSONEncoder().encode(RemoteTeamRequest.worktree(outgoing)))
            switch try JSONDecoder().decode(RemoteTeamResponse.self, from: data) {
            case .worktreeCreate(let status):
                guard status.operationID == request.operationID else {
                    throw RemoteWorktreeError("Mismatched remote operation ID")
                }
                let address = try RemoteTeamAddress(deviceID: device, worktreePath: status.worktreePath)
                return .worktreeCreate(.init(operationID: status.operationID, state: status.state,
                    worktreePath: status.worktreePath, messageAddress: address.rawValue, error: status.error))
            case .error(let message): return .error(message)
            case .ok, .members:
                throw RemoteWorktreeError("Unexpected response; update Graftty on both Macs")
            }
        } catch TeamRPCSession.SessionError.timedOut {
            return .worktreeCreateRetry(operationID: request.operationID)
        } catch {
            return .error("Remote worktree operation \(request.operationID) was not acknowledged and may still finish. Check the destination before creating another worktree. Both Macs must support remote worktree creation: \(error)")
        }
    }

    private func preferredRoute(for device: RemoteDeviceID) -> Route? {
        routes[device]?.values.max { $0.order < $1.order }
    }
}
