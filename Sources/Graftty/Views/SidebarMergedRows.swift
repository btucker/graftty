import Foundation
import GrafttyProtocol

/// Everything the Mac sidebar shows, once projects and rows from every host
/// are merged. Rows keep their owning host so requests still route to it.
struct SidebarMergedRows {
    let projects: [MergedProject]
    private let memberToMerged: [String: String]
    private let rowsByProject: [String: [WorktreePanes]]
    private let availabilityByRow: [String: HostAvailability]
    private let availabilityByMember: [String: HostAvailability]

    /// `remoteRows` holds each connected host's rows. Rows a host relays from a
    /// third machine are left out: the Mac only lists hosts it's paired with.
    static func make(projects: [SidebarProject], localRows: [WorktreePanes], remoteRows: [WorktreePanes],
                     localDeviceID: RemoteDeviceID?, availability: @escaping (SidebarProject) -> HostAvailability) -> SidebarMergedRows {
        let rows = localRows + remoteRows.filter { ($0.origin?.relayDepth ?? 0) == 0 }
        let known = Set(projects.map(\.id))
        let inferred = SidebarProjection.projects(rows).filter { !known.contains($0.id) }
        let all = projects + inferred
        let merged = ProjectMerge.merge(all, availability: availability, localDeviceID: localDeviceID)
        let memberToMerged = ProjectMerge.memberToMergedID(merged)
        var grouped: [String: [WorktreePanes]] = [:]
        var rowAvailability: [String: HostAvailability] = [:]
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for row in rows {
            let member = SidebarProjection.projectID(row)
            grouped[memberToMerged[member] ?? member, default: []].append(row)
            rowAvailability[MergedWorktreeList.identity(row)] = byID[member].map(availability) ?? .reachable
        }
        return SidebarMergedRows(projects: merged, memberToMerged: memberToMerged, rowsByProject: grouped,
                                 availabilityByRow: rowAvailability, availabilityByMember: byID.mapValues(availability))
    }

    /// What a row says after its name. Sleeping temporary rows don't name the
    /// host, in keeping with hosts not mattering while scanning the list.
    static func hostText(_ row: MergedWorktreeRow, isLocal: Bool) -> String? {
        let host = isLocal ? "This Mac" : row.hostLabel
        if row.availability == .asleep { return row.showsHostLabel ? "\(host) · asleep" : "asleep" }
        return row.showsHostLabel ? host : nil
    }

    static func removeTitle(hostLabel: String, isOnSeveralHosts: Bool) -> String {
        isOnSeveralHosts ? "Remove from \(hostLabel)…" : "Remove Repository"
    }

    static func pullTitle(hostLabel: String, isOnSeveralHosts: Bool) -> String {
        isOnSeveralHosts ? "Pull Default Branch on \(hostLabel)" : "Pull Default Branch"
    }

    /// Hosts of this project that can't be reached or woken, whose rows are hidden.
    func offlineHosts(for projectID: String) -> [String] {
        var seen: Set<String> = []
        return (project(id: projectID)?.members ?? []).compactMap { member -> String? in
            guard availabilityByMember[member.id] == .offline, let label = member.owner?.deviceLabel,
                  seen.insert(label).inserted else { return nil }
            return label
        }
    }

    func availability(ofMember id: String) -> HostAvailability {
        availabilityByMember[id] ?? .offline
    }

    func project(id: String?) -> MergedProject? {
        projects.first { $0.id == id }
    }

    /// Selection may hold a member id from before merging, or from a row just
    /// opened. Nil means no project matches it any more.
    func selectedProjectID(for selected: String?) -> String? {
        guard let selected else { return nil }
        if let merged = memberToMerged[selected] { return merged }
        return project(id: selected)?.id
    }

    func mergedID(forMember member: String) -> String {
        memberToMerged[member] ?? member
    }

    func rekeyed(_ counts: [String: Int]) -> [String: Int] {
        var result: [String: Int] = [:]
        for (member, count) in counts { result[mergedID(forMember: member), default: 0] += count }
        return result
    }

