import Foundation
import GrafttyProtocol

/// Every paired host's worktrees, merged for a client that shows them together.
/// A row stays tied to the host that delivered it, because a relayed row's
/// path is an alias only that host can resolve.
public struct MultiHostFeedState: Sendable, Equatable {
    public struct HostInfo: Sendable, Equatable {
        public var id: UUID
        public var label: String
        public var deviceID: RemoteDeviceID?
        public var isWakeable: Bool
        public init(id: UUID, label: String, deviceID: RemoteDeviceID?, isWakeable: Bool) {
            self.id = id; self.label = label; self.deviceID = deviceID; self.isWakeable = isWakeable
        }
    }

    private struct Record: Sendable, Equatable {
        var info: HostInfo
        var isLive = false
        /// The last report. For a sleeping host, this is what stays on screen.
        var rows: [WorktreePanes] = []
        var projects: [SidebarProject] = []
    }

    private var order: [UUID] = []
    private var records: [UUID: Record] = [:]

    public init() {}

    public var hostIDs: [UUID] { order }

    public mutating func setHosts(_ hosts: [HostInfo]) {
        let previous = records
        order = hosts.map(\.id)
        records = [:]
        for host in hosts {
            var record = previous[host.id] ?? Record(info: host)
            record.info = host
            records[host.id] = record
        }
    }

    public mutating func apply(rows: [WorktreePanes], projects: [SidebarProject], from hostID: UUID) {
        records[hostID]?.isLive = true
        records[hostID]?.rows = rows
        records[hostID]?.projects = projects
    }

    public mutating func markUnavailable(_ hostID: UUID) {
        records[hostID]?.isLive = false
    }

    /// The report saved at the last launch, until the host answers.
    public mutating func setCache(_ snapshot: HostSnapshotCache.Snapshot, for hostID: UUID) {
        guard let record = records[hostID], !record.isLive, record.rows.isEmpty else { return }
        records[hostID]?.rows = snapshot.rows
        records[hostID]?.projects = snapshot.projects
    }

    public func isLive(_ hostID: UUID) -> Bool { records[hostID]?.isLive == true }
    public func isAsleep(_ hostID: UUID) -> Bool {
        guard let record = records[hostID] else { return false }
        return !record.isLive && record.info.isWakeable
    }

    /// What this host reported, including rows it relays.
    public func rawRows(of hostID: UUID) -> [WorktreePanes] {
        guard let record = records[hostID], record.isLive else { return [] }
        return record.rows
    }

    public func snapshot(of hostID: UUID) -> HostSnapshotCache.Snapshot? {
        records[hostID].map { .init(projects: $0.projects, rows: $0.rows) }
    }

    private func visibleRows(of record: Record) -> [WorktreePanes] {
        if record.isLive { return record.rows }
        guard record.info.isWakeable else { return [] }
        // A sleeping host relays nothing, so only its own rows are shown.
        return record.rows.filter { ($0.origin?.relayDepth ?? 0) == 0 }
    }

    /// Direct routes come first, so de-duplication keeps them.
    private var deliveries: [(row: WorktreePanes, host: UUID)] {
        order.flatMap { id -> [(row: WorktreePanes, host: UUID)] in
            guard let record = records[id] else { return [] }
            return visibleRows(of: record).map { row in
                (row: row.origin == nil ? row.with(origin: WorktreeOrigin(deviceID: record.info.deviceID ?? RemoteDeviceID(value: id.uuidString), deviceLabel: record.info.label, relayDepth: 0)) : row, host: id)
            }
        }.sorted { ($0.row.origin?.relayDepth ?? 0) < ($1.row.origin?.relayDepth ?? 0) }
    }

    public var rows: [WorktreePanes] {
        var seen: Set<String> = []
        return deliveries.filter { seen.insert(MergedWorktreeList.identity($0.row)).inserted }.map(\.row)
    }

    /// The host to send this row's requests through.
    public func hostID(for row: WorktreePanes) -> UUID? {
        let identity = MergedWorktreeList.identity(row)
        if let delivered = deliveries.first(where: { MergedWorktreeList.identity($0.row) == identity }) { return delivered.host }
        // A row from an older host has no origin until it's attributed here.
        return deliveries.first { $0.row.path == row.path && row.origin == nil }?.host
    }

    public var projects: [SidebarProject] {
        order.flatMap { id -> [SidebarProject] in
            guard let record = records[id] else { return [] }
            return record.isLive ? record.projects : record.projects.filter { ($0.owner?.relayDepth ?? 0) == 0 || $0.owner?.deviceID == record.info.deviceID }
        }
    }

    public func availability(of project: SidebarProject) -> HostAvailability {
        guard let device = project.owner?.deviceID else { return project.isAvailable ? .reachable : .offline }
        if let host = records.values.first(where: { $0.info.deviceID == device }) {
            if host.isLive { return project.isAvailable ? .reachable : .offline }
            if host.info.isWakeable { return .asleep }
        }
        // A third machine reached only through a live relay.
        let relayed = records.values.contains { $0.isLive && $0.projects.contains { $0.id == project.id && $0.isAvailable } }
        return relayed ? .reachable : .offline
    }

    public func merged(localDeviceID: RemoteDeviceID?) -> SidebarMergedRows {
        let state = self
        return SidebarMergedRows.make(projects: projects, localRows: rows, remoteRows: [], localDeviceID: localDeviceID,
                                      availability: { state.availability(of: $0) })
    }
}
