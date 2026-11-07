import Foundation
import GrafttyProtocol
import Observation

/// Connection controls for hosts reachable through an already paired Mac.
/// A destination can have several routes, each with its own connection state.
@Observable
@MainActor
public final class DownstreamHostConnections<HostID: Hashable & Sendable> {
    public struct Host: Identifiable, Equatable, Sendable {
        public let id: HostID
        public let label: String
        public let isConnected: Bool

        public init(id: HostID, label: String, isConnected: Bool = true) {
            self.id = id
            self.label = label
            self.isConnected = isConnected
        }
    }

    /// @spec REMOTE-13.49
    /// While the Mac or mobile host manager is open, the application shall list each downstream host with its intermediary Mac and preserve separate routes to the same destination.
    public struct Route: Identifiable, Equatable, Sendable {
        public struct ID: Hashable, Sendable {
            public let hostID: HostID
            public let targetID: RemoteMacConnectionSummary.ID
        }

        public let host: Host
        public let target: RemoteMacConnectionSummary
        public var id: ID { .init(hostID: host.id, targetID: target.id) }
        public var label: String { "\(target.label) via \(host.label)" }
    }

    public typealias Send = @MainActor (HostID, WorktreeManagementRequest) async throws -> WorktreeManagementResponse

    public private(set) var routes: [Route] = []
    public private(set) var connecting: Set<Route.ID> = []
    public var error: String?
    private var refreshGeneration = 0

    public init() {}

    /// Retain known routes while their saved intermediary is offline. Polling
    /// must never wake a host; explicit actions may reconnect it.
    public func refresh(hosts: [Host], send: Send) async {
        refreshGeneration += 1
        let generation = refreshGeneration
        var next: [Route] = []
        for host in hosts {
            guard !Task.isCancelled, generation == refreshGeneration else { return }
            guard host.isConnected else {
                next += routes.filter { $0.host.id == host.id }.map { Route(host: host, target: $0.target) }
                continue
            }
            guard case .remoteMacConnections(let targets)? = try? await send(host.id, .listRemoteMacConnections) else {
                let unavailable = Host(id: host.id, label: host.label, isConnected: false)
                next += routes.filter { $0.host.id == host.id }.map { Route(host: unavailable, target: $0.target) }
                continue
            }
            var seen: Set<RemoteMacConnectionSummary.ID> = []
            next += targets.filter { seen.insert($0.id).inserted }.map { Route(host: host, target: $0) }
        }
        guard !Task.isCancelled, generation == refreshGeneration else { return }
        routes = next
    }

    public func connect(_ route: Route, send: Send) async {
        guard let current = routes.first(where: { $0.id == route.id }) else {
            error = "\(route.label) is no longer available. Refresh the host list and try again."
            return
        }
        guard (!current.host.isConnected || current.target.state != .connecting), current.target.state != .needsPairing,
              connecting.insert(route.id).inserted else { return }
        defer { connecting.remove(route.id) }
        error = nil
        do {
            let response = try await send(route.host.id, .connectRemoteMac(
                deviceID: route.target.deviceID, fingerprint: route.target.fingerprint))
            switch response {
            case .ok: break // Accepted; only a later host report confirms the connection.
            case .error(_, let message, _, _): error = "\(route.label): \(message)"
            default: error = "\(route.label): The Mac returned an unexpected connection response."
            }
        } catch is CancellationError {
            return
        } catch {
            self.error = "Couldn't connect to \(route.label): \(error.localizedDescription)"
        }
    }
}
