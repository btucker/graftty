#if canImport(UIKit)
import Foundation
import Observation

/// One resolved notification occurrence, owned above this window's pane routes.
@MainActor @Observable
final class MobileNotificationPaneActivation {
    struct Request: Equatable {
        let id = UUID()
        let hostID: UUID
        let sessionName: String
    }
    private(set) var request: Request?
    @ObservationIgnored private var consumed = false

    func activate(hostID: UUID, sessionName: String) {
        consumed = false
        request = .init(hostID: hostID, sessionName: sessionName)
    }

    func consume(hostID: UUID, sessionName: String) -> Bool {
        guard !consumed, let request, request.hostID == hostID,
              request.sessionName == sessionName else { return false }
        // Preserve the task identity while its recovery request is in flight.
        consumed = true
        return true
    }

    func discard(unlessHostID hostID: UUID?, sessionName: String?) {
        guard request?.hostID != hostID || request?.sessionName != sessionName else { return }
        cancel()
    }

    func cancel() { request = nil }
}
#endif
