#if canImport(UIKit)
import Foundation
import GrafttyProtocol
import Observation

/// Narrow protocol that SessionClient satisfies; lets HostControllerTests
/// stub without importing GhosttyTerminal.
public protocol SessionClientProtocol: AnyObject {
    var name: String { get }
    func start()
    func stop()
}

extension SessionClient: SessionClientProtocol {
    public var name: String { sessionName }
}

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
    private let makeClient: (String) -> any SessionClientProtocol
    private var clientsByPaneID: [UUID: any SessionClientProtocol] = [:]

    public init(
        host: Host,
        fetcher: @escaping () async -> [SessionInfo],
        makeClient: @escaping (String) -> any SessionClientProtocol
    ) {
        self.host = host
        self.fetcher = fetcher
        self.makeClient = makeClient
    }

    public func refreshSessions() async {
        sessions = await fetcher()
    }

    public func openPane(sessionName: String) {
        let pane = Pane(sessionName: sessionName)
        let client = makeClient(sessionName)
        client.start()
        clientsByPaneID[pane.id] = client
        panes.append(pane)
    }

    public func closePane(_ id: UUID) {
        clientsByPaneID[id]?.stop()
        clientsByPaneID.removeValue(forKey: id)
        panes.removeAll { $0.id == id }
    }

    public func tearDownForBackground() {
        for (_, c) in clientsByPaneID { c.stop() }
        clientsByPaneID.removeAll()
    }

    public func resumeForForeground(currentSessions: [SessionInfo]) async {
        sessions = currentSessions
        let liveNames = Set(currentSessions.map(\.name))
        var survivors: [Pane] = []
        var ended: [Pane] = endedPanes
        for pane in panes {
            if liveNames.contains(pane.sessionName) {
                let client = makeClient(pane.sessionName)
                client.start()
                clientsByPaneID[pane.id] = client
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
