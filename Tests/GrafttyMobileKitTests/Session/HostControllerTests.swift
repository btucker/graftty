#if canImport(UIKit)
import Foundation
import Testing
@testable import GrafttyMobileKit
import GrafttyProtocol

@Suite
@MainActor
struct HostControllerTests {

    final class FakeSessionClient: SessionClientProtocol, @unchecked Sendable {
        let name: String
        var startCount = 0
        var stopCount = 0
        init(name: String) { self.name = name }
        func start() { startCount += 1 }
        func stop() { stopCount += 1 }
    }

    @Test
    func resumeRedialsPanesWhoseSessionsStillExist() async {
        let sessions = [
            SessionInfo(name: "a", worktreePath: "/", repoDisplayName: "r", worktreeDisplayName: "a"),
            SessionInfo(name: "b", worktreePath: "/", repoDisplayName: "r", worktreeDisplayName: "b"),
        ]
        let host = HostController(
            host: Host(label: "m", baseURL: URL(string: "http://m/")!),
            fetcher: { sessions },
            makeClient: { name in FakeSessionClient(name: name) }
        )
        await host.refreshSessions()
        host.openPane(sessionName: "a")
        host.openPane(sessionName: "b")
        host.tearDownForBackground()
        await host.resumeForForeground(currentSessions: [sessions[0]])
        #expect(host.panes.map(\.sessionName) == ["a"])
        #expect(host.endedPanes.map(\.sessionName) == ["b"])
    }

    @Test
    func exponentialBackoffSequence() {
        let schedule = HostController.backoffSchedule(attempts: 5)
        #expect(schedule == [1, 2, 4, 8, 16])
    }

    @Test
    func backoffCapsAt30Seconds() {
        let schedule = HostController.backoffSchedule(attempts: 8)
        #expect(schedule == [1, 2, 4, 8, 16, 30, 30, 30])
    }
}
#endif
