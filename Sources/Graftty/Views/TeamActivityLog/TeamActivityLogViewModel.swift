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

extension TeamActivityLogViewModel {
    /// Continuation window: messages from the same actor within this
    /// duration collapse their headers.
    nonisolated static let continuationWindow: TimeInterval = 5 * 60

    /// Pure helper extracted for testability. Annotates each message
    /// with a `isContinuation` flag and weaves in `dayDivider` items
    /// at local-midnight crossings.
    nonisolated static func renderedItems(
        from messages: [TeamInboxMessage],
        calendar: Calendar
    ) -> [RenderedFeedItem] {
        var out: [RenderedFeedItem] = []
        var prev: (actor: String, timestamp: Date, day: Date)?

        for msg in messages {
            let row = ActivityFeedRow.resolve(msg)
            let day = calendar.startOfDay(for: msg.createdAt)

            // Insert day-divider when local-day rolls over.
            if let previous = prev, previous.day != day {
                out.append(.init(
                    id: "day-\(day.timeIntervalSince1970)",
                    row: .dayDivider(label: dayLabel(for: day, calendar: calendar)),
                    isContinuation: false
                ))
                prev = nil  // Day boundary always breaks continuation.
            }

            switch row {
            case let .chat(worktree, _, _, ts, _),
                 let .system(worktree, _, _, ts):
                let isCont = prev.map { p in
                    p.actor == worktree
                        && ts.timeIntervalSince(p.timestamp) <= continuationWindow
                } ?? false
                out.append(.init(id: msg.id, row: row, isContinuation: isCont))
                prev = (worktree, ts, day)

            case .memberJoined, .memberLeft:
                out.append(.init(id: msg.id, row: row, isContinuation: false))
                prev = nil  // Markers reset the continuation chain.

            case .dayDivider:
                // resolve(_:) does not produce dayDivider; only the
                // weaving code above does.
                continue
            }
        }
        return out
    }

    /// Renders a `Date` as the day-divider label: "Today", "Yesterday",
    /// or "MMM d" for older days.
    nonisolated private static func dayLabel(for day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "MMM d"
        return formatter.string(from: day)
    }

    /// View-side accessor — wraps the static helper using the system
    /// calendar at the actor's locale.
    var renderedItems: [RenderedFeedItem] {
        Self.renderedItems(from: messages, calendar: .current)
    }
}
