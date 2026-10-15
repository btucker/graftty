import Foundation
import UserNotifications
import GrafttyKit

/// Keeps slower identity lookups from replacing a later request for the same worktree.
@MainActor
final class AgentNotificationDelivery {
    private var pending: [String: UUID] = [:]

    struct Reservation {
        let identifier: String?
        let token: UUID
    }

    func reserve(_ notification: AgentStopNotificationContent) -> Reservation {
        let reservation = Reservation(identifier: notification.identifier, token: UUID())
        if let id = reservation.identifier { pending[id] = reservation.token }
        return reservation
    }

    func post(
        _ notification: AgentStopNotificationContent, reservation: Reservation,
        authorized: () async -> Bool,
        resolving: (AgentStopNotificationContent) async -> AgentStopNotificationContent,
        deliver: ((request: UNNotificationRequest, sourceURL: URL?)) async -> Void
    ) async {
        let token = reservation.token
        defer {
            if let id = reservation.identifier, pending[id] == token { pending[id] = nil }
        }
        guard reservation.identifier.map({ pending[$0] == token }) ?? true else { return }
        guard await authorized() else { return }
        let resolved = await resolving(notification)
        guard notification.identifier.map({ pending[$0] == token }) ?? true else { return }
        let prepared = AgentNotificationRouter.prepareRequest(for: resolved)
        defer {
            // Capture the source path, since attachment.url may be system-owned.
            if let source = prepared.sourceURL { try? FileManager.default.removeItem(at: source) }
        }
        await deliver(prepared)
    }
}
