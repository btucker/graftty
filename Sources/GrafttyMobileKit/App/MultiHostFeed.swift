#if canImport(UIKit)
import Foundation
import GrafttyCommandUI
import GrafttyProtocol
import GrafttyRemoteClient
import Observation
import SwiftUI

/// Every paired host's worktrees, kept current together. Connections here are
/// quiet: opening the app never starts a sleeping host. Anything that needs a
/// host goes through its provider or `wake`, which may.
@Observable
@MainActor
public final class MultiHostFeed {
    public private(set) var state = MultiHostFeedState()
    public private(set) var hosts: [Host] = []
    let downstreamConnections = DownstreamHostConnections<UUID>()
    private let hostRouteResolver = HostRouteResolver<UUID>()
    private let routeOperationsOverride: HostRouteResolver<UUID>.Operations?
    private var pendingNavigation: UUID?
    private var navigationGeneration: UInt64 = 0
    private struct TerminalRoute: Hashable {
        let host: UUID
        let worktree: String
        let pane: String
    }
    private var reconnectingTerminals: Set<TerminalRoute> = []
    private var failedTerminalHosts: [String: Set<UUID>] = [:]
    private var activeRecovery: (token: UUID, host: UUID, path: String, pane: String?)?

    func terminalConnectionChanged(host: UUID, worktree: String, pane: String, reconnecting: Bool) {
        let route = TerminalRoute(host: host, worktree: worktree, pane: pane)
        if reconnecting { reconnectingTerminals.insert(route) }
        else { reconnectingTerminals.remove(route) }
        if let row = state.snapshot(of: host)?.rows.first(where: { $0.path == worktree }) {
            let key = MergedWorktreeList.identity(row)
            if reconnecting { failedTerminalHosts[key, default: []].insert(host) }
            else { failedTerminalHosts[key] = nil }
        }
    }

    func permitsTerminalDial(host: UUID, worktree: String, pane: String) -> Bool {
        !reconnectingTerminals.contains(.init(host: host, worktree: worktree, pane: pane))
    }

    func beginRouteSelection() -> UUID {
        let token = UUID()
        navigationGeneration &+= 1
        failedTerminalHosts.removeAll()
        pendingNavigation = token
        return token
    }

    func endRouteSelection(_ token: UUID) {
        if pendingNavigation == token { pendingNavigation = nil }
    }

    var permitsRouteRecovery: Bool { pendingNavigation == nil }
    /// True once every host has either answered or failed at least once.
    public private(set) var hasSettled = false

    private let coordinator: RemoteConnectionCoordinator?
    private let updates: (@MainActor (Host) -> AsyncStream<RemoteWorktreeUpdate>?)?
    private let isPaired: (@MainActor (Host) -> Bool)?
    private let cache: HostSnapshotCache
    private var settledHosts: Set<UUID> = []
    private var savedAt: [UUID: Date] = [:]

    public init(coordinator: RemoteConnectionCoordinator?,
                updates: (@MainActor (Host) -> AsyncStream<RemoteWorktreeUpdate>?)? = nil,
                isPaired: (@MainActor (Host) -> Bool)? = nil,
                cache: HostSnapshotCache = HostSnapshotCache(),
                routeOperations: HostRouteResolver<UUID>.Operations? = nil) {
        self.isPaired = isPaired
        self.coordinator = updates == nil ? coordinator : nil
        self.updates = updates
        self.cache = cache
        self.routeOperationsOverride = routeOperations
    }

    public func setHosts(_ hosts: [Host]) {
        let paired = hosts.filter { isPaired?($0) ?? coordinator?.isPaired($0) ?? true }
        guard paired != self.hosts else { return }
        self.hosts = paired
        let pairedIDs = Set(paired.map(\.id))
        reconnectingTerminals = reconnectingTerminals.filter { pairedIDs.contains($0.host) }
        state.setHosts(paired.map { host in
            .init(id: host.id, label: host.label, deviceID: host.remoteDeviceID,
                  isWakeable: coordinator?.hasWakeAddresses(host) ?? false)
        })
        state.loadCaches { cache.load(hostID: $0) }
        settledHosts.formIntersection(paired.map(\.id))
        hasSettled = settledHosts.count == paired.count
    }

    /// Runs until cancelled, with one observation per host.
    public func observe() async {
        await withTaskGroup(of: Void.self) { group in
            for host in hosts {
                group.addTask { @MainActor [weak self] in await self?.observe(host) }
            }
        }
    }

