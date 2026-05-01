import Foundation
import GrafttyKit
import Observation

/// Backs the Team Activity Log window for one team. Owns a
/// `TeamInboxObserver` and republishes its emit stream as
/// `messages: [TeamInboxMessage]` on the main actor so SwiftUI views
/// can observe it via `@Observable`.
///
/// The observer's callback fires on a private utility-QoS dispatch
/// queue; we hop to the main thread before assigning `messages` so
/// SwiftUI redraw scheduling stays on its own actor.
@Observable
@MainActor
final class TeamActivityLogViewModel {
    /// Latest snapshot of the team's inbox, in append order.
    var messages: [TeamInboxMessage] = []

    /// Display name used in the window title bar; fixed at init time so
    /// renames during the window's lifetime do not retitle.
    let teamName: String

    @ObservationIgnored private let observer: TeamInboxObserver
    @ObservationIgnored private var cancellable: TeamInboxObserver.Cancellable?

    init(rootDirectory: URL, teamID: String, teamName: String) {
        self.teamName = teamName
        self.observer = TeamInboxObserver(rootDirectory: rootDirectory, teamID: teamID)
    }

    func start() {
        guard cancellable == nil else { return }
        cancellable = observer.start { [weak self] messages in
            // Observer fires on its private queue. Hop to main before
            // mutating @Observable state.
            DispatchQueue.main.async {
                self?.messages = messages
            }
        }
    }

    func stop() {
        cancellable?.cancel()
        cancellable = nil
    }
}
