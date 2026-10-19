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
    private var center: UNUserNotificationCenter?
    private let defaults: UserDefaults
    private let prepareRequest: (UNNotificationRequest) -> UNNotificationRequest
    private var ledger: MobileStopNotificationLedger
    private var authorizationRequested = false
    // Observes submission without replacing the native notification service.
    var didSubmitRequest: ((UNNotificationRequest) -> Void)?
    // Observes only decoded, native default-action responses; never supplies a route.
    var didReceiveResponse: ((String, MobileStopNotificationRoute) -> Void)?
    // Observes the OS presentation callback without changing its options.
    var didReceivePresentationRequest: ((String, UInt) -> Void)?
    private static let storageKey = "GrafttyMobile.stopNotifications"
    private static let logger = Logger(subsystem: "dev.graftty.mobile", category: "Notifications")

    override convenience init() { self.init(defaults: .standard) }

    init(defaults: UserDefaults,
         prepareRequest: @escaping (UNNotificationRequest) -> UNNotificationRequest = { $0 }) {
        self.defaults = defaults
        self.prepareRequest = prepareRequest
        ledger = defaults.data(forKey: Self.storageKey).flatMap {
            try? JSONDecoder().decode(MobileStopNotificationLedger.self, from: $0)
        } ?? .init()
        super.init()
    }

    /// Called by the application entry point before launch completes. Keeping
    /// system access here lets views and standalone tests construct state safely.
    func install() {
        guard center == nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        self.center = center
    }

    func requestAuthorization() async {
        guard let center, !authorizationRequested else { return }
        authorizationRequested = true
        do { _ = try await center.requestAuthorization(options: [.alert, .sound]) }
        catch { Self.logger.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)") }
    }

    func receive(_ rows: [WorktreePanes], hostID: UUID) async {
        guard let center else { return }
        let previous = ledger
        let notifications = ledger.receive(rows, hostID: hostID)
        if ledger != previous { defaults.set(try? JSONEncoder().encode(ledger), forKey: Self.storageKey) }
        for notification in notifications {
            do {
                let request = prepareRequest(Self.request(for: notification))
                try await center.add(request)
                didSubmitRequest?(request)
            }
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
        let options: UNNotificationPresentationOptions = notification.request.content.userInfo["kind"] as? String == "mobile_agent_stop" ? [.banner, .sound] : []
        let identifier = notification.request.identifier
        Task { @MainActor in self.didReceivePresentationRequest?(identifier, options.rawValue) }
        completionHandler(options)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           response.notification.request.content.userInfo["kind"] as? String == "mobile_agent_stop",
           let encoded = response.notification.request.content.userInfo["route"] as? String,
           let data = Data(base64Encoded: encoded),
           let route = try? JSONDecoder().decode(MobileStopNotificationRoute.self, from: data) {
            let identifier = response.notification.request.identifier
            Task { @MainActor in
                self.pendingRoute = route
                self.didReceiveResponse?(identifier, route)
            }
        }
        completionHandler()
    }
}
#endif
