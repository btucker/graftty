import Foundation
import GrafttyProtocol
import Observation
import UserNotifications

/// Delivers events observed on the live connection. Background push requires APNs.
@Observable @MainActor
final class MobileAttentionNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MobileAttentionNotifications(authorize: {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .notDetermined: return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default: return false
        }
    }, deliver: { try await UNUserNotificationCenter.current().add($0) })

    /// @spec IOS-13.2: When mobile delivers an Attention notification, the application shall request notification authorization, present an authorized request with its project, worktree, and request text, and preserve a host-scoped activation payload without marking it viewed.
    struct Payload: Codable, Equatable {
        let hostID: UUID
        let item: SidebarActivityItem
        private static let key = "graftty.mobile.attention"

        // Length-delimited components avoid ambiguous paths and project IDs.
        var identifier: String { "mobile-attention:\(hostID):\(item.worktreeIdentity.id)" }

        func request() throws -> UNNotificationRequest {
            let content = UNMutableNotificationContent()
            content.title = item.agentStop?.recap?.title ?? item.title
            content.subtitle = "\(item.projectName) · \(item.worktreeName)"
            content.body = item.agentStop?.recap.map { $0.need ?? $0.completed }
                ?? item.occurrence?.text ?? item.title
            content.sound = .default
            content.threadIdentifier = identifier
            content.userInfo = [Self.key: try JSONEncoder().encode(self)]
            return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        }

        static func decode(_ userInfo: [AnyHashable: Any]) -> Self? {
            guard let data = userInfo[key] as? Data else { return nil }
            return try? JSONDecoder().decode(Self.self, from: data)
        }
    }

    struct Activation: Equatable {
        let id = UUID()
        let payload: Payload
    }
    var activation: Activation?
    @ObservationIgnored private let authorize: () async -> Bool
    @ObservationIgnored private let deliver: (UNNotificationRequest) async throws -> Void
    @ObservationIgnored private var authorization: Task<Bool, Never>?
    @ObservationIgnored private var reservations: [String: UUID] = [:]

    init(authorize: @escaping () async -> Bool, deliver: @escaping (UNNotificationRequest) async throws -> Void) {
        self.authorize = authorize
        self.deliver = deliver
        super.init()
    }

    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    @discardableResult
    func enqueue(_ item: SidebarActivityItem, hostID: UUID,
                 isCurrent: @escaping () -> Bool = { true }) -> Task<Void, Never> {
        let payload = Payload(hostID: hostID, item: item)
        let token = UUID()
        reservations[payload.identifier] = token
        return Task {
            defer {
                if reservations[payload.identifier] == token { reservations[payload.identifier] = nil }
            }
            guard isCurrent() else { return }
            let permission: Task<Bool, Never>
            if let authorization { permission = authorization }
            else {
                permission = Task { await authorize() }
                authorization = permission
            }
            let allowed = await permission.value
            authorization = nil
            guard allowed, reservations[payload.identifier] == token, isCurrent(),
                  let request = try? payload.request() else { return }
            // Failed delivery leaves the durable Attention request available in the list.
            try? await deliver(request)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else {
            completionHandler()
            return
        }
        let userInfo = response.notification.request.content.userInfo
        Task { @MainActor in
            if let payload = Payload.decode(userInfo) { activation = Activation(payload: payload) }
            completionHandler()
        }
    }
}
