import Foundation

public enum SidebarLayoutPolicy {
    public static let projectRailSettingKey = "showProjectRail"

    public static func projectFilter(selectedID: String?, showsProjectRail: Bool) -> String? {
        showsProjectRail ? selectedID : nil
    }

    public static func clampedRailWidth(_ width: Double) -> Double {
        width.isFinite ? min(280, max(128, width)) : 196
    }

    public static func railWidth(collapsed: Bool, expandedWidth: Double) -> Double {
        collapsed ? 64 : clampedRailWidth(expandedWidth)
    }

    public static func resizedRail(proposedWidth: Double, expandedWidth: Double) -> (collapsed: Bool, expandedWidth: Double) {
        let collapsed = proposedWidth < 112
        return (collapsed, clampedRailWidth(collapsed ? expandedWidth : proposedWidth))
    }

    public static func railCollapsed(preference: Bool, isMobile: Bool, windowWidth: Double) -> Bool {
        preference || (isMobile && windowWidth < 1100)
    }
}

/// Stable presentation identity is separate from the live, opaque management route.
public struct SidebarProject: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var repositoryID: String
    public var name: String
    public var owner: WorktreeOrigin?
    public var iconRevision: String?
    public var initials: String?
    public var isAvailable: Bool
    public var supportsWorktreeEditing: Bool?

    public init(id: String, repositoryID: String, name: String, owner: WorktreeOrigin? = nil,
                iconRevision: String? = nil, initials: String? = nil, isAvailable: Bool = true, supportsWorktreeEditing: Bool? = nil) {
        self.id = id; self.repositoryID = repositoryID; self.name = name; self.owner = owner
        self.iconRevision = iconRevision; self.initials = initials; self.isAvailable = isAvailable; self.supportsWorktreeEditing = supportsWorktreeEditing
    }

    public var displayInitials: String {
        if let initials, !initials.isEmpty { return String(initials.prefix(3)) }
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return words.count > 1 ? String(words.prefix(2).compactMap(\.first)).uppercased()
            : String(name.prefix(2)).uppercased()
    }

    public func ownerSubtitle(localDeviceID: RemoteDeviceID?) -> String? {
        let host = owner.flatMap { $0.deviceID == localDeviceID ? nil : $0.deviceLabel }
        let parts = [host, isAvailable ? nil : "Offline"].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// FNV-1a, rather than Swift's process-randomized Hasher, keeps colors stable.
    public var colorIndex: Int {
        Int(id.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 } % 8)
    }
}

public struct SidebarSnapshot: Codable, Sendable, Equatable {
    public var projects: [SidebarProject]
    public var supportsNavigationEditing: Bool
    public init(projects: [SidebarProject], supportsNavigationEditing: Bool = true) {
        self.projects = projects; self.supportsNavigationEditing = supportsNavigationEditing
    }
}

/// The latest completed agent turn not yet viewed in its worktree.
/// The numeric timestamp retains precision across JSON date strategies.
public struct SidebarAgentStop: Codable, Sendable, Hashable {
    public var agentName: String
    public var timestamp: Double
    public init(agentName: String, stoppedAt: Date) {
        self.agentName = agentName
        self.timestamp = stoppedAt.timeIntervalSinceReferenceDate
    }
    public var stoppedAt: Date { Date(timeIntervalSinceReferenceDate: timestamp) }
    public var title: String { "\(agentName) stopped" }
    public var occurrence: SidebarAttentionOccurrence {
        .init(timestamp: stoppedAt, text: title, source: .agentStop)
    }
    public func elapsedDescription(at now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(stoppedAt))
        guard seconds.isFinite, seconds >= 60 else { return "just now" }
        let (duration, unit): (Double, String) = seconds >= 86400 ? (86400, "day")
            : seconds >= 3600 ? (3600, "hour") : (60, "minute")
        let count = Int(min(seconds / duration, Double(Int.max / 2)))
        return "\(count) \(unit)\(count == 1 ? "" : "s") ago"
    }
}

public struct SidebarWorktreeMetadata: Codable, Sendable, Hashable {
    public var id: String
    public var projectID: String
    public var folders: [String]
    public var folderIDs: [String]?
    public var paneIDs: [String: String]?
    public var attentionTimestamps: [String: Double]?
    public var unseenAgentStop: SidebarAgentStop?
    public init(id: String, projectID: String, folders: [String] = [], folderIDs: [String]? = nil, paneIDs: [String: String]? = nil, attentionTimestamps: [String: Double]? = nil, unseenAgentStop: SidebarAgentStop? = nil) {
        self.id = id; self.projectID = projectID; self.folders = folders; self.folderIDs = folderIDs; self.paneIDs = paneIDs; self.attentionTimestamps = attentionTimestamps; self.unseenAgentStop = unseenAgentStop
    }

    public func folderID(at depth: Int) -> String? {
        guard folders.indices.contains(depth) else { return nil }
        if let folderIDs, folderIDs.indices.contains(depth) { return folderIDs[depth] }
        return folders.prefix(depth + 1).joined(separator: "/")
    }
}

