import Foundation
import Observation
import GrafttyProtocol

@Observable @MainActor
public final class SidebarNavigationState {
    public var selectedProjectID: String?
    public var showsAttention = false
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
        if succeeded { opened(visit.item) }
        else if selectionOpeningID == id {
            selectedAttentionID = visit.previousSelection
            selectionOpeningID = nil
        }
    }
    public func hasViewed(_ item: SidebarActivityItem) -> Bool {
        history.entries.contains { $0.id == item.id && $0.item.occurrence == item.occurrence }
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
