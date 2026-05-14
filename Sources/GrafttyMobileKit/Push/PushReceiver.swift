#if canImport(UIKit)
import Foundation
import UserNotifications

/// Abstraction over the slice of `UNUserNotificationCenter` that
/// `PushReceiver` needs. Renamed (vs the underlying selector) so a
/// test double can supply an async signature without clashing with
/// `UNUserNotificationCenter`'s synchronous
/// `removeDeliveredNotifications(withIdentifiers:)`.
public protocol NotificationCenterRemover: Sendable {
    func removeNotifications(ids: [String]) async
}

extension UNUserNotificationCenter: NotificationCenterRemover {
    public func removeNotifications(ids: [String]) async {
        self.removeDeliveredNotifications(withIdentifiers: ids)
    }
}

/// Handler for silent remote notifications. Currently recognizes
/// `kind == "agent_stop_clear"`, which collapses a previously-delivered
/// agent-stop banner by removing it from the notification center.
public actor PushReceiver {
    private let remover: NotificationCenterRemover

    public init(remover: NotificationCenterRemover = UNUserNotificationCenter.current()) {
        self.remover = remover
    }

    /// Called from `UIApplicationDelegate.application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`.
    /// Returns `true` if the userInfo matched a known silent-push kind and was processed.
    public func handleSilentPush(userInfo: [AnyHashable: Any]) async -> Bool {
        guard let kind = userInfo["kind"] as? String, kind == "agent_stop_clear" else { return false }
        guard let collapseID = userInfo["collapse_id"] as? String else { return false }
        await remover.removeNotifications(ids: [collapseID])
        return true
    }
}
#endif
