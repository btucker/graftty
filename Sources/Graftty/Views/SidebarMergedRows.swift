import Foundation
import GrafttyProtocol

/// Everything the Mac sidebar shows, once projects and rows from every host
/// are merged. Rows keep their owning host so requests still route to it.
struct SidebarMergedRows {
    let projects: [MergedProject]
    private let memberToMerged: [String: String]
    private let rowsByProject: [String: [WorktreePanes]]
    private let availabilityByRow: [String: HostAvailability]

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
                                 availabilityByRow: rowAvailability)
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
}
