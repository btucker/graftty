#if canImport(UIKit)
import Foundation
import GrafttyProtocol
import Observation

@Observable
@MainActor
public final class HostController {

    public struct Pane: Identifiable, Equatable {
        public let id = UUID()
        public let sessionName: String
    }

    public let host: Host
    public private(set) var sessions: [SessionInfo] = []
    public private(set) var panes: [Pane] = []
    public private(set) var endedPanes: [Pane] = []

    private let fetcher: () async -> [SessionInfo]

    public init(
        host: Host,
        fetcher: @escaping () async -> [SessionInfo]
    ) {
        self.host = host
        self.fetcher = fetcher
    }

    public func refreshSessions() async {
        let fresh = await fetcher()
        if fresh != sessions { sessions = fresh }
    }

    @discardableResult
    public func openPane(sessionName: String) -> Pane {
        let pane = Pane(sessionName: sessionName)
        panes.append(pane)
        return pane
    }

    public func closePane(_ id: UUID) {
        panes.removeAll { $0.id == id }
    }

    /// Called when the app enters the background. RootView tears down the
    /// live `SessionClient`s; this controller keeps the `panes` list so
    /// `resumeForForeground` can filter it against the next `/sessions`
    /// response.
    public func tearDownForBackground() {}

    /// Called after the app is back in the foreground with a fresh
    /// `/sessions` response. Panes whose session name is absent from the
    /// response move to `endedPanes`; survivors stay in `panes` for
    /// RootView to re-dial.
    public func resumeForForeground(currentSessions: [SessionInfo]) async {
        sessions = currentSessions
        let liveNames = Set(currentSessions.map(\.name))
        var survivors: [Pane] = []
        var ended = endedPanes
        for pane in panes {
            if liveNames.contains(pane.sessionName) {
                survivors.append(pane)
            } else {
                ended.append(pane)
            }
        }
        panes = survivors
        endedPanes = ended
    }

    /// Exponential backoff schedule for reconnect attempts (1s → 30s cap).
    public static func backoffSchedule(attempts: Int) -> [TimeInterval] {
        (0..<attempts).map { n in
            min(30, pow(2.0, Double(n)))
        }
    }
}
#endif
