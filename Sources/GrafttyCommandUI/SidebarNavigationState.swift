import Foundation
import Observation
import GrafttyProtocol

/// @spec LAYOUT-2.75: When Attention mode opens, the application shall include every project, order projects by pending attention with direct requests ranked first, and keep that order fixed until Attention closes.
@Observable @MainActor
public final class SidebarNavigationState {
    public var selectedProjectID: String?
    public var showsAttention = false
    private var attentionProjectOrder: [String] = []
    public var filter: SidebarActivityFilter = .needsYou
    public var query = ""
    public var rememberedWorktrees: [String: String] = [:]
    public var scrollAnchors: [String: String] = [:]
    public var compactShowsProjects = true
    public var railCollapsed: Bool { didSet { defaults.set(railCollapsed, forKey: prefix + ".collapsed") } }
    public var railExpandedWidth: Double {
        didSet { defaults.set(railExpandedWidth, forKey: prefix + ".railWidth") }
    }
    public var railWidth: Double {
        SidebarLayoutPolicy.railWidth(collapsed: railCollapsed, expandedWidth: railExpandedWidth)
    }
    public private(set) var history: SidebarRecentHistory
    public private(set) var selectedAttentionID: String?
    private struct Opening {
        let item: SidebarActivityItem
        let previousSelection: String?
    }
    private var opening: [UUID: Opening] = [:]
    private var selectionOpeningID: UUID?
    private let defaults: UserDefaults
    private let prefix: String
    public init(prefix: String, defaults: UserDefaults = .standard, collapsed: Bool = false) {
        self.prefix = prefix; self.defaults = defaults
        railCollapsed = defaults.object(forKey: prefix + ".collapsed") == nil ? collapsed : defaults.bool(forKey: prefix + ".collapsed")
        railExpandedWidth = SidebarLayoutPolicy.clampedRailWidth(
            (defaults.object(forKey: prefix + ".railWidth") as? Double) ?? 196)
        history = defaults.data(forKey: prefix + ".recent").flatMap { try? JSONDecoder().decode(SidebarRecentHistory.self, from: $0) } ?? .init()
    }
    public func opened(_ item: SidebarActivityItem) {
        history.open(item)
        persistHistory()
    }
    public func beginOpening(_ item: SidebarActivityItem) -> UUID {
        let id = UUID()
        opening[id] = Opening(item: item, previousSelection: selectedAttentionID)
        selectedAttentionID = item.id
        selectionOpeningID = id
        return id
    }
    public func finishOpening(_ id: UUID, succeeded: Bool) {
        guard let visit = opening.removeValue(forKey: id) else { return }
        let isCurrentSelection = selectionOpeningID == id
        if succeeded {
            opened(visit.item)
            if isCurrentSelection {
                rememberedWorktrees[visit.item.projectID] = visit.item.worktreeID
                showProject(visit.item.projectID)
            }
        } else if isCurrentSelection {
            selectedAttentionID = visit.previousSelection
            selectionOpeningID = nil
        }
    }
    public func hasViewed(_ item: SidebarActivityItem) -> Bool {
        history.entries.contains { $0.id == item.id && $0.item.occurrence == item.occurrence }
    }
    public func enterAttention(projects: [SidebarProject], items: [SidebarActivityItem]) {
        selectionOpeningID = nil
        let pending = items.filter { $0.needsAttention && !hasViewed($0) }
        let counts = Dictionary(grouping: pending, by: \.projectID).mapValues { group in
            let direct = group.filter { $0.agentStop?.recap?.need != nil || $0.occurrence?.source == .userNotify }.count
            return (direct: direct, total: group.count)
        }
        let positions = Dictionary(projects.enumerated().map { ($1.id, $0) }, uniquingKeysWith: min)
        attentionProjectOrder = projects.map(\.id).sorted { left, right in
            let a = counts[left] ?? (0, 0), b = counts[right] ?? (0, 0)
            if a.direct != b.direct { return a.direct > b.direct }
            if a.total != b.total { return a.total > b.total }
            return positions[left, default: .max] < positions[right, default: .max]
        }
        showsAttention = true
        query = ""
    }
    public func leaveAttention() {
        showsAttention = false
        selectionOpeningID = nil
        attentionProjectOrder = []
        query = ""
    }
    public func showProject(_ id: String) {
        leaveAttention()
        selectedProjectID = id
        compactShowsProjects = false
    }
    public func orderedProjects(_ projects: [SidebarProject]) -> [SidebarProject] {
        guard showsAttention else { return projects }
        let positions = Dictionary(attentionProjectOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        return projects.enumerated().sorted {
            let left = positions[$0.element.id, default: attentionProjectOrder.count + $0.offset]
            let right = positions[$1.element.id, default: attentionProjectOrder.count + $1.offset]
            return left < right
        }.map(\.element)
    }
    public func attentionItems(live: [SidebarActivityItem], projects: [SidebarProject]) -> [SidebarActivityItem] {
        if filter == .running { return filter.apply(to: live, query: query) }
        let projectIDs = Set(projects.map(\.id))
        var retained = Dictionary(history.entries.map { ($0.id, $0.item) }, uniquingKeysWith: { first, _ in first })
        for visit in opening.values {
            if retained[visit.item.id] == nil || (visit.item.occurrence?.timestamp ?? .distantPast) >= (retained[visit.item.id]?.occurrence?.timestamp ?? .distantPast) {
                retained[visit.item.id] = visit.item
            }
        }
        for item in live {
            // A busy update after acknowledgement must not replace the viewed
            // occurrence. A fresh request at the same target takes its place.
            if item.occurrence != nil || retained[item.id] == nil { retained[item.id] = item }
            retained[item.id]?.prBadge = item.prBadge
        }
        return filter.apply(to: retained.values.filter { projectIDs.contains($0.projectID) }, query: query)
    }
    public func reconcile(worktrees: [WorktreePanes], projects: [SidebarProject]) {
        var next = history
        next.reconcile(worktrees: worktrees, availableProjectIDs: Set(projects.filter(\.isAvailable).map(\.id)))
        if next != history { history = next; persistHistory() }
    }
    public func forget(_ id: String) { history.remove(id); persistHistory() }
    private func persistHistory() { defaults.set(try? JSONEncoder().encode(history), forKey: prefix + ".recent") }
}
