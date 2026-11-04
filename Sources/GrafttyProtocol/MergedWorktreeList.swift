import Foundation

public struct MergedWorktreeRow: Sendable, Equatable, Identifiable {
    public let row: WorktreePanes
    public let hostID: RemoteDeviceID?
    public let hostLabel: String
    public let showsHostLabel: Bool
    public let availability: HostAvailability
    /// The full name, such as `spikes/old-relay`.
    public var relativeName: String { row.displayName }
    /// The name inside its folder. Equals `relativeName` when not in a folder.
    public let leafName: String
    public var id: String { MergedWorktreeList.identity(row) }
}

public indirect enum MergedWorktreeNode: Sendable, Equatable, Identifiable {
    case row(MergedWorktreeRow)
    case folder(id: String, name: String, children: [MergedWorktreeNode])

    public var id: String {
        switch self {
        case .row(let row): return row.id
        case .folder(let id, _, _): return "folder:" + id
        }
    }
}

extension Array where Element == MergedWorktreeNode {
    /// Every row in displayed order, with folders flattened.
    public var flattenedRows: [MergedWorktreeRow] {
        flatMap { node -> [MergedWorktreeRow] in
            switch node {
            case .row(let row): return [row]
            case .folder(_, _, let children): return children.flattenedRows
            }
        }
    }
}

public enum MergedWorktreeList {
    /// Stable across routes: a relayed row's path is an alias, its metadata id isn't.
    public static func identity(_ row: WorktreePanes) -> String {
        "\(row.origin?.deviceID.value ?? "connected")\u{0}\(row.sidebar?.id ?? row.path)"
    }

    /// Keeps each worktree once, on its most direct route, in first-seen order.
    public static func deduplicated(_ rows: [WorktreePanes]) -> [WorktreePanes] {
        var best: [String: WorktreePanes] = [:]
        var order: [String] = []
        for row in rows {
            let key = identity(row)
            guard let existing = best[key] else { best[key] = row; order.append(key); continue }
            if (row.origin?.relayDepth ?? 0) < (existing.origin?.relayDepth ?? 0) { best[key] = row }
        }
        return order.compactMap { best[$0] }
    }

    public static func build(rows: [WorktreePanes], availability: (WorktreePanes) -> HostAvailability,
                             projectIsOnSeveralHosts: Bool) -> (pinned: [MergedWorktreeNode], temporary: [MergedWorktreeRow]) {
        let unique = deduplicated(rows)
        let nameCounts = Dictionary(unique.map { ($0.displayName, 1) }, uniquingKeysWith: +)
        func merged(_ row: WorktreePanes, pinned: Bool) -> MergedWorktreeRow {
            let clashes = (nameCounts[row.displayName] ?? 0) > 1
            return MergedWorktreeRow(row: row, hostID: row.origin?.deviceID, hostLabel: row.origin?.deviceLabel ?? "",
                                     showsHostLabel: projectIsOnSeveralHosts && (pinned || clashes),
                                     availability: availability(row), leafName: row.displayName)
        }
        let isPinned = { (row: WorktreePanes) in row.isMainCheckout || row.sidebar?.isPinned == true }
        let temporary = sortedByActivity(unique.filter { !isPinned($0) }).map { merged($0, pinned: false) }
        let pinnedRows = unique.filter(isPinned)
        let defaults = pinnedRows.filter(\.isMainCheckout).sorted(by: hostThenPath)
        let others = sortedByRank(pinnedRows.filter { !$0.isMainCheckout })
        let leading = defaults.map { MergedWorktreeNode.row(merged($0, pinned: true)) }
        let items = others.map { row in
            Item(row: merged(row, pinned: true), components: folderComponents(row))
        }
        return (leading + nodes(items, prefix: ""), temporary)
    }

    private static func hostThenPath(_ left: WorktreePanes, _ right: WorktreePanes) -> Bool {
        let leftHost = left.origin?.deviceLabel ?? ""
        let rightHost = right.origin?.deviceLabel ?? ""
        let comparison = leftHost.localizedCaseInsensitiveCompare(rightHost)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return left.path < right.path
    }

    private static func sortedByActivity(_ rows: [WorktreePanes]) -> [WorktreePanes] {
        let live = rows.filter { $0.state != .stale }
        let active = live.filter { $0.sidebar?.activityTime != nil }.sorted {
            let left = $0.sidebar!.activityTime!, right = $1.sidebar!.activityTime!
            return left == right ? hostThenPath($0, $1) : left > right
        }
        return active + live.filter { $0.sidebar?.activityTime == nil } + rows.filter { $0.state == .stale }
    }

    private static func sortedByRank(_ rows: [WorktreePanes]) -> [WorktreePanes] {
        func rank(_ row: WorktreePanes) -> String? {
            row.sidebar?.pinnedRank.flatMap { FractionalRank.isValid($0) ? $0 : nil }
        }
        let ranked = rows.filter { rank($0) != nil }.sorted {
            let left = rank($0)!, right = rank($1)!
            return left == right ? hostThenPath($0, $1) : left < right
        }
        return ranked + rows.filter { rank($0) == nil }
    }

    private struct Item {
        var row: MergedWorktreeRow
        var components: [FolderComponent]
    }

    private struct FolderComponent: Equatable {
        var id: String
        var name: String
    }

    /// A managed worktree's folders come from its relative name, so a folder
    /// a host published and one only visible across hosts look the same. Folders
    /// inferred from absolute paths describe one machine's disk and stay per host.
    private static func folderComponents(_ row: WorktreePanes) -> [FolderComponent] {
        let ids = row.sidebar?.folderIDs ?? []
        if ids.contains(where: { $0.hasPrefix("/") || $0.hasPrefix("~") }), let folders = row.sidebar?.folders {
            let host = row.origin?.deviceLabel ?? ""
            return folders.enumerated().map { index, name in
                let id = index < ids.count ? ids[index] : name
                return FolderComponent(id: "\(row.origin?.deviceID.value ?? ""):\(id)", name: index == 0 ? "\(name) · \(host)" : name)
            }
        }
        let parts = row.displayName.split(separator: "/").map(String.init).dropLast()
        var path: [String] = []
        return parts.map { part in
            path.append(part)
            return FolderComponent(id: path.joined(separator: "/"), name: part)
        }
    }

    private static func nodes(_ items: [Item], prefix: String) -> [MergedWorktreeNode] {
        let counts = Dictionary(items.compactMap { $0.components.first.map { ($0.id, 1) } }, uniquingKeysWith: +)
        var emitted: Set<String> = []
        var result: [MergedWorktreeNode] = []
        for item in items {
            guard let first = item.components.first, (counts[first.id] ?? 0) >= 2 else {
                var row = item.row
                row = MergedWorktreeRow(row: row.row, hostID: row.hostID, hostLabel: row.hostLabel, showsHostLabel: row.showsHostLabel,
                                        availability: row.availability, leafName: leafName(row.row, under: prefix))
                result.append(.row(row))
                continue
            }
            guard emitted.insert(first.id).inserted else { continue }
            let children = items.filter { $0.components.first?.id == first.id }.map {
                Item(row: $0.row, components: Array($0.components.dropFirst()))
            }
            result.append(.folder(id: first.id, name: first.name, children: nodes(children, prefix: first.id + "/")))
        }
        return result
    }

    private static func leafName(_ row: WorktreePanes, under prefix: String) -> String {
        row.displayName.hasPrefix(prefix) ? String(row.displayName.dropFirst(prefix.count)) : row.displayName
    }
}
