import SwiftUI
import AppKit
import UserNotifications
import GrafttyCommandUI
import GrafttyHostAgent
import GrafttyKit
import GrafttyProtocol
import GrafttyRemoteClient

final class AgentNotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AgentNotificationRouter()

    @MainActor var onActivate: ((AgentStopNotificationPayload) -> Void)?
    @MainActor var onActivateRemote: ((RemoteNotificationEvent) -> Void)?

    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    @MainActor private lazy var delivery = AgentNotificationDelivery()

    @MainActor
    func post(_ notification: AgentStopNotificationContent,
              resolving: @escaping @MainActor (AgentStopNotificationContent) async -> AgentStopNotificationContent = {
                  await ProjectNotificationIdentity.resolved($0)
              }) {
        let center = UNUserNotificationCenter.current()
        let reservation = delivery.reserve(notification)
        Task {
            await delivery.post(notification, reservation: reservation, authorized: {
                let settings = await center.notificationSettings()
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral: return true
                case .notDetermined:
                    return (try? await center.requestAuthorization(options: [.alert, .sound])) == true
                default: return false
                }
            }, resolving: resolving, deliver: { request in
                try? await center.add(request.request)
            })
        }
    }

    @MainActor
    func post(_ event: RemoteNotificationEvent,
              resolvingIdentity: @escaping @MainActor () async -> Data? = { nil }) {
        guard let data = try? JSONEncoder().encode(event) else { return }
        post(AgentStopNotificationContent(
            title: event.title,
            body: event.body,
            userInfo: [
                "kind": "remote_attention",
                "event": data.base64EncodedString(),
            ],
            identifier: event.kind == .agentStop
                ? "remote-agent-attention:\(event.originFingerprint?.display ?? event.origin.deviceID.value):\(event.worktreeID)"
                : nil,
            identityImage: nil
        ), resolving: { notification in
            var resolved = notification
            resolved.identityImage = await resolvingIdentity()
            return resolved
        })
    }

    static func request(for notification: AgentStopNotificationContent) -> UNNotificationRequest {
        prepareRequest(for: notification).request
    }

    static func prepareRequest(for notification: AgentStopNotificationContent) -> (request: UNNotificationRequest, sourceURL: URL?) {
        var sourceURL: URL?
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.subtitle = notification.subtitle ?? ""
        content.body = notification.body
        content.sound = .default
        content.userInfo = notification.userInfo
        if let data = notification.identityImage, data.count <= 65536 {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("graftty-project-\(UUID().uuidString).png")
            do {
                try data.write(to: url, options: .atomic)
                content.attachments = [try UNNotificationAttachment(identifier: "project-icon", url: url)]
                sourceURL = url
            } catch {
                try? FileManager.default.removeItem(at: url)
            }
        }
        return (UNNotificationRequest(identifier: notification.identifier ?? UUID().uuidString, content: content, trigger: nil), sourceURL)
    }

    static func foregroundPresentationOptions(kind: String?) -> UNNotificationPresentationOptions {
        kind == "agent_stop" || kind == "remote_attention" ? [.banner, .sound] : []
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let raw = response.notification.request.content.userInfo
        var userInfo: [String: Any] = [:]
        for (key, value) in raw {
            guard let key = key as? String else { continue }
            userInfo[key] = value
        }
        if userInfo["kind"] as? String == "remote_attention",
           let encoded = userInfo["event"] as? String,
           let data = Data(base64Encoded: encoded),
           let event = try? JSONDecoder().decode(
               RemoteNotificationEvent.self,
               from: data
           ) {
            await MainActor.run {
                self.onActivateRemote?(event)
            }
            return
        }
        guard let payload = try? AgentStopNotification.payload(from: userInfo) else { return }
        await MainActor.run {
            self.onActivate?(payload)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        Self.foregroundPresentationOptions(kind: notification.request.content.userInfo["kind"] as? String)
    }
}