    private func observe(_ host: Host) async {
        let stream = updates?(host) ?? coordinator?.worktreeUpdates(for: host, wake: .never)
        guard let stream else { markSettled(host.id); return }
        for await update in stream {
            guard !Task.isCancelled else { return }
            receive(update, from: host)
        }
    }

    func receive(_ update: RemoteWorktreeUpdate, from host: Host) {
        markSettled(host.id)
        switch update {
        case .unavailable:
            updateState { $0.markUnavailable(host.id) }
        case let .frame(.snapshot(rows, metadata)):
            updateState { $0.apply(rows: rows, projects: metadata?.projects ?? SidebarProjection.projects(rows), from: host.id) }
            saveSnapshot(of: host)
        }
    }

    /// IOS-10.10: hosts repeat frames while agents work. Writing an equal state
    /// would still redraw every view that reads it, so only a change is stored.
    private func updateState(_ change: (inout MultiHostFeedState) -> Void) {
        var next = state
        change(&next)
        if next != state { state = next }
    }

    private func markSettled(_ id: UUID) {
        settledHosts.insert(id)
        hasSettled = settledHosts.count == hosts.count
    }

    /// Sleeping rows only need to be roughly current.
    private func saveSnapshot(of host: Host) {
        guard Date().timeIntervalSince(savedAt[host.id] ?? .distantPast) > 30 else { return }
        savedAt[host.id] = Date()
        // A host signs its wake details when dialed, so check them again here.
        let isWakeable = coordinator?.hasWakeAddresses(host) ?? false
        updateState { $0.setWakeable(isWakeable, for: host.id) }
        guard isWakeable, let device = host.remoteDeviceID, let snapshot = state.snapshot(of: host.id) else { return }
        let cache = cache
        Task.detached(priority: .utility) {
            try? cache.save(hostID: device, projects: snapshot.projects,
                            rows: snapshot.rows.filter { ($0.origin?.relayDepth ?? 0) == 0 })
        }
    }

    public func host(id: UUID?) -> Host? { hosts.first { $0.id == id } }

    public func host(for row: WorktreePanes) -> Host? { host(id: state.hostID(for: row)) }

    /// The host that reported a project, preferring its owner over a relay.
    public func host(for project: SidebarProject) -> Host? {
        hosts.first { $0.remoteDeviceID == project.owner?.deviceID && state.isLive($0.id) }
            ?? hosts.first { candidate in state.isLive(candidate.id) && state.snapshot(of: candidate.id)?.projects.contains { $0.id == project.id } == true }
            ?? hosts.first { $0.remoteDeviceID == project.owner?.deviceID }
    }

    /// Requests through this need the host, so by default they wake it. That
    /// has to skip the cooldown: this feed's quiet dials fail while a host sleeps.
    /// Background reads of a host that's already live pass `.never`.
    public func provider(for host: Host, wake: RemoteConnectionCoordinator.WakePolicy = .now) -> RemoteConnectionProvider {
        if let coordinator { return makeRemoteConnectionProvider(coordinator: coordinator, host: host, sessionName: "worktree-management", wake: wake) }
        return { nil }
    }

    /// Fresh rows from one host, dialing it if needed.
    public func fetchRows(on host: Host) async throws -> [WorktreePanes] {
        guard let coordinator else { throw RelayedWorktreeManagementClient.ClientError.pairedConnectionUnavailable }
        return try await coordinator.worktreePanes(for: host, wake: .now)
    }

    private var routeHosts: [HostRouteResolver<UUID>.Host] {
        let ordered = hosts.filter { state.isLive($0.id) } + hosts.filter { !state.isLive($0.id) }
        return ordered.compactMap { host in
            coordinator?.pairedPeerIdentity(for: host).map { .init(id: host.id, peer: $0) }
        }
    }

    private func savedRouteHost(_ candidate: HostRouteResolver<UUID>.Host) throws -> Host {
        guard let host = host(id: candidate.id), coordinator?.pairedPeerIdentity(for: host) == candidate.peer else {
            throw RelayedWorktreeManagementClient.ClientError.pairedConnectionUnavailable
        }
        return host
    }

    private func connectRouteHost(_ candidate: HostRouteResolver<UUID>.Host) async throws {
        let host = try savedRouteHost(candidate)
        if let operations = routeOperationsOverride { try await operations.connect(candidate); return }
        guard await coordinator?.connection(for: host, wake: .now) != nil else {
            throw RelayedWorktreeManagementClient.ClientError.pairedConnectionUnavailable
        }
    }

