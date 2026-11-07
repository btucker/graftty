import Foundation
import GrafttyProtocol

/// Establishes a destination before any worktree command is dispatched.
/// Only paired intermediaries can advertise and reconnect their saved peers.
@MainActor
public final class HostRouteResolver<HostID: Hashable & Sendable> {
    public struct Host: Hashable, Sendable {
        public let id: HostID
        public let peer: RemoteMacConnectionSummary.ID
        public init(id: HostID, peer: RemoteMacConnectionSummary.ID) { self.id = id; self.peer = peer }
    }

    public struct Target: Hashable, Sendable {
        public let deviceID: RemoteDeviceID
        public let fingerprint: RemoteIdentityFingerprint?
        public init(deviceID: RemoteDeviceID, fingerprint: RemoteIdentityFingerprint? = nil) {
            self.deviceID = deviceID; self.fingerprint = fingerprint
        }
        public init(_ peer: RemoteMacConnectionSummary.ID) {
            self.init(deviceID: peer.deviceID, fingerprint: peer.fingerprint)
        }
    }

    /// @spec REMOTE-13.56
    /// When Mac or mobile opens a host with several available paths, the application shall try its paired direct connection before any relay, even when a relay was used previously.
    public struct Route: Sendable, Equatable {
        public let host: Host
        public let destination: RemoteMacConnectionSummary.ID
        public var isDirect: Bool { host.peer == destination }
    }

    public struct WorktreeRoute: Sendable {
        public let route: Route
        public let worktree: WorktreePanes
    }

    public enum Failure: LocalizedError {
        case unavailable, invalidReply, relayNotReady, worktreeUnavailable
        public var errorDescription: String? {
            switch self {
            case .unavailable: "No direct or relayed connection to this host is available."
            case .invalidReply: "The intermediary could not establish the requested host connection."
            case .relayNotReady: "The intermediary's connection to the host did not become ready."
            case .worktreeUnavailable: "This worktree is no longer available on the destination host."
            }
        }
    }

    public typealias Connect = @MainActor (Host) async throws -> Void
    public typealias Send = @MainActor (Host, WorktreeManagementRequest) async throws -> WorktreeManagementResponse
    public typealias Fetch = @MainActor (Host) async throws -> [WorktreePanes]
    public struct Operations {
        public let connect: Connect
        public let send: Send
        public let fetch: Fetch
        public init(connect: @escaping Connect, send: @escaping Send, fetch: @escaping Fetch) {
            self.connect = connect; self.send = send; self.fetch = fetch
        }
    }
    private struct ResolutionKey: Hashable {
        let target: Target
        let hosts: [Host]
        let preferredRelayID: HostID?
    }
    private struct Pending {
        let id: UUID
        let task: Task<Route, Error>
        var waiters: Set<UUID>
    }
    private var pending: [ResolutionKey: Pending] = [:]
    private let pollAttempts: Int
    private let sleep: @MainActor () async throws -> Void

    public init(pollAttempts: Int = 60, sleep: @escaping @MainActor () async throws -> Void = {
        try await Task.sleep(for: .milliseconds(250))
    }) {
        self.pollAttempts = max(1, pollAttempts)
        self.sleep = sleep
    }

    /// Recently failed terminal paths yield to alternatives for this recovery.
    /// They remain eligible after alternatives fail and on every new open.
    public func resolveWorktree(_ worktree: WorktreePanes, source: Host?, hosts: [Host], excluding: Set<HostID> = [],
                                connect: @escaping Connect, send: @escaping Send, fetch: @escaping Fetch) async throws -> WorktreeRoute {
        guard let owner = worktree.origin?.deviceID ?? source?.peer.deviceID else { throw Failure.worktreeUnavailable }
        let expected = (source?.peer.deviceID == owner ? source : nil)?.peer.fingerprint
            ?? hosts.first { $0.peer.deviceID == owner }?.peer.fingerprint
        var matched: WorktreePanes?
        var destinationVisible = false
        let alternatives = hosts.filter { !excluding.contains($0.id) }
        let attempt: @MainActor ([Host]) async throws -> Route = { candidates in
            try await self.resolveAvailable(target: .init(deviceID: owner, fingerprint: expected), hosts: candidates,
                preferredRelayID: source?.id, connect: { host in
                    try await connect(host)
                    _ = try await fetch(host)
                }, send: send, ready: { route in
                    let rows = try await fetch(route.host).map { row in
                        row.origin == nil ? row.with(origin: .init(deviceID: route.host.peer.deviceID,
                            deviceLabel: route.host.peer.deviceID.value, relayDepth: 0)) : row
                    }
                    destinationVisible = route.isDirect || rows.contains { $0.origin?.deviceID == owner }
                    matched = WorktreeRouteIdentity.matching(worktree, in: rows, owner: owner)
                    return matched != nil
                }, missing: { _ in destinationVisible ? .worktreeUnavailable : .relayNotReady })
        }
        let route: Route
        do { route = try await attempt(alternatives.isEmpty ? hosts : alternatives) }
        catch is CancellationError { throw CancellationError() }
        catch Failure.worktreeUnavailable { throw Failure.worktreeUnavailable }
        catch {
            let previous = hosts.filter { excluding.contains($0.id) }
            guard !alternatives.isEmpty, !previous.isEmpty else { throw error }
            route = try await attempt(previous)
        }
        guard let matched else { throw Failure.worktreeUnavailable }
        return WorktreeRoute(route: route, worktree: matched)
    }

