import Foundation
import Testing
@testable import GrafttyKit

@Suite("Background presence maintenance")
struct TeamPresenceSweepTests {
    @Test("@spec TEAM-10.18: When the periodic presence sweep runs, the application shall clean stale presence and orphaned app-server records and load the remaining presence records off the main thread before updating delivery liveness.")
    @MainActor
    func sweepsOffMainThread() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = TeamPresenceStorage(rootDirectory: root)
        let alive = TeamPresenceRecord(teamID: "team", worktree: "alive", runtime: .codex,
                                       paneSessionName: nil, pid: 1, registeredAt: Date(timeIntervalSince1970: 1_700_000_000))
        let dead = TeamPresenceRecord(teamID: "team", worktree: "dead", runtime: .codex,
                                      paneSessionName: nil, pid: 2, registeredAt: Date(timeIntervalSince1970: 1_700_000_000))
        try storage.write(alive)
        try storage.write(dead)
        let sessions = CodexAppServerSessionStorage(rootDirectory: root)
        try sessions.write(.init(teamID: "team", worktree: "orphan", paneSessionName: "session",
                                 socketPath: "/unused", realBinaryPath: "/unused", appServerPID: .max,
                                 appServerProcessStartTimeMicroseconds: 1, ownerPID: .max,
                                 ownerProcessStartTimeMicroseconds: 1, registeredAt: Date()))

        let records = await TeamPresenceMonitor.sweep(storage: storage, isAlive: { pid in
            #expect(!Thread.isMainThread)
            return pid == 1
        }, eventLog: nil)
        #expect(records == [alive])
        #expect(try storage.listAll() == [alive])
        #expect(try sessions.listAll().isEmpty)
    }
}
