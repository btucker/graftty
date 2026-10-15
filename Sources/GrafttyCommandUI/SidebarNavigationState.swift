import Foundation
import Observation
import GrafttyProtocol

@Observable @MainActor
public final class SidebarNavigationState {
    public var selectedProjectID: String?
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
    private var workspace: SidebarAttentionWorkspace
    private var retainedReports: [SidebarActivityItem] = []
    private var opening: [UUID: Opening] = [:]
    private var selectionOpeningID: UUID?
    private var bannerSnapshotReceived = false
    private var bannerOccurrences: [String: SidebarAttentionOccurrence] = [:]
    private var attentionBanners: [SidebarActivityItem] = []
    public var attentionBanner: SidebarActivityItem? { attentionBanners.first }
    private let defaults: UserDefaults
    private let prefix: String
    public init(prefix: String, defaults: UserDefaults = .standard, collapsed: Bool = false) {
        self.prefix = prefix; self.defaults = defaults
        railCollapsed = defaults.object(forKey: prefix + ".collapsed") == nil ? collapsed : defaults.bool(forKey: prefix + ".collapsed")
        railExpandedWidth = SidebarLayoutPolicy.clampedRailWidth(
            (defaults.object(forKey: prefix + ".railWidth") as? Double) ?? 196)
        history = defaults.data(forKey: prefix + ".recent").flatMap { try? JSONDecoder().decode(SidebarRecentHistory.self, from: $0) } ?? .init()
        workspace = defaults.data(forKey: prefix + ".attentionWorkspace").flatMap {
            try? JSONDecoder().decode(SidebarAttentionWorkspace.self, from: $0)
        } ?? .init()
        if defaults.data(forKey: prefix + ".attentionWorkspace") == nil {
            workspace.merge(history.entries.map(\.item))
        }
        retainedReports = defaults.data(forKey: prefix + ".worktreeReports").flatMap {
            try? JSONDecoder().decode([SidebarActivityItem].self, from: $0)
        } ?? workspace.items.filter { $0.agentStop != nil }
    }
    public func opened(_ item: SidebarActivityItem) {
        updateAttentionItems([item])
        history.open(item)
        persistHistory()
        dismissAttentionBanner(item)
    }
    public func beginOpening(_ item: SidebarActivityItem) -> UUID {
        let id = UUID()
        opening[id] = Opening(item: item, previousSelection: selectedAttentionID)
        selectedAttentionID = item.id
        selectionOpeningID = id
        return id
    }
    public func finishOpening(_ id: UUID, succeeded: Bool, navigateToProject: Bool = false) {
        guard let visit = opening.removeValue(forKey: id) else { return }
        let isCurrentSelection = selectionOpeningID == id
        if succeeded {
            opened(visit.item)
            if isCurrentSelection {
                rememberedWorktrees[visit.item.projectID] = visit.item.worktreeID
                selectedProjectID = visit.item.projectID
                if navigateToProject { showProject(visit.item.projectID) }
                else { selectionOpeningID = nil }
            }
        } else if isCurrentSelection {
            selectedAttentionID = visit.previousSelection
            selectionOpeningID = nil
        }
    }
    public func worktreeContext(_ worktree: WorktreePanes) -> SidebarWorktreeContext {
        SidebarWorktreeContext(worktree: worktree, retained: workspace.items + retainedReports, isViewed: { item in
            item.occurrence?.source == .agentStop ? self.workspace.isDismissed(item) : self.hasViewed(item)
        })
    }

    public func hasViewed(_ item: SidebarActivityItem) -> Bool {
        workspace.isDismissed(item) || history.entries.contains { $0.id == item.id && $0.item.occurrence == item.occurrence }
    }
    public func isSelectedAttention(_ item: SidebarActivityItem) -> Bool {
        guard let selectedAttentionID else { return false }
        if item.id == selectedAttentionID { return true }
        return workspace.items.first { $0.id == selectedAttentionID }?.worktreeIdentity == item.worktreeIdentity
    }
    public func resetSelection() {
        selectedAttentionID = nil
        selectionOpeningID = nil
        query = ""
    }
    public func showProject(_ id: String) {
        resetSelection()
        selectedProjectID = id
        compactShowsProjects = false
    }
    public func attentionItems(live: [SidebarActivityItem], projects: [SidebarProject]) -> [SidebarActivityItem] {
        var current = workspace
        current.merge(opening.values.map(\.item))
        current.merge(live)
        var rows = current.items
        if filter != .needsYou {
            let retainedIDs = Set(rows.map(\.id))
            rows += SidebarActivityFilter.all.apply(to: live).filter {
                !retainedIDs.contains($0.id) && !current.isDismissed($0)
            }
        }
        if filter == .running {
            let runningWorktrees = Set(live.filter(\.isBusy).map(\.worktreeIdentity))
            rows = rows.filter { $0.isBusy && runningWorktrees.contains($0.worktreeIdentity) }
        }
        rows = SidebarAttentionWorkspace.newestFirst(SidebarAttentionWorkspace.cards(from: rows))
        // Search filters the newest-first order without re-ranking matches.
        let matching = Set(SidebarActivityFilter.all.apply(to: rows, query: query).map(\.id))
        // Mobile shares navigation storage across hosts. Keep other hosts' cards
        // stored without offering routes through the currently connected host.
        let projectIDs = Set(projects.map(\.id))
        return rows.filter { matching.contains($0.id) && projectIDs.contains($0.projectID) }
    }
    public func updateAttentionItems(_ live: [SidebarActivityItem]) {
        retainReports(live)
        observeAttentionBanners(live)
        pruneAttentionBanners(live: live)
        var next = workspace
        next.merge(live)
        storeWorkspace(next)
    }

