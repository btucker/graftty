import Foundation
import GrafttyProtocol

struct MobileStopNotificationRoute: Codable, Equatable, Sendable {
    let hostID: UUID
    let worktreePath: String
    let worktreeID: String?
    let originDeviceID: RemoteDeviceID?
    let paneID: String?
    var paneSlotID: String? = nil

    func matches(_ row: WorktreePanes) -> Bool {
        row.path == worktreePath
            && (worktreeID == nil || row.sidebar?.id == worktreeID)
            && (originDeviceID == nil || row.origin?.deviceID == originDeviceID)
    }

    func pane(in row: WorktreePanes) -> PaneLayoutNode.Leaf? {
        let leaves = row.layout?.leaves ?? []
        if let paneSlotID { return leaves.first { row.sidebar?.paneIDs?[$0.sessionName] == paneSlotID } }
        if let paneID { return leaves.first { $0.sessionName == paneID } }
        return leaves.count == 1 ? leaves.first : nil
    }
}

/// Resolves fresh authenticated snapshots before committing any navigation.
enum MobileNotificationActivation {
    enum Failure: Error { case worktreeUnavailable, paneUnavailable, notReady }
    struct Target {
        let rows: [WorktreePanes]
        let worktree: WorktreePanes
        let pane: PaneLayoutNode.Leaf
    }

    @MainActor static func resolve(_ route: MobileStopNotificationRoute,
        fetch: () async throws -> [WorktreePanes], reopen: (String) async throws -> Void,
        isCurrent: () -> Bool,
        pause: () async throws -> Void = { try await Task.sleep(for: .milliseconds(250)) }
    ) async throws -> Target {
        func checkCurrent() throws {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
        }
        try checkCurrent()
        var rows = try await fetch()
        try checkCurrent()
        guard let original = rows.first(where: route.matches), original.state.hasOnDiskWorktree
        else { throw Failure.worktreeUnavailable }
        if original.state == .closed {
            try await reopen(original.path)
            try checkCurrent()
            rows = try await fetch()
        }
        for attempt in 0..<12 {
            try checkCurrent()
            guard let row = rows.first(where: route.matches), row.state.hasOnDiskWorktree
            else { throw Failure.worktreeUnavailable }
            if row.state == .running, row.layout?.leaves.isEmpty == false {
                guard let pane = route.pane(in: row) else { throw Failure.paneUnavailable }
                return .init(rows: rows, worktree: row, pane: pane)
            }
            guard attempt < 11 else { throw Failure.notReady }
            try await pause()
            try checkCurrent()
            rows = try await fetch()
        }
        throw Failure.notReady
    }
}

struct MobileStopNotification: Sendable {
    let identifier: String
    let title: String
    let subtitle: String
    let body: String
    let route: MobileStopNotificationRoute
}

/// Durable high-water marks prevent polling, transport reconnects, and view recreation from replaying stops.
struct MobileStopNotificationLedger: Codable, Equatable {
    private var timestamps: [String: Double] = [:]

    mutating func receive(_ rows: [WorktreePanes], hostID: UUID) -> [MobileStopNotification] {
        var notifications: [MobileStopNotification] = []
        for row in rows {
            let identity = [hostID.uuidString, row.origin?.deviceID.value ?? "", row.sidebar?.id ?? row.path]
                .map { "\($0.utf8.count):\($0)" }.joined()
            let activity = SidebarProjection.activity([row])
            let stop = [row.sidebar?.lastAgentStop, row.sidebar?.unseenAgentStop]
                .compactMap { $0 }.max { $0.timestamp < $1.timestamp }
            let stopPane = stop.flatMap { stop in
                let item = SidebarActivityItem(id: identity + ":stop", projectID: SidebarProjection.projectID(row),
                    worktreeID: row.path, paneID: nil, projectName: row.repoDisplayName, worktreeName: row.displayName,
                    title: stop.title, occurrence: stop.occurrence, isBusy: false, agentStop: stop)
                return SidebarProjection.attentionPaneRoute(for: item, in: row)
            }
            func notification(title: String?, body: String, paneID: String?, paneSlotID: String? = nil) -> MobileStopNotification {
                .init(identifier: "mobile-agent-stop:" + identity,
                    title: row.sidebar?.brief?.title ?? title ?? row.displayName,
                    subtitle: [row.effectiveEmoji, row.repoDisplayName, row.displayName].compactMap { $0 }.joined(separator: " · "),
                    body: body, route: .init(hostID: hostID, worktreePath: row.path,
                        worktreeID: row.sidebar?.id, originDeviceID: row.origin?.deviceID, paneID: paneID,
                        paneSlotID: paneSlotID ?? paneID.flatMap { row.sidebar?.paneIDs?[$0] }))
            }
            if let stop, stop.timestamp > (timestamps[identity] ?? -.infinity) {
                let previous = timestamps[identity]
                timestamps[identity] = stop.timestamp
                // Do not announce read history when a device is paired for the first time.
                if previous != nil || row.sidebar?.unseenAgentStop?.occurrence == stop.occurrence {
                    notifications.append(notification(title: stop.recap?.title,
                        body: stop.recap?.need ?? stop.recap?.completed ?? "\(stop.agentName) stopped.", paneID: stopPane,
                        paneSlotID: stop.paneSlotID))
                }
            }
            for item in activity where item.agentStop == nil && item.occurrence?.source == .agentStop {
                guard let time = item.occurrence?.timestamp?.timeIntervalSinceReferenceDate else { continue }
                let key = identity + ":input:" + item.id
                guard time > (timestamps[key] ?? -.infinity) else { continue }
                timestamps[key] = time
                let paneID = SidebarProjection.attentionPaneRoute(for: item, in: row)
                if let stop, time <= stop.timestamp, paneID == stopPane { continue }
                notifications.append(notification(title: nil, body: item.title, paneID: paneID))
            }
        }
        return notifications
    }
}
