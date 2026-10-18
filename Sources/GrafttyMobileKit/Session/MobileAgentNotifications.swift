#if canImport(UIKit)
import Foundation
import GrafttyProtocol
import Observation
import UserNotifications
import os

@MainActor @Observable
final class MobileAgentNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MobileAgentNotifications()
    private(set) var pendingRoute: MobileStopNotificationRoute?
    private let center: UNUserNotificationCenter
    private let defaults: UserDefaults
    private var ledger: MobileStopNotificationLedger
    private var authorizationRequested = false
    private static let storageKey = "GrafttyMobile.stopNotifications"
    private static let logger = Logger(subsystem: "dev.graftty.mobile", category: "Notifications")

    override init() {
        center = .current()
        defaults = .standard
        ledger = defaults.data(forKey: Self.storageKey).flatMap {
            try? JSONDecoder().decode(MobileStopNotificationLedger.self, from: $0)
        } ?? .init()
        super.init()
        center.delegate = self
    }

    func requestAuthorization() async {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        do { _ = try await center.requestAuthorization(options: [.alert, .sound]) }
        catch { Self.logger.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)") }
    }

    func receive(_ rows: [WorktreePanes], hostID: UUID) async {
        let previous = ledger
        let notifications = ledger.receive(rows, hostID: hostID)
        if ledger != previous { defaults.set(try? JSONEncoder().encode(ledger), forKey: Self.storageKey) }
        for notification in notifications {
            do { try await center.add(Self.request(for: notification)) }
            catch { Self.logger.error("Stop notification failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    static func request(for notification: MobileStopNotification) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.subtitle = notification.subtitle
        content.body = notification.body
        content.sound = .default
        if let route = try? JSONEncoder().encode(notification.route) {
            content.userInfo = ["kind": "mobile_agent_stop", "route": route.base64EncodedString()]
        }
        return UNNotificationRequest(identifier: notification.identifier, content: content, trigger: nil)
    }

    func consume(_ route: MobileStopNotificationRoute) {
        if pendingRoute == route { pendingRoute = nil }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(notification.request.content.userInfo["kind"] as? String == "mobile_agent_stop" ? [.banner, .sound] : [])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           response.notification.request.content.userInfo["kind"] as? String == "mobile_agent_stop",
           let encoded = response.notification.request.content.userInfo["route"] as? String,
           let data = Data(base64Encoded: encoded),
           let route = try? JSONDecoder().decode(MobileStopNotificationRoute.self, from: data) {
            Task { @MainActor in self.pendingRoute = route }
        }
        completionHandler()
    }
}
#endif