public struct SidebarProjectOrder: Codable, Sendable, Equatable {
    public var ids: [String]
    public init(ids: [String] = []) { self.ids = ids }
    public mutating func discover(_ discovered: [String]) {
        var known = Set(ids)
        for id in discovered where known.insert(id).inserted { ids.append(id) }
    }
    @discardableResult public mutating func move(_ id: String, relativeTo target: String, after: Bool) -> Bool {
        guard id != target, ids.contains(id), ids.contains(target) else { return false }
        let old = ids
        ids.removeAll { $0 == id }
        guard let index = ids.firstIndex(of: target) else { return false }
        ids.insert(id, at: index + (after ? 1 : 0))
        return ids != old
    }
    public func sorted(_ projects: [SidebarProject]) -> [SidebarProject] {
        var order = self; order.discover(projects.map(\.id))
        let indices = Dictionary(order.ids.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        return projects.sorted { indices[$0.id, default: .max] < indices[$1.id, default: .max] }
    }
}

public struct SidebarAttentionOccurrence: Codable, Sendable, Hashable {
    public var timestamp: Date?
    public var text: String
    public var source: AttentionSource?
    public init(timestamp: Date?, text: String, source: AttentionSource?) {
        self.timestamp = timestamp; self.text = text; self.source = source
    }
    private enum CodingKeys: String, CodingKey { case timestamp, timestampExact, text, source }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try c.decodeIfPresent(Double.self, forKey: .timestampExact).map(Date.init(timeIntervalSinceReferenceDate:))
            ?? c.decodeIfPresent(Date.self, forKey: .timestamp)
        text = try c.decode(String.self, forKey: .text)
        source = try c.decodeIfPresent(AttentionSource.self, forKey: .source)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(timestamp, forKey: .timestamp)
        try c.encodeIfPresent(timestamp?.timeIntervalSinceReferenceDate, forKey: .timestampExact)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(source, forKey: .source)
    }
    public func matches(timestamp: Date?, text: String?, source: AttentionSource?) -> Bool {
        self.timestamp == timestamp && self.text == text && self.source == source
    }
}

public struct SidebarActivityItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var projectID: String
    public var worktreeID: String
    public var paneID: String?
    public var projectName: String
    public var worktreeName: String
    public var title: String
    public var occurrence: SidebarAttentionOccurrence?
    public var isBusy: Bool
    public var agentStop: SidebarAgentStop?
    public init(id: String, projectID: String, worktreeID: String, paneID: String?,
                projectName: String, worktreeName: String, title: String,
                occurrence: SidebarAttentionOccurrence?, isBusy: Bool, agentStop: SidebarAgentStop? = nil) {
        self.id = id; self.projectID = projectID; self.worktreeID = worktreeID; self.paneID = paneID
        self.projectName = projectName; self.worktreeName = worktreeName; self.title = title
        self.occurrence = occurrence; self.isBusy = isBusy; self.agentStop = agentStop
    }
    public var needsAttention: Bool { occurrence != nil && occurrence?.source != .commandFinished }
}

public enum SidebarActivityFilter: String, CaseIterable, Codable, Sendable {
    case needsYou, running, all
    public var title: String {
        switch self { case .needsYou: return "Needs you"; case .running: return "Running"; case .all: return "All activity" }
    }
    public func apply(to items: [SidebarActivityItem], query: String = "") -> [SidebarActivityItem] {
        items.filter { item in
            let matches: Bool
            switch self { case .needsYou: matches = item.needsAttention
            case .running: matches = item.isBusy
            case .all: matches = true }
            return matches && (query.isEmpty || "\(item.projectName) \(item.worktreeName) \(item.title)".localizedCaseInsensitiveContains(query))
        }.sorted {
            let lhs = $0.occurrence?.timestamp ?? .distantPast
            let rhs = $1.occurrence?.timestamp ?? .distantPast
            return lhs == rhs ? $0.id < $1.id : lhs > rhs
        }
    }
}

/// @spec LAYOUT-2.58: While projects and worktrees are displayed, the application shall show working-agent counts in green for each project and matching pending-attention counts in orange for each project and worktree, excluding viewed history and command-finished markers.
public struct SidebarActivityCounts: Sendable {
    public private(set) var workingByProject: [String: Int] = [:]
    public private(set) var attentionByProject: [String: Int] = [:]
    public private(set) var attentionByWorktree: [String: Int] = [:]

    public init(items: [SidebarActivityItem]) {
        var seen: Set<String> = []
        for item in items where seen.insert(item.id).inserted {
            if item.isBusy { workingByProject[item.projectID, default: 0] += 1 }
            if item.needsAttention {
                attentionByProject[item.projectID, default: 0] += 1
                attentionByWorktree[item.worktreeID, default: 0] += 1
            }
        }
    }
}

