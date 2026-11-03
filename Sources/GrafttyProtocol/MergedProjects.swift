import Foundation

public enum HostAvailability: Sendable, Equatable {
    case reachable
    /// Unreachable, with wake details saved. Its last known rows stay visible.
    case asleep
    case offline
}

/// One project in the UI, possibly checked out on several hosts. Each member
/// keeps its own routes, so requests still go to one owning host.
public struct MergedProject: Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let members: [SidebarProject]
    public let availability: HostAvailability
    public let rank: String?
    public let rankChangedAt: Double?
    /// The member whose icon represents the project: this device's checkout
    /// if it has an icon, otherwise the first member with one.
    public let iconMember: SidebarProject?
    /// A presentation-only project for rails and lists, carrying the merged id.
    public let representative: SidebarProject

    public var isOnSeveralHosts: Bool {
        Set(members.compactMap { $0.owner?.deviceID }).count > 1
    }
}

public enum ProjectMerge {
    /// `projects` may repeat a project reached through several routes; the most
    /// direct route is kept. Output order is the shared project order.
    public static func merge(_ projects: [SidebarProject],
                             availability: (SidebarProject) -> HostAvailability,
                             localDeviceID: RemoteDeviceID?) -> [MergedProject] {
        var direct: [String: SidebarProject] = [:]
        for project in projects {
            if let existing = direct[project.id],
               (existing.owner?.relayDepth ?? 0) <= (project.owner?.relayDepth ?? 0) { continue }
            direct[project.id] = project
        }
        var seen: Set<String> = []
        var keys: [String] = []
        var groups: [String: [SidebarProject]] = [:]
        for project in projects where seen.insert(project.id).inserted {
            let key = mergedID(project)
            if groups[key] == nil { keys.append(key) }
            groups[key, default: []].append(direct[project.id] ?? project)
        }
        let nameCounts = Dictionary(keys.map { (repositoryName(groups[$0]![0]), 1) }, uniquingKeysWith: +)
        let merged = keys.map { key -> MergedProject in
            let members = groups[key]!
            let name = repositoryName(members[0])
            return build(id: key, members: members,
                         name: (nameCounts[name] ?? 0) > 1 ? qualifiedName(members[0]) : name,
                         availability: availability, localDeviceID: localDeviceID)
        }
        let ranked = merged.filter { $0.rank != nil }.sorted {
            $0.rank! == $1.rank! ? $0.id < $1.id : $0.rank! < $1.rank!
        }
        return ranked + merged.filter { $0.rank == nil }
    }

    /// Hosts holding an older order than the project's newest drag, which a
    /// device that can reach them should update.
    public static func repairs(_ merged: [MergedProject], isReachable: (SidebarProject) -> Bool)
        -> [(member: SidebarProject, rank: String, changedAt: Double)] {
        merged.flatMap { project -> [(member: SidebarProject, rank: String, changedAt: Double)] in
            guard let rank = project.rank, let changedAt = project.rankChangedAt else { return [] }
            return project.members.filter { member in
                // A member with no rank is an older host that can't store one.
                member.rank != nil && (member.rankChangedAt ?? -.infinity) < changedAt && isReachable(member)
            }.map { (member: $0, rank: rank, changedAt: changedAt) }
        }
    }

    public static func memberToMergedID(_ merged: [MergedProject]) -> [String: String] {
        var result: [String: String] = [:]
        for project in merged { for member in project.members { result[member.id] = project.id } }
        return result
    }

    private static func mergedID(_ project: SidebarProject) -> String {
        project.originKey.map { "origin:" + $0 } ?? project.id
    }

    private static func keyComponents(_ project: SidebarProject) -> [String] {
        guard let key = project.originKey else { return [] }
        return key.split(whereSeparator: { $0 == "/" || $0 == ":" }).map {
            $0.hasSuffix(".git") ? String($0.dropLast(4)) : String($0)
        }
    }

    private static func repositoryName(_ project: SidebarProject) -> String {
        keyComponents(project).last ?? project.name
    }

    private static func qualifiedName(_ project: SidebarProject) -> String {
        let parts = keyComponents(project)
        return parts.count >= 2 ? parts.suffix(2).joined(separator: "/") : repositoryName(project)
    }

    private static func build(id: String, members: [SidebarProject], name: String,
                              availability: (SidebarProject) -> HostAvailability,
                              localDeviceID: RemoteDeviceID?) -> MergedProject {
        let states = members.map(availability)
        let state: HostAvailability = states.contains(.reachable) ? .reachable
            : states.contains(.asleep) ? .asleep : .offline
        let valid = members.filter { $0.rank.map(FractionalRank.isValid) == true }
        let timed = valid.filter { $0.rankChangedAt != nil }
        let winner = timed.max { $0.rankChangedAt! < $1.rankChangedAt! }
            ?? valid.min { $0.rank! < $1.rank! }
        let hasIcon = { (project: SidebarProject) in project.iconRevision != nil || project.initials != nil }
        let local = members.first { $0.owner?.deviceID == localDeviceID && hasIcon($0) }
        let icon = local ?? members.first(where: hasIcon)
        var representative = SidebarProject(
            id: id, repositoryID: (icon ?? members[0]).repositoryID, name: name, owner: nil,
            iconRevision: icon?.iconRevision, initials: icon?.initials, accentHex: icon?.accentHex,
            isAvailable: state != .offline,
            supportsWorktreeEditing: members.contains { $0.supportsWorktreeEditing == true },
            originKey: members[0].originKey, rank: winner?.rank, rankChangedAt: winner?.rankChangedAt)
        representative.statusLabel = state == .asleep ? "Asleep" : nil
        return MergedProject(id: id, name: name, members: members, availability: state,
                             rank: winner?.rank, rankChangedAt: winner?.rankChangedAt,
                             iconMember: icon, representative: representative)
    }
}
