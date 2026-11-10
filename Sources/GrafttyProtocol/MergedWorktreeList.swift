import Foundation

public struct MergedWorktreeRow: Sendable, Equatable, Identifiable {
    public let row: WorktreePanes
    public let hostID: RemoteDeviceID?
    public let hostLabel: String
    public let showsHostLabel: Bool
    public let availability: HostAvailability
    /// The full name, such as `spikes/old-relay`.
    public var relativeName: String { row.displayName }
    /// What the row is called in a list. Pinned agents are a flat grid, so
    /// this is always the full name.
    public var leafName: String { relativeName }
    public var id: String { MergedWorktreeList.identity(row) }
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
                             projectIsOnSeveralHosts: Bool, localDeviceID: RemoteDeviceID? = nil) -> (pinned: [MergedWorktreeRow], temporary: [MergedWorktreeRow]) {
        let unique = deduplicated(rows)
        let nameCounts = Dictionary(unique.map { ($0.displayName, 1) }, uniquingKeysWith: +)
        func merged(_ row: WorktreePanes, pinned: Bool) -> MergedWorktreeRow {
            let clashes = (nameCounts[row.displayName] ?? 0) > 1
            let isElsewhere = row.origin?.deviceID != localDeviceID
            return MergedWorktreeRow(row: row, hostID: row.origin?.deviceID, hostLabel: row.origin?.deviceLabel ?? "",
                                     showsHostLabel: projectIsOnSeveralHosts && (pinned || clashes || isElsewhere),
                                     availability: availability(row))
        }
        let isPinned = { (row: WorktreePanes) in row.isMainCheckout || row.sidebar?.isPinned == true }
        let temporary = sortedByActivity(unique.filter { !isPinned($0) }).map { merged($0, pinned: false) }
        let pinnedRows = unique.filter(isPinned)
        let defaults = pinnedRows.filter(\.isMainCheckout).sorted(by: hostThenPath)
        let others = sortedByRank(pinnedRows.filter { !$0.isMainCheckout })
        return ((defaults + others).map { merged($0, pinned: true) }, temporary)
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
}
