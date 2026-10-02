import Foundation
import Testing
@testable import Graftty
@testable import GrafttyKit

@MainActor
@Suite("TerminalManager background port PID lookup")
struct TerminalManagerPortScanTests {
    @Test("Remapping a pane invalidates its previously cached shell PID")
    func remapClearsCachedPID() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = TerminalManager(socketPath: "/tmp/graftty-port-remap-test.sock")
        let launcher = ZmxLauncher(executable: URL(fileURLWithPath: "/usr/bin/true"), zmxDir: directory)
        manager.zmxLauncher = launcher
        let slot = PaneSlotID()
        let first = PaneSessionID()
        manager.recordPaneSession(first, for: slot)
        let firstName = launcher.sessionName(for: first)
        let firstLog = launcher.logFile(forSession: firstName)
        try FileManager.default.createDirectory(at: firstLog.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "pty spawned session=\(firstName) pid=1111\n".write(to: firstLog, atomically: true, encoding: .utf8)
        #expect(await manager.lookupShellPIDForPortScan(for: slot) == 1111)

        let second = PaneSessionID()
        manager.recordPaneSession(second, for: slot)
        let secondName = launcher.sessionName(for: second)
        try "pty spawned session=\(secondName) pid=2222\n".write(
            to: launcher.logFile(forSession: secondName), atomically: true, encoding: .utf8
        )
        #expect(await manager.lookupShellPIDForPortScan(for: slot) == 2222)
    }

    @Test("@spec PORTS-4.9: When a background port-scan PID lookup finishes after its pane is evicted or remapped to another session, the application shall discard the earlier result.", arguments: [false, true])
    func discardsResultAfterPaneChanges(remap: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = TerminalManager(socketPath: "/tmp/graftty-port-pid-test.sock")
        let launcher = ZmxLauncher(executable: URL(fileURLWithPath: "/usr/bin/true"), zmxDir: directory)
        manager.zmxLauncher = launcher
        let slot = PaneSlotID()
        let session = PaneSessionID()
        manager.recordPaneSession(session, for: slot)
        let name = launcher.sessionName(for: session)
        let log = launcher.logFile(forSession: name)
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "pty spawned session=\(name) pid=4242\n".write(to: log, atomically: true, encoding: .utf8)

        let started = AsyncStream<Void>.makeStream()
        let finish = DispatchSemaphore(value: 0)
        let timeout = Task {
            try? await Task.sleep(for: .seconds(5))
            started.continuation.finish()
        }
        defer { timeout.cancel(); finish.signal(); started.continuation.finish() }
        manager.portScanPIDResolver = ZmxPIDResolver(readLog: { url in
            #expect(!Thread.isMainThread)
            started.continuation.yield(())
            guard finish.wait(timeout: .now() + 5) == .success else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        })
        let lookup = Task { await manager.lookupShellPIDForPortScan(for: slot) }
        var iterator = started.stream.makeAsyncIterator()
        _ = try #require(await iterator.next())
        if remap { manager.recordPaneSession(PaneSessionID(), for: slot) }
        else { manager.evictSurface(terminalID: slot) }
        finish.signal()
        #expect(await lookup.value == nil)
        if remap { #expect(manager.lookupShellPID(for: slot) == nil) }
    }
}
