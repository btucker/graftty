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
                cache: HostSnapshotCache = HostSnapshotCache()) {
        self.isPaired = isPaired
        self.coordinator = updates == nil ? coordinator : nil
        self.updates = updates
        self.cache = cache
    }

    public func setHosts(_ hosts: [Host]) {
        let paired = hosts.filter { isPaired?($0) ?? coordinator?.isPaired($0) ?? true }
        guard paired != self.hosts else { return }
        self.hosts = paired
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
        return try await coordinator.worktreePanes(for: host)
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
        guard let coordinator else { return }
        await withTaskGroup(of: Void.self) { group in
            for host in hosts where !state.isLive(host.id) {
                group.addTask { @MainActor in _ = await coordinator.connection(for: host, wake: .now) }
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
