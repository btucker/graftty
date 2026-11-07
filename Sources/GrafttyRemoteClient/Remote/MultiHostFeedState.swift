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

    /// One worktree's chosen route to this client.
    private struct Delivery: Sendable, Equatable {
        var row: WorktreePanes
        var host: UUID
        var isLive: Bool
    }

    private var order: [UUID] = []
    private var records: [UUID: Record] = [:]
    /// Views read these once per drawn row, so they're rebuilt when a host
    /// changes rather than on each read.
    private var deliveries: [Delivery] = []
    private var hostByIdentity: [String: UUID] = [:]
    public private(set) var rows: [WorktreePanes] = []
    public private(set) var projects: [SidebarProject] = []

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
        rebuild()
    }

    public mutating func apply(rows: [WorktreePanes], projects: [SidebarProject], from hostID: UUID) {
        records[hostID]?.isLive = true
        records[hostID]?.rows = rows
        records[hostID]?.projects = projects
        rebuild()
    }

    public mutating func markUnavailable(_ hostID: UUID) {
        records[hostID]?.isLive = false
        rebuild()
    }

    /// The report saved at the last launch, until the host answers.
    public mutating func setCache(_ snapshot: HostSnapshotCache.Snapshot, for hostID: UUID) {
        guard let record = records[hostID], !record.isLive, record.rows.isEmpty else { return }
        records[hostID]?.rows = snapshot.rows
        records[hostID]?.projects = snapshot.projects
        rebuild()
    }

    /// Gives every sleeping host with nothing to show its saved report.
    public mutating func loadCaches(_ load: (RemoteDeviceID) -> HostSnapshotCache.Snapshot?) {
        for id in order where needsReconnect(id) {
            guard let record = records[id], record.rows.isEmpty, let device = record.info.deviceID,
                  let snapshot = load(device) else { continue }
            setCache(snapshot, for: id)
        }
    }

    /// A host signs its wake details during a dial, so they can arrive after it
    /// was first listed.
    public mutating func setWakeable(_ isWakeable: Bool, for hostID: UUID) {
        guard let record = records[hostID], record.info.isWakeable != isWakeable else { return }
        records[hostID]?.info.isWakeable = isWakeable
        rebuild()
    }

    public func isLive(_ hostID: UUID) -> Bool { records[hostID]?.isLive == true }
    public func availability(of hostID: UUID) -> HostAvailability {
        guard let record = records[hostID] else { return .offline }
        if record.isLive { return .reachable }
        return record.info.isWakeable ? .wakeable : .offline
    }

    /// A cached host can be reconnected and, if necessary, woken. Saved wake
    /// details are a capability, never evidence of the host's power state.
    public func needsReconnect(_ hostID: UUID) -> Bool {
        availability(of: hostID) == .wakeable
    }

    /// What this host reported, including rows it relays.
    public func rawRows(of hostID: UUID) -> [WorktreePanes] {
        guard let record = records[hostID], record.isLive else { return [] }
        return record.rows
    }

    public func snapshot(of hostID: UUID) -> HostSnapshotCache.Snapshot? {
        records[hostID].map { .init(projects: $0.projects, rows: $0.rows) }
    }

    /// Rows a host is reporting now, without a sleeping host's last report.
    public var liveRows: [WorktreePanes] { deliveries.filter(\.isLive).map(\.row) }

    private func visibleRows(of record: Record) -> [WorktreePanes] {
        if record.isLive { return record.rows }
        guard record.info.isWakeable else { return [] }
        // A sleeping host relays nothing, so only its own rows are shown.
        return record.rows.filter { ($0.origin?.relayDepth ?? 0) == 0 }
    }

    private mutating func rebuild() {
        var all: [Delivery] = []
        for id in order {
            guard let record = records[id] else { continue }
            for row in visibleRows(of: record) {
                let attributed = row.origin == nil
                    ? row.with(origin: WorktreeOrigin(deviceID: record.info.deviceID ?? RemoteDeviceID(value: id.uuidString), deviceLabel: record.info.label, relayDepth: 0))
                    : row
                all.append(Delivery(row: attributed, host: id, isLive: record.isLive))
            }
        }
        // De-duplication keeps the first: a live route over a saved report, then
        // the most direct.
        func priority(_ delivery: Delivery) -> (Int, Int) { (delivery.isLive ? 0 : 1, delivery.row.origin?.relayDepth ?? 0) }
        all.sort { priority($0) < priority($1) }
        var seen: Set<String> = []
        deliveries = all.filter { seen.insert(MergedWorktreeList.identity($0.row)).inserted }
        rows = deliveries.map(\.row)
        hostByIdentity = Dictionary(deliveries.map { (MergedWorktreeList.identity($0.row), $0.host) }, uniquingKeysWith: { first, _ in first })

        let liveProjects = Set(order.flatMap { id -> [String] in
            guard let record = records[id], record.isLive else { return [] }
            return record.projects.map(\.id)
        })
        projects = order.flatMap { id -> [SidebarProject] in
            guard let record = records[id] else { return [] }
            if record.isLive { return record.projects }
            return record.projects.filter {
                !liveProjects.contains($0.id) && (($0.owner?.relayDepth ?? 0) == 0 || $0.owner?.deviceID == record.info.deviceID)
            }
        }
    }

    /// The host to send this row's requests through.
    public func hostID(for row: WorktreePanes) -> UUID? {
        if let host = hostByIdentity[MergedWorktreeList.identity(row)] { return host }
        // A row from an older host has no origin until it's attributed here.
        guard row.origin == nil else { return nil }
        return deliveries.first { $0.row.path == row.path }?.host
    }

    public func availability(of project: SidebarProject) -> HostAvailability {
        guard let device = project.owner?.deviceID else { return project.isAvailable ? .reachable : .offline }
        let host = records.values.first { $0.info.deviceID == device }
        if let host, host.isLive { return project.isAvailable ? .reachable : .offline }
        // A live relay reaches it without waking anything.
        let relayed = records.values.contains { $0.isLive && $0.projects.contains { $0.id == project.id && $0.isAvailable } }
        if relayed { return .reachable }
        return host?.info.isWakeable == true ? .wakeable : .offline
    }

    /// `rows` stands in for the delivered rows, for a client that adds its own
    /// placeholders while a worktree is being created.
    public func merged(localDeviceID: RemoteDeviceID?, rows: [WorktreePanes]? = nil) -> SidebarMergedRows {
        let state = self
        return SidebarMergedRows.make(projects: projects, localRows: rows ?? self.rows, remoteRows: [], localDeviceID: localDeviceID,
                                      availability: { state.availability(of: $0) })
    }
}