    private func sendRouteRequest(_ candidate: HostRouteResolver<UUID>.Host, _ request: WorktreeManagementRequest) async throws -> WorktreeManagementResponse {
        let host = try savedRouteHost(candidate)
        if let operations = routeOperationsOverride { return try await operations.send(candidate, request) }
        guard let coordinator else { throw RelayedWorktreeManagementClient.ClientError.pairedConnectionUnavailable }
        return try await coordinator.sendWorktreeManagement(request, to: host)
    }

    private func routeRows(_ candidate: HostRouteResolver<UUID>.Host) async throws -> [WorktreePanes] {
        let host = try savedRouteHost(candidate)
        let rows: [WorktreePanes]
        if let operations = routeOperationsOverride { rows = try await operations.fetch(candidate) }
        else { rows = try await fetchRows(on: host) }
        _ = try savedRouteHost(candidate)
        let frame = await coordinator?.navigationSnapshot(for: host, matching: rows) ?? .snapshot(rows)
        receive(.frame(frame), from: host)
        return state.snapshot(of: host.id)?.rows ?? rows
    }

    private func routeOperations(owner: RemoteDeviceID, pins: Set<RemoteMacConnectionSummary.ID>) -> HostRouteResolver<UUID>.Operations {
        let validate: @MainActor () throws -> Void = { [self] in
            try Task.checkCancellation()
            guard Set(routeHosts.filter { $0.peer.deviceID == owner }.map(\.peer)) == pins else {
                throw RelayedWorktreeManagementClient.ClientError.pairedConnectionUnavailable
            }
        }
        return .init(connect: { [self] host in
            try validate()
            try await connectRouteHost(host)
            try validate()
        }, send: { [self] host, request in
            try validate()
            let reply = try await sendRouteRequest(host, request)
            try validate()
            return reply
        }, fetch: { [self] host in
            try validate()
            let rows = try await routeRows(host)
            try validate()
            return rows
        })
    }

    public func resolveWorktreeRoute(_ worktree: WorktreePanes, from source: Host? = nil, excluding: Set<UUID> = []) async throws -> (host: Host, worktree: WorktreePanes) {
        if coordinator == nil, updates != nil, let host = host(for: worktree) ?? source {
            return (host, worktree) // A supplied feed transport owns its connection lifecycle.
        }
        let candidates = routeHosts
        let source = source ?? host(for: worktree)
        guard let owner = worktree.origin?.deviceID ?? source?.remoteDeviceID else {
            throw HostRouteResolver<UUID>.Failure.worktreeUnavailable
        }
        let originalPins = Set(candidates.filter { $0.peer.deviceID == owner }.map(\.peer))
        let operations = routeOperations(owner: owner, pins: originalPins)
        let resolved = try await hostRouteResolver.resolveWorktree(worktree, source: candidates.first { $0.id == source?.id }, hosts: candidates, excluding: excluding,
            connect: operations.connect, send: operations.send, fetch: operations.fetch)
        let currentPins = Set(routeHosts.filter { $0.peer.deviceID == owner }.map(\.peer))
        guard currentPins == originalPins, currentPins.isEmpty || currentPins.contains(resolved.route.destination) else {
            throw RelayedWorktreeManagementClient.ClientError.pairedConnectionUnavailable
        }
        return (try savedRouteHost(resolved.route.host), resolved.worktree)
    }

    func resolveHostRoute(_ source: Host, destination: RemoteDeviceID? = nil) async throws -> Host {
        guard let owner = destination ?? source.remoteDeviceID else { throw HostRouteResolver<UUID>.Failure.unavailable }
        let candidates = routeHosts
        let pins = Set(candidates.filter { $0.peer.deviceID == owner }.map(\.peer))
        let operations = routeOperations(owner: owner, pins: pins)
        let route = try await hostRouteResolver.resolveAvailable(target: .init(deviceID: owner, fingerprint: pins.first?.fingerprint),
            hosts: candidates, preferredRelayID: source.id, connect: { host in
                try await operations.connect(host)
                _ = try await operations.fetch(host)
            }, send: operations.send, ready: { route in
                let rows = try await operations.fetch(route.host)
                return route.isDirect || rows.contains { $0.origin?.deviceID == owner }
            })
        let currentPins = Set(routeHosts.filter { $0.peer.deviceID == owner }.map(\.peer))
        guard pins == currentPins, currentPins.isEmpty || currentPins.contains(route.destination) else {
            throw RelayedWorktreeManagementClient.ClientError.pairedConnectionUnavailable
        }
        return try savedRouteHost(route.host)
    }

