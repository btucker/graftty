import Testing
import Foundation
@testable import GrafttyKit

@Suite("Presence monitor — stale record cleanup")
struct PresenceMonitorTests {
    @Test("@spec TEAM-PRESENCE-1.4: When an agent process exits without its wrapper trap firing (e.g. SIGKILL), the application's process monitor shall clear the stale presence record on next observation.")
    func staleRecordCleared() throws {
        let tmpRoot = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpRoot) }
        let storage = TeamPresenceStorage(rootDirectory: tmpRoot)

        try storage.write(.init(teamID: "team-abc", worktree: "alive", runtime: .claude, paneSessionName: nil, pid: 1, registeredAt: Date()))
        try storage.write(.init(teamID: "team-abc", worktree: "dead", runtime: .claude, paneSessionName: nil, pid: 999_999, registeredAt: Date()))

        TeamPresenceMonitor.cleanupStale(
            storage: storage,
            isAlive: { $0 == 1 },
            eventLog: TeamEventLog(rootDirectory: tmpRoot.appendingPathComponent("events", isDirectory: true))
        )

        let alive = try storage.read(
            teamID: "team-abc",
            worktree: "alive",
            runtime: .claude,
            paneSessionName: nil
        )
        let dead = try storage.read(
            teamID: "team-abc",
            worktree: "dead",
            runtime: .claude,
            paneSessionName: nil
        )
        #expect(alive != nil)
        #expect(dead == nil)
    }

    @Test("Default isAlive uses kill(pid, 0) semantics: PID 1 (init) is always alive.")
    func defaultIsAliveUsesKill() {
        // PID 1 should always be considered alive on macOS.
        #expect(TeamPresenceMonitor.kernelIsAlive(1))
        // A wildly-out-of-range PID is not alive.
        #expect(!TeamPresenceMonitor.kernelIsAlive(999_999))
    }

    private func makeTmpDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("graftty-monitor-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