    /// Readiness reads can fail over safely before any resource command runs.
    /// A readable destination that lacks the requested resource is authoritative.
    public func resolveAvailable(target: Target, hosts: [Host], preferredRelayID: HostID? = nil,
                                 connect: @escaping Connect, send: @escaping Send,
                                 ready: @escaping @MainActor (Route) async throws -> Bool,
                                 missing: @escaping @MainActor (Route) -> Failure = { _ in .relayNotReady }) async throws -> Route {
        var remaining = hosts
        while !remaining.isEmpty {
            let route = try await resolve(target: target, hosts: remaining, preferredRelayID: preferredRelayID,
                                          connect: connect, send: send)
            do {
                for attempt in 0..<pollAttempts {
                    try Task.checkCancellation()
                    if try await ready(route) { return route }
                    if attempt + 1 < pollAttempts { try await sleep() }
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                remaining.removeAll { $0.id == route.host.id }
                if remaining.isEmpty { throw error }
                continue
            }
            let failure = missing(route)
            if case .relayNotReady = failure {
                remaining.removeAll { $0.id == route.host.id }
                if !remaining.isEmpty { continue }
            }
            throw failure
        }
        throw Failure.unavailable
    }

    /// Concurrent requests for one destination share establishment, but a
    /// later open always tries direct again. Cancel when no caller needs it.
    public func resolve(target: Target, hosts: [Host], preferredRelayID: HostID? = nil,
                        connect: @escaping Connect, send: @escaping Send) async throws -> Route {
        try Task.checkCancellation()
        let key = ResolutionKey(target: target, hosts: hosts, preferredRelayID: preferredRelayID)
        let waiter = UUID()
        let attempt: Pending
        if var existing = pending[key] {
            existing.waiters.insert(waiter)
            pending[key] = existing
            attempt = existing
        } else {
            let task = Task { @MainActor in
                try await self.establish(target: target, hosts: hosts, preferredRelayID: preferredRelayID, connect: connect, send: send)
            }
            attempt = Pending(id: UUID(), task: task, waiters: [waiter])
            pending[key] = attempt
        }
        return try await withTaskCancellationHandler {
            defer { release(key, attemptID: attempt.id, waiter: waiter) }
            let route = try await attempt.task.value
            try Task.checkCancellation()
            return route
        } onCancel: {
            Task { @MainActor in self.release(key, attemptID: attempt.id, waiter: waiter) }
        }
    }

    private func release(_ key: ResolutionKey, attemptID: UUID, waiter: UUID) {
        guard var attempt = pending[key], attempt.id == attemptID,
              attempt.waiters.remove(waiter) != nil else { return }
        if attempt.waiters.isEmpty {
            pending[key] = nil
            attempt.task.cancel()
        } else { pending[key] = attempt }
    }

    private func establish(target: Target, hosts: [Host], preferredRelayID: HostID?, connect: Connect, send: Send) async throws -> Route {
        try Task.checkCancellation()
        let direct = hosts.first { $0.peer.deviceID == target.deviceID && (target.fingerprint == nil || $0.peer.fingerprint == target.fingerprint) }
        let fingerprint = target.fingerprint ?? direct?.peer.fingerprint
        if let direct {
            do {
                try await connect(direct)
                try Task.checkCancellation()
                return Route(host: direct, destination: direct.peer)
            } catch is CancellationError { throw CancellationError() }
            catch { /* A failed direct path may still be reachable through a paired Mac. */ }
        }
        let relays = hosts.filter { $0.peer.deviceID != target.deviceID }
        let ordered = relays.filter { $0.id == preferredRelayID } + relays.filter { $0.id != preferredRelayID }
        for relay in ordered {
            try Task.checkCancellation()
            do {
                try await connect(relay)
                try Task.checkCancellation()
                guard let summary = try await summaries(on: relay, send: send).first(where: {
                    $0.deviceID == target.deviceID && (fingerprint == nil || $0.fingerprint == fingerprint)
                }), summary.state != .needsPairing else { continue }
                if summary.state == .connected { return Route(host: relay, destination: summary.id) }
                if summary.state != .connecting {
                    let reply = try await send(relay, .connectRemoteMac(deviceID: summary.deviceID, fingerprint: summary.fingerprint))
                    guard reply == .ok else { throw Failure.invalidReply }
                }
                for _ in 0..<pollAttempts {
                    try await sleep()
                    try Task.checkCancellation()
                    let current = try await summaries(on: relay, send: send).first { $0.id == summary.id }
                    guard let current, current.state != .needsPairing else { throw Failure.relayNotReady }
                    if current.state == .connected { return Route(host: relay, destination: current.id) }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { continue }
        }
        throw Failure.unavailable
    }

    private func summaries(on host: Host, send: Send) async throws -> [RemoteMacConnectionSummary] {
        try Task.checkCancellation()
        guard case .remoteMacConnections(let peers) = try await send(host, .listRemoteMacConnections) else { throw Failure.invalidReply }
        try Task.checkCancellation()
        return peers
    }
}

/// Match presentation identity, never a relay's opaque path or display name.
public enum WorktreeRouteIdentity {
    public static func paneSession(_ session: String, from source: WorktreePanes, to destination: WorktreePanes) -> String? {
        if let stableID = source.sidebar?.paneIDs?[session] {
            return destination.sidebar?.paneIDs?.first { $0.value == stableID }?.key
        }
        return source.path == destination.path && destination.layout?.leaves.contains(where: { $0.sessionName == session }) == true ? session : nil
    }

    public static func matching(_ target: WorktreePanes, in rows: [WorktreePanes], owner: RemoteDeviceID) -> WorktreePanes? {
        rows.first { row in
            guard row.origin?.deviceID == owner, (row.origin?.relayDepth ?? 0) <= 1 else { return false }
            if let id = target.sidebar?.id { return row.sidebar?.id == id }
            return (target.origin?.relayDepth ?? 0) == 0 && (row.origin?.relayDepth ?? 0) == 0 && row.path == target.path
        }
    }
}
