import Foundation
import GrafttyProtocol

struct MobileStopNotificationRoute: Codable, Equatable, Sendable {
    let hostID: UUID
    let worktreePath: String
    let worktreeID: String?
    let originDeviceID: RemoteDeviceID?
    let paneID: String?
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
            let stopPane = activity.first { $0.agentStop != nil }
                .flatMap { SidebarProjection.attentionPaneRoute(for: $0, in: row) }
            func notification(title: String?, body: String, paneID: String?) -> MobileStopNotification {
                .init(identifier: "mobile-agent-stop:" + identity,
                    title: row.sidebar?.brief?.title ?? title ?? row.displayName,
                    subtitle: [row.effectiveEmoji, row.repoDisplayName, row.displayName].compactMap { $0 }.joined(separator: " · "),
                    body: body, route: .init(hostID: hostID, worktreePath: row.path,
                        worktreeID: row.sidebar?.id, originDeviceID: row.origin?.deviceID, paneID: paneID))
            }
            if let stop, stop.timestamp > (timestamps[identity] ?? -.infinity) {
                let previous = timestamps[identity]
                timestamps[identity] = stop.timestamp
                // Do not announce read history when a device is paired for the first time.
                if previous != nil || row.sidebar?.unseenAgentStop?.occurrence == stop.occurrence {
                    notifications.append(notification(title: stop.recap?.title,
                        body: stop.recap?.need ?? stop.recap?.completed ?? "\(stop.agentName) stopped.", paneID: stopPane))
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