/// @spec LAYOUT-2.39: When an attention target is opened, the application shall retain the last 20 distinct recently viewed targets locally across relaunches, newest first, without counting them as pending requests.
public struct SidebarRecentHistory: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable, Identifiable {
        public var item: SidebarActivityItem
        public var viewedAt: Date
        public var id: String { item.id }
    }
    public private(set) var entries: [Entry] = []
    public init() {}
    public mutating func open(_ item: SidebarActivityItem, at date: Date = Date()) {
        entries.removeAll { $0.id == item.id }
        entries.insert(Entry(item: item, viewedAt: date), at: 0)
        entries = Array(entries.prefix(20))
    }
    public mutating func reconcile(worktrees: [WorktreePanes], availableProjectIDs: Set<String>) {
        let targets = worktrees.flatMap { wt -> [(String, WorktreePanes, String?)] in
            let stable = wt.sidebar?.id ?? "\(SidebarProjection.projectID(wt)):\(wt.path)"
            let panes: [(String, WorktreePanes, String?)]
            if wt.state == .closed, let identities = wt.sidebar?.paneIDs {
                panes = identities.map { ("\(stable):\($0.value)", wt, $0.key) }
            } else {
                panes = (wt.layout?.leaves ?? []).map {
                    ("\(stable):\(wt.sidebar?.paneIDs?[$0.sessionName] ?? $0.sessionName)", wt, $0.sessionName)
                }
            }
            return [(stable, wt, nil), (stable + ":stop", wt, nil)] + panes
        }
        let current = Dictionary(targets.map { ($0.0, ($0.1, $0.2)) }, uniquingKeysWith: { first, _ in first })
        entries = entries.compactMap { entry in
            guard let (worktree, pane) = current[entry.id] else {
                return availableProjectIDs.contains(entry.item.projectID) ? nil : entry
            }
            var updated = entry
            updated.item.worktreeID = worktree.path
            updated.item.paneID = pane
            updated.item.projectName = worktree.repoDisplayName
            updated.item.worktreeName = worktree.displayBranch
            return updated
        }
    }
    public mutating func remove(_ id: String) { entries.removeAll { $0.id == id } }
}

public enum SidebarProjection {
    public static func projectID(_ worktree: WorktreePanes) -> String {
        worktree.sidebar?.projectID ?? "\(worktree.origin?.deviceID.value ?? "connected"):\(worktree.repositoryID ?? worktree.repoDisplayName)"
    }
    public static func projects(_ worktrees: [WorktreePanes]) -> [SidebarProject] {
        var seen: Set<String> = []
        return worktrees.compactMap { wt in
            let id = projectID(wt)
            guard seen.insert(id).inserted else { return nil }
            return SidebarProject(id: id, repositoryID: wt.repositoryID ?? wt.repoDisplayName,
                                  name: wt.repoDisplayName, owner: wt.origin, supportsWorktreeEditing: false)
        }
    }
    public static func activity(_ worktrees: [WorktreePanes]) -> [SidebarActivityItem] {
        worktrees.flatMap { wt in
            let projectID = projectID(wt)
            let stable = wt.sidebar?.id ?? "\(projectID):\(wt.path)"
            var items: [SidebarActivityItem] = []
            if let stop = wt.sidebar?.unseenAgentStop {
                items.append(.init(id: stable + ":stop", projectID: projectID, worktreeID: wt.path, paneID: nil,
                    projectName: wt.repoDisplayName, worktreeName: wt.displayBranch, title: stop.title,
                    occurrence: stop.occurrence, isBusy: false, agentStop: stop))
            }
            if let text = wt.attentionText {
                items.append(.init(id: stable, projectID: projectID, worktreeID: wt.path, paneID: nil,
                                   projectName: wt.repoDisplayName, worktreeName: wt.displayBranch, title: text,
                                   occurrence: .init(timestamp: wt.sidebar?.attentionTimestamps?["worktree"].map(Date.init(timeIntervalSinceReferenceDate:)) ?? wt.attentionTimestamp, text: text, source: wt.attentionSource), isBusy: false))
            }
            for leaf in wt.layout?.leaves ?? [] where leaf.attentionText != nil || leaf.isBusy {
                items.append(.init(id: "\(stable):\(wt.sidebar?.paneIDs?[leaf.sessionName] ?? leaf.sessionName)", projectID: projectID, worktreeID: wt.path,
                                   paneID: leaf.sessionName, projectName: wt.repoDisplayName, worktreeName: wt.displayBranch,
                                   title: leaf.attentionText ?? leaf.displayTitle,
                                   occurrence: leaf.attentionText.map { .init(timestamp: wt.sidebar?.attentionTimestamps?[wt.sidebar?.paneIDs?[leaf.sessionName] ?? leaf.sessionName].map(Date.init(timeIntervalSinceReferenceDate:)) ?? leaf.attentionTimestamp, text: $0, source: leaf.attentionSource) },
                                   isBusy: leaf.isBusy))
            }
            return items
        }
    }
}