    func shouldRecoverSelection(_ selection: IPadAppState) -> Bool {
        guard let id = selection.selectedHostId, host(id: id) != nil,
              let path = selection.selectedWorktreePath,
              let row = selection.latestWorktrees.first(where: { $0.path == path }) else { return false }
        if let activeRecovery, activeRecovery.host == id, activeRecovery.path == path,
           activeRecovery.pane == selection.focusedPaneId { return true }
        if let pane = selection.focusedPaneId,
           reconnectingTerminals.contains(.init(host: id, worktree: path, pane: pane)) { return true }
        if !state.isLive(id) { return true }
        if state.rawRows(of: id).contains(where: { $0.path == path }) { return false }
        return state.snapshot(of: id)?.projects.first(where: { $0.id == SidebarProjection.projectID(row) })?.isAvailable == false
    }

    /// Reconnection changes both delivery host and resource IDs together. A
    /// navigation or pane-focus change during establishment cancels adoption.
    func recoverSelection(_ selection: IPadAppState, requestsTerminalFocus: Bool = false, isCurrent: () -> Bool = { true }) async throws -> Bool {
        guard permitsRouteRecovery, isCurrent(), shouldRecoverSelection(selection), let host = host(id: selection.selectedHostId),
              let row = selection.latestWorktrees.first(where: { $0.path == selection.selectedWorktreePath }) else { return false }
        let pane = selection.focusedPaneId
        let focus = selection.focusRequestCount
        let generation = navigationGeneration
        let token = UUID()
        activeRecovery = (token, host.id, row.path, pane)
        defer { if activeRecovery?.token == token { activeRecovery = nil } }
        let failedHosts = failedTerminalHosts[MergedWorktreeList.identity(row)] ?? []
        let resolved = try await resolveWorktreeRoute(row, from: host, excluding: failedHosts)
        try Task.checkCancellation()
        guard permitsRouteRecovery, navigationGeneration == generation, isCurrent(), selection.selectedHostId == host.id, selection.selectedWorktreePath == row.path,
              selection.focusedPaneId == pane, selection.focusRequestCount == focus else { return false }
        selection.latestWorktrees = state.rawRows(of: resolved.host.id)
        if let pane { reconnectingTerminals.remove(.init(host: host.id, worktree: row.path, pane: pane)) }
        let replacement = pane.flatMap { WorktreeRouteIdentity.paneSession($0, from: row, to: resolved.worktree) }
            ?? resolved.worktree.layout?.leaves.first?.sessionName
        selection.select(hostID: resolved.host.id, worktreePath: resolved.worktree.path, paneID: replacement,
                         requestsTerminalFocus: requestsTerminalFocus)
        return true
    }

    /// An interaction needs this host. True once its live rows have arrived.
    public func wake(_ host: Host) async -> Bool {
        guard let coordinator, await coordinator.connection(for: host, wake: .now) != nil else { return false }
        for _ in 0..<50 {
            if state.isLive(host.id) { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return state.isLive(host.id)
    }

    /// The person asked to try again, so hosts that aren't connected may wake.
    /// A connection this opens reaches the feed through that host's observation.
    public func retry() async {
        guard coordinator != nil else { return }
        await withTaskGroup(of: Void.self) { group in
            for host in hosts where !state.isLive(host.id) {
                group.addTask { @MainActor in
                    _ = try? await self.resolveHostRoute(host)
                }
            }
        }
        await refresh()
    }

    public func refresh() async {
        guard let coordinator else { return }
        for host in hosts where state.isLive(host.id) {
            if let rows = try? await coordinator.worktreePanes(for: host),
               let projects = state.snapshot(of: host.id)?.projects {
                state.apply(rows: rows, projects: projects, from: host.id)
            }
        }
    }
}

private struct MultiHostFeedKey: EnvironmentKey {
    static let defaultValue: MultiHostFeed? = nil
}

extension EnvironmentValues {
    var multiHostFeed: MultiHostFeed? {
        get { self[MultiHostFeedKey.self] }
        set { self[MultiHostFeedKey.self] = newValue }
    }
}
#endif