    /// `frozenOrder` holds rows still while a report is open, so a row doesn't
    /// move out from under its popover when activity arrives.
    func sections(for projectID: String, frozenOrder: [String]? = nil) -> (pinned: [MergedWorktreeNode], temporary: [MergedWorktreeRow]) {
        let isOnSeveralHosts = project(id: projectID)?.isOnSeveralHosts ?? false
        var result = MergedWorktreeList.build(rows: rowsByProject[projectID] ?? [],
            availability: { availabilityByRow[MergedWorktreeList.identity($0)] ?? .reachable },
            projectIsOnSeveralHosts: isOnSeveralHosts)
        if let frozenOrder {
            let positions = Dictionary(frozenOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
            result.temporary = result.temporary.enumerated().sorted {
                let left = positions[$0.element.id] ?? frozenOrder.count + $0.offset
                let right = positions[$1.element.id] ?? frozenOrder.count + $1.offset
                return left < right
            }.map(\.element)
        }
        return result
    }

    /// Displayed order, with folders flattened.
    func flattenedRows(for projectID: String) -> [MergedWorktreeRow] {
        func flatten(_ nodes: [MergedWorktreeNode]) -> [MergedWorktreeRow] {
            nodes.flatMap { node -> [MergedWorktreeRow] in
                switch node {
                case .row(let row): return [row]
                case .folder(_, _, let children): return flatten(children)
                }
            }
        }
        let section = sections(for: projectID)
        return flatten(section.pinned) + section.temporary
    }

    enum PinnedMove: Equatable {
        /// Rank writes, each sent to the row's own host.
        case ranks([PinnedRankWrite])
        /// A row on an older host, which only understands moves within itself.
        case legacy(source: MergedWorktreeRow, target: MergedWorktreeRow, after: Bool)
    }

    struct PinnedRankWrite: Equatable {
        let row: MergedWorktreeRow
        let rank: String
    }

    /// Drags stay among one folder's rows, as they always have (`LAYOUT-2.34`).
    func pinnedMove(source: String, target: String, after: Bool, projectID: String,
                    isWritable: (MergedWorktreeRow) -> Bool) -> PinnedMove? {
        guard let rows = Self.siblings(of: source, in: sections(for: projectID).pinned),
              let moving = rows.first(where: { $0.id == source }), !moving.row.isMainCheckout,
              let destination = rows.first(where: { $0.id == target }) else { return nil }
        if moving.row.sidebar?.pinnedRank == nil {
            guard moving.hostID == destination.hostID, destination.row.sidebar?.pinnedRank == nil else { return nil }
            return .legacy(source: moving, target: destination, after: after)
        }
        let ranked = rows.filter { !$0.row.isMainCheckout }
        let rest = ranked.filter { $0.id != source }
        let toIndex = destination.row.isMainCheckout ? 0
            : (rest.firstIndex { $0.id == target } ?? rest.count) + (after ? 1 : 0)
        let writes = RankPlacement.move(source, toIndex: toIndex, in: ranked.map {
            RankPlacement.Row(id: $0.id, rank: $0.row.sidebar?.pinnedRank, isWritable: isWritable($0))
        })
        let byID = Dictionary(uniqueKeysWithValues: ranked.map { ($0.id, $0) })
        return .ranks(writes.compactMap { write in byID[write.id].map { PinnedRankWrite(row: $0, rank: write.rank) } })
    }

    private static func siblings(of id: String, in nodes: [MergedWorktreeNode]) -> [MergedWorktreeRow]? {
        let rows = nodes.compactMap { node -> MergedWorktreeRow? in
            if case .row(let row) = node { return row }
            return nil
        }
        if rows.contains(where: { $0.id == id }) { return rows }
        for node in nodes {
            if case .folder(_, _, let children) = node, let found = siblings(of: id, in: children) { return found }
        }
        return nil
    }

    /// The same rank and time go to every member it can reach. Empty when the
    /// project has no reachable member that stores ranks.
    func projectMove(id: String, target: String, after: Bool, changedAt: Double,
                     isReachable: (SidebarProject) -> Bool) -> [(member: SidebarProject, rank: String, changedAt: Double)] {
        let rest = projects.filter { $0.id != id }
        guard let index = rest.firstIndex(where: { $0.id == target }) else { return [] }
        let writes = RankPlacement.move(id, toIndex: index + (after ? 1 : 0), in: projects.map { project in
            RankPlacement.Row(id: project.id, rank: project.rank, isWritable: project.members.contains { $0.rank != nil && isReachable($0) })
        })
        return writes.flatMap { write -> [(member: SidebarProject, rank: String, changedAt: Double)] in
            (project(id: write.id)?.members ?? []).filter { $0.rank != nil && isReachable($0) }
                .map { (member: $0, rank: write.rank, changedAt: changedAt) }
        }
    }
}

/// Sends each repair once: a host's next report is what clears it.
struct ProjectRankRepairTracker {
    private var sent: [String: Double] = [:]

    mutating func due(_ repairs: [(member: SidebarProject, rank: String, changedAt: Double)])
        -> [(member: SidebarProject, rank: String, changedAt: Double)] {
        repairs.filter { repair in
            guard (sent[repair.member.id] ?? -.infinity) < repair.changedAt else { return false }
            sent[repair.member.id] = repair.changedAt
            return true
        }
    }
}
