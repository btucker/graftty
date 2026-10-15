import Foundation
import Testing
@testable import GrafttyKit

@Suite("Background presence maintenance")
struct TeamPresenceSweepTests {
    @Test("@spec TEAM-10.19: If a periodic presence refresh finishes after a newer foreground presence update or removal, then the application shall preserve the newer records and use them for delivery liveness.", arguments: [false, true])
    @MainActor
    func preservesChangesDuringRefresh(remove: Bool) async {
        let original = TeamPresenceRecord(teamID: "team", worktree: "old", runtime: .codex,
                                          paneSessionName: "old-pane", pid: 1, registeredAt: Date())
        let added = TeamPresenceRecord(teamID: "team", worktree: "new", runtime: .codex,
                                       paneSessionName: "new-pane", pid: 2, registeredAt: Date())
        let index = TeamPresenceIndex(records: [original])
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<[TeamPresenceRecord]>.makeStream()
        defer { started.continuation.finish(); release.continuation.finish() }
        let refresh = Task {
            await index.refresh {
                started.continuation.yield(())
                var results = release.stream.makeAsyncIterator()
                return await results.next() ?? []
            }
        }
        var starts = started.stream.makeAsyncIterator()
        _ = await starts.next()
        let expected: [TeamPresenceRecord]
        if remove {
            index.remove(teamID: "team", worktree: "old", runtime: .codex, paneSessionName: "old-pane")
            expected = []
        } else {
            expected = [original, added]
            index.replace(with: expected)
        }
        release.continuation.yield([original])
        #expect(await refresh.value == expected)
        #expect(index.allRecords() == expected)
        #expect(index.records(forPaneSessionName: "new-pane") == (remove ? [] : [added]))
    }

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

        let index = TeamPresenceIndex(records: [dead])
        let records = await index.refresh {
            await TeamPresenceMonitor.sweep(storage: storage, isAlive: { pid in
                #expect(!Thread.isMainThread)
                return pid == 1
            }, eventLog: nil)
        }
        #expect(records == [alive])
        #expect(index.allRecords() == [alive])
        #expect(index.records(forPaneSessionName: "missing").isEmpty)
        #expect(try storage.listAll() == [alive])
        #expect(try sessions.listAll().isEmpty)
    }
}