    private func observeAttentionBanners(_ live: [SidebarActivityItem]) {
        var incoming: [SidebarActivityItem] = []
        for item in SidebarActivityFilter.all.apply(to: live).reversed() where item.needsAttention {
            guard let occurrence = item.occurrence else { continue }
            if let previous = bannerOccurrences[item.id] {
                if previous == occurrence { continue }
                if let timestamp = occurrence.timestamp, let previousTimestamp = previous.timestamp,
                   timestamp <= previousTimestamp { continue }
            }
            bannerOccurrences[item.id] = occurrence
            if bannerSnapshotReceived, !item.isBusy, !hasViewed(item) {
                incoming.append(item)
            }
        }
        bannerSnapshotReceived = true
        attentionBanners = SidebarAttentionWorkspace.cards(from: attentionBanners + incoming)
    }

    public func dismissAttentionBanner(_ item: SidebarActivityItem) {
        attentionBanners.removeAll { $0.id == item.id && $0.occurrence == item.occurrence }
    }

    private func pruneAttentionBanners(live: [SidebarActivityItem], authoritativeProjectIDs: Set<String> = []) {
        let current = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        attentionBanners = attentionBanners.compactMap { item in
            guard !hasViewed(item) else { return nil }
            guard let pending = current[item.id] else {
                return authoritativeProjectIDs.contains(item.projectID) ? nil : item
            }
            if pending.occurrence != item.occurrence,
               let timestamp = pending.occurrence?.timestamp, let queuedTimestamp = item.occurrence?.timestamp,
               timestamp <= queuedTimestamp { return item }
            return pending.needsAttention && !pending.isBusy && pending.occurrence == item.occurrence ? pending : nil
        }
    }

    public func beginOpeningAttentionBanner(_ item: SidebarActivityItem, projects: [SidebarProject],
                                            items: [SidebarActivityItem]) -> UUID {
        updateAttentionItems(items)
        showProject(item.projectID)
        return beginOpening(item)
    }
    private func storeWorkspace(_ next: SidebarAttentionWorkspace) {
        guard next != workspace else { return }
        workspace = next
        defaults.set(try? JSONEncoder().encode(next), forKey: prefix + ".attentionWorkspace")
    }

    private func retainReports(_ items: [SidebarActivityItem], worktrees: [WorktreePanes]? = nil,
                               authoritativeProjectIDs: Set<String> = []) {
        var next = retainedReports
        for item in items where item.agentStop != nil {
            if let index = next.firstIndex(where: { $0.id == item.id }) {
                if item.agentStop!.timestamp >= (next[index].agentStop?.timestamp ?? -.infinity) { next[index] = item }
            } else { next.append(item) }
        }
        if let worktrees {
            next.removeAll { item in
                authoritativeProjectIDs.contains(item.projectID) && !worktrees.contains {
                    SidebarWorktreeContext.matchesRetainedReport(item, worktree: $0)
                }
            }
        }
        guard next != retainedReports else { return }
        retainedReports = next
        defaults.set(try? JSONEncoder().encode(next), forKey: prefix + ".worktreeReports")
    }

    public func reconcile(worktrees: [WorktreePanes], projects: [SidebarProject], authoritativeProjectIDs: Set<String>? = nil) {
        observeAttentionBanners(SidebarProjection.activity(worktrees))
        let availableProjectIDs = Set(projects.filter(\.isAvailable).map(\.id))
            .intersection(authoritativeProjectIDs ?? Set(projects.map(\.id)))
        retainReports(worktrees.map { worktreeContext($0).item }, worktrees: worktrees,
                      authoritativeProjectIDs: availableProjectIDs)
        pruneAttentionBanners(live: SidebarProjection.activity(worktrees), authoritativeProjectIDs: availableProjectIDs)
        var cards = workspace
        cards.reconcile(worktrees: worktrees, availableProjectIDs: availableProjectIDs)
        let deletedIDs = Set(workspace.items.map(\.id)).subtracting(cards.items.map(\.id))
        attentionBanners.removeAll { deletedIDs.contains($0.id) }
        opening = opening.filter { !deletedIDs.contains($0.value.item.id) }
        if let selectedAttentionID, deletedIDs.contains(selectedAttentionID) {
            self.selectedAttentionID = nil
            selectionOpeningID = nil
        }
        storeWorkspace(cards)
        var next = history
        next.reconcile(worktrees: worktrees, availableProjectIDs: availableProjectIDs)
        if next != history { history = next; persistHistory() }
    }
    public func forget(_ id: String) {
        var next = workspace
        let target = next.items.first { $0.id == id }
        let forgotten = next.items.filter { $0.worktreeIdentity == target?.worktreeIdentity }.map(\.id)
        next.dismiss(id)
        storeWorkspace(next)
        attentionBanners.removeAll { $0.worktreeIdentity == target?.worktreeIdentity }
        for forgottenID in forgotten { history.remove(forgottenID) }
        persistHistory()
    }
    public func dismissRequest(in context: SidebarWorktreeContext) {
        updateAttentionItems(context.pending)
        var next = workspace
        for item in context.pending {
            next.dismissOccurrence(item)
            dismissAttentionBanner(item)
        }
        storeWorkspace(next)
    }
    private func persistHistory() { defaults.set(try? JSONEncoder().encode(history), forKey: prefix + ".recent") }
}
