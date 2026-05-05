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
    /// Setter recomputes `renderedItems` so SwiftUI sees a single
    /// observable change per emit instead of paying for the full
    /// annotation walk every time the view body reads renderedItems.
    var messages: [TeamInboxMessage] = [] {
        didSet { renderedItems = Self.renderedItems(from: messages, calendar: .current) }
    }

    /// Annotated transcript items derived from `messages`. Read-only
    /// from outside; updated atomically with `messages`.
    private(set) var renderedItems: [RenderedFeedItem] = []

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
        // Continuation chain (`actor` + `timestamp`) is independent
        // from the day pointer used for divider insertion: a marker
        // resets the chain but doesn't reset the day, so a midnight
        // crossing after a marker still surfaces a divider.
        var prevContinuation: (actor: String, timestamp: Date)?
        var prevDay: Date?

        for msg in messages {
            let row = ActivityFeedRow.resolve(msg)
            let day = calendar.startOfDay(for: msg.createdAt)

            if let lastDay = prevDay, lastDay != day {
                out.append(.init(
                    id: "day-\(day.timeIntervalSince1970)",
                    row: .dayDivider(label: dayLabel(for: day, calendar: calendar)),
                    isContinuation: false
                ))
                prevContinuation = nil
            }

            switch row {
            case let .chat(worktree, _, _, ts, _),
                 let .system(worktree, _, _, ts):
                let isCont = prevContinuation.map { p in
                    p.actor == worktree
                        && ts.timeIntervalSince(p.timestamp) <= continuationWindow
                } ?? false
                out.append(.init(id: msg.id, row: row, isContinuation: isCont))
                prevContinuation = (worktree, ts)

            case .memberJoined, .memberLeft:
                out.append(.init(id: msg.id, row: row, isContinuation: false))
                prevContinuation = nil

            case .dayDivider:
                // resolve(_:) does not produce dayDivider; only the
                // weaving code above does.
                continue
            }
            prevDay = day
        }
        return out
    }

    /// Date → day-divider label: "Today", "Yesterday", or "MMM d".
    nonisolated private static func dayLabel(for day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return Self.olderDayFormatter.string(from: day)
    }

    /// Static — `DateFormatter` is expensive to construct and the
    /// formatter is stateless aside from locale/calendar.
    nonisolated private static let olderDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()
}
