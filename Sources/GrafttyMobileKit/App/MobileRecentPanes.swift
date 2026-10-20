import Foundation
import GrafttyProtocol
import Observation

/// Mobile visits share the sidebar's bounded history and stable target IDs,
/// scoped by paired host so identical remote routes cannot cross connections.
@Observable @MainActor
final class MobileRecentPanes {
    struct Entry: Equatable, Identifiable {
        let hostID: UUID
        let hostLabel: String
        let visit: SidebarRecentHistory.Entry
        var id: String { hostID.uuidString + ":" + visit.id }
        var label: String {
            [visit.item.title, visit.item.projectName, visit.item.worktreeName, hostLabel].joined(separator: " · ")
        }
    }

    private struct HostHistory: Codable {
        let hostID: UUID
        var label: String
        var history: SidebarRecentHistory
    }
    private var hosts: [HostHistory]
    private let defaults: UserDefaults
    private static let key = "mobile.recentPanes"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hosts = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([HostHistory].self, from: $0) } ?? []
    }

    var entries: [Entry] {
        hosts.flatMap { host in
            host.history.entries.map { Entry(hostID: host.hostID, hostLabel: host.label, visit: $0) }
        }.sorted { $0.visit.viewedAt > $1.visit.viewedAt }
    }

    func record(hostID: UUID, hostLabel: String, worktree: WorktreePanes, sessionName: String, at date: Date = Date()) {
        guard let leaf = worktree.layout?.leaves.first(where: { $0.sessionName == sessionName }) else { return }
        let project = SidebarProjection.projectID(worktree)
        let stable = worktree.sidebar?.id ?? "\(project):\(worktree.path)"
        let item = SidebarActivityItem(id: stable + ":" + (worktree.sidebar?.paneIDs?[sessionName] ?? sessionName),
            projectID: project, worktreeID: worktree.path, paneID: sessionName,
            projectName: worktree.repoDisplayName, worktreeName: worktree.displayName,
            title: leaf.displayTitle, occurrence: nil, isBusy: false)
        if !hosts.contains(where: { $0.hostID == hostID }) {
            hosts.append(.init(hostID: hostID, label: hostLabel, history: .init()))
        }
        let index = hosts.firstIndex { $0.hostID == hostID }!
        hosts[index].label = hostLabel
        hosts[index].history.open(item, at: date)
        for entry in entries.dropFirst(20) {
            if let index = hosts.firstIndex(where: { $0.hostID == entry.hostID }) {
                hosts[index].history.remove(entry.visit.id)
            }
        }
        persist()
    }

    func reconcile(hostID: UUID, worktrees: [WorktreePanes], projects: [SidebarProject]) {
        guard let index = hosts.firstIndex(where: { $0.hostID == hostID }) else { return }
        var history = hosts[index].history
        history.reconcile(worktrees: worktrees,
            availableProjectIDs: Set(projects.filter(\.isAvailable).map(\.id)))
        for visit in history.entries {
            guard let row = worktrees.first(where: { $0.path == visit.item.worktreeID && SidebarProjection.projectID($0) == visit.item.projectID }),
                  let leaf = row.layout?.leaves.first(where: { $0.sessionName == visit.item.paneID }),
                  leaf.displayTitle != visit.item.title else { continue }
            var item = visit.item
            item.title = leaf.displayTitle
            history.open(item, at: visit.viewedAt)
        }
        guard history != hosts[index].history else { return }
        hosts[index].history = history
        persist()
    }

    func forget(_ entry: Entry) {
        guard let index = hosts.firstIndex(where: { $0.hostID == entry.hostID }) else { return }
        hosts[index].history.remove(entry.visit.id)
        persist()
    }

    private func persist() {
        hosts.removeAll { $0.history.entries.isEmpty }
        defaults.set(try? JSONEncoder().encode(hosts), forKey: Self.key)
    }

    static func resolve(_ entry: Entry, fetch: () async throws -> [WorktreePanes],
        reopen: (String) async throws -> Void, isCurrent: () -> Bool
    ) async throws -> MobileNotificationActivation.Target {
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        let rows = try await fetch()
        guard isCurrent() else { throw CancellationError() }
        let item = entry.visit.item
        let worktree = rows.first { row in
            guard SidebarProjection.projectID(row) == item.projectID else { return false }
            if let metadata = row.sidebar, metadata.paneIDs != nil || metadata.paneSlotIDs != nil {
                return SidebarProjection.paneSlotID(for: item, in: metadata) != nil
            }
            let stable = row.sidebar?.id ?? "\(item.projectID):\(row.path)"
            return row.path == item.worktreeID && item.id == "\(stable):\(item.paneID ?? "")"
        }
        guard let worktree else { throw MobileNotificationActivation.Failure.worktreeUnavailable }
        let route = MobileStopNotificationRoute(hostID: entry.hostID, worktreePath: worktree.path,
            worktreeID: worktree.sidebar?.id, originDeviceID: worktree.origin?.deviceID,
            paneID: item.paneID, paneSlotID: worktree.sidebar.flatMap { SidebarProjection.paneSlotID(for: item, in: $0) })
        var firstFetch = true
        return try await MobileNotificationActivation.resolve(route, fetch: {
            if firstFetch { firstFetch = false; return rows }
            return try await fetch()
        }, reopen: reopen, isCurrent: isCurrent)
    }
}

/// All asynchronous mobile activations share one ordering, including requests
/// that are still waiting for a snapshot and have not changed selection yet.
@MainActor
final class MobileNavigationIntent {
    private(set) var current: UInt64 = 0
    @discardableResult func begin() -> UInt64 { current &+= 1; return current }
    func isCurrent(_ request: UInt64) -> Bool { request == current }
}
