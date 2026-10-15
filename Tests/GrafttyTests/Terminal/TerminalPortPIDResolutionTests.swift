import Foundation
import Testing
@testable import Graftty
@testable import GrafttyKit

@MainActor
@Suite("Port-scan PID resolution")
struct TerminalPortPIDResolutionTests {
    private struct Fixture {
        let directory: URL
        let listing: URL
        let started: URL
        let release: URL
        let calls: URL
        let launcher: ZmxLauncher

        init(blocked: Bool = false) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            listing = directory.appendingPathComponent("listing")
            started = directory.appendingPathComponent("started")
            release = directory.appendingPathComponent("release")
            calls = directory.appendingPathComponent("calls")
            let executable = directory.appendingPathComponent("zmx")
            let wait = blocked ? "while [ ! -f '\(release.path)' ]; do /bin/sleep 0.01; done\n" : ""
            try """
            #!/bin/sh
            [ "$1" = list ] || exit 0
            printf x >> '\(calls.path)'
            /bin/cat '\(listing.path)' > '\(directory.path)/snapshot'
            : > '\(started.path)'
            \(wait)/bin/cat '\(directory.path)/snapshot'
            """.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            launcher = ZmxLauncher(executable: executable, zmxDir: directory)
        }

        func setListing(_ sessions: [PaneSessionID: Int32]) throws {
            try sessions.map { "name=\(ZmxLauncher.sessionName(for: $0.key))\tpid=\($0.value)\n" }
                .joined().write(to: listing, atomically: true, encoding: .utf8)
        }

        func waitUntilStarted() async throws {
            let deadline = ContinuousClock.now + .seconds(3)
            while !FileManager.default.fileExists(atPath: started.path), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            try #require(FileManager.default.fileExists(atPath: started.path))
        }

        func unblock() throws { try Data().write(to: release) }
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    enum Change: Sendable, CaseIterable { case remap, recreate, restoreState, launcher, reset }

    @Test("@spec PORTS-4.9: If a pane lifecycle, launcher, or query changes during port PID resolution, then the application shall discard the late result before updating the PID cache or port registration.", arguments: Change.allCases)
    func lateResultsAreDiscarded(change: Change) async throws {
        let fixture = try Fixture(blocked: true)
        defer { fixture.remove() }
        let manager = TerminalManager(socketPath: "/tmp/graftty-port-late-test.sock")
        manager.zmxLauncher = fixture.launcher
        let pane = PaneSlotID(), session = PaneSessionID(), replacement = PaneSessionID()
        manager.recordPaneSession(session, for: pane)
        manager.markRehydrated(pane)
        try fixture.setListing([session: 111])
        let lookup = Task { @MainActor in await manager.lookupShellPIDForPortScan(for: pane) }
        try await fixture.waitUntilStarted()
        switch change {
        case .remap: manager.recordPaneSession(replacement, for: pane)
        case .recreate:
            manager.destroySurface(terminalID: pane)
            manager.recordPaneSession(session, for: pane)
            manager.markRehydrated(pane)
        case .restoreState: manager.clearRehydrated(pane)
        case .launcher:
            manager.zmxLauncher = ZmxLauncher(executable: URL(fileURLWithPath: "/usr/bin/true"), zmxDir: fixture.directory)
        case .reset: manager.registerForPortScan(pane, resetting: true)
        }
        try fixture.unblock()
        #expect(await lookup.value == nil)
        let currentSession = change == .remap ? replacement : session
        try fixture.setListing([currentSession: 222])
        manager.zmxLauncher = fixture.launcher
        manager.registerForPortScan(pane, resetting: true)
        #expect(await manager.lookupShellPIDForPortScan(for: pane) == 222)
        #expect(manager.lookupShellPID(for: pane) == 222)
    }

    @Test("@spec PORTS-4.10: When one port PID consumer cancels, the application shall discard that consumer's result without cancelling the shared live-session query needed by other panes.")
    func consumerCancellationPreservesSharedQuery() async throws {
        let fixture = try Fixture(blocked: true)
        defer { fixture.remove() }
        let manager = TerminalManager(socketPath: "/tmp/graftty-port-cancel-test.sock")
        manager.zmxLauncher = fixture.launcher
        let first = PaneSlotID(), second = PaneSlotID(), session = PaneSessionID()
        for pane in [first, second] { manager.recordPaneSession(session, for: pane) }
        try fixture.setListing([session: 222])
        let cancelled = Task { @MainActor in await manager.lookupShellPIDForPortScan(for: first) }
        try await fixture.waitUntilStarted()
        let survivor = Task { @MainActor in await manager.lookupShellPIDForPortScan(for: second) }
        cancelled.cancel()
        try fixture.unblock()
        #expect(await cancelled.value == nil)
        #expect(await survivor.value == 222)
        #expect(try String(contentsOf: fixture.calls, encoding: .utf8) == "x")
    }

    @Test("@spec PORTS-4.11: When an initial port PID query is invalidated or its renderer is evicted, the application shall retain pending discovery and resolve the pane on a subsequent scan tick.", arguments: [false, true])
    func initialRegistrationSurvivesQueryInvalidationAndEviction(invalidate: Bool) async throws {
        actor Runner: LsofRunner {
            func run(pids: String) async -> String? {
                "node \(pids) alice 23u IPv4 0x1 0t0 TCP 127.0.0.1:3000 (LISTEN)"
            }
        }
        struct Walker: ProcessTreeWalking {
            func descendants(of root: pid_t) -> [pid_t] { [root] }
        }
        let fixture = try Fixture(blocked: true)
        defer { fixture.remove() }
        let manager = TerminalManager(socketPath: "/tmp/graftty-port-pending-test.sock")
        manager.zmxLauncher = fixture.launcher
        let pane = PaneSlotID(), session = PaneSessionID()
        manager.recordPaneSession(session, for: pane)
        try fixture.setListing([session: 222])
        let scanner = PortScanner(runner: Runner(), walker: Walker())
        manager.portScanner = scanner
        await scanner.setPIDResolver { [weak manager] id in await manager?.lookupShellPIDForPortScan(for: id) }
        manager.registerForPortScan(pane)
        let firstTick = Task {
            for _ in 0..<20 { await Task.yield(); await scanner.tick() }
        }
        try await fixture.waitUntilStarted()
        if invalidate {
            manager.recordPaneSession(PaneSessionID(), for: PaneSlotID())
        } else {
            manager.evictSurface(terminalID: pane)
            manager.recordPaneSession(session, for: pane)
        }
        try fixture.unblock()
        await firstTick.value
        await scanner.tick()
        #expect(await scanner.bindings(for: pane).map(\.pid) == [222])
    }

    @Test func sessionRemappingInvalidatesCachedPIDButSameSessionRetainsIt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let manager = TerminalManager(socketPath: "/tmp/graftty-port-cache-test.sock")
        manager.zmxLauncher = fixture.launcher
        let pane = PaneSlotID(), first = PaneSessionID(), second = PaneSessionID()
        manager.recordPaneSession(first, for: pane)
        try fixture.setListing([first: 111, second: 222])
        #expect(await manager.lookupShellPIDForPortScan(for: pane) == 111)
        manager.recordPaneSession(first, for: pane)
        #expect(manager.lookupShellPID(for: pane) == 111)
        manager.recordPaneSession(second, for: pane)
        #expect(manager.lookupShellPID(for: pane) == nil)
        #expect(await manager.lookupShellPIDForPortScan(for: pane) == 222)
    }

    @Test(arguments: [false, true])
    func replacementObservationInvalidatesAnObsoleteLiveSnapshot(shellReady: Bool) async throws {
        let fixture = try Fixture(blocked: true)
        defer { fixture.remove() }
        try fixture.unblock()
        let manager = TerminalManager(socketPath: "/tmp/graftty-port-obsolete-race-test.sock")
        manager.zmxLauncher = fixture.launcher
        let pane = PaneSlotID(), session = PaneSessionID()
        manager.recordPaneSession(session, for: pane)
        try fixture.setListing([session: 111])
        #expect(await manager.lookupShellPIDForPortScan(for: pane) == 111)
        try fixture.setListing([:])
        manager.registerForPortScan(pane, resetting: true)
        #expect(await manager.lookupShellPIDForPortScan(for: pane) == nil)
        try fixture.setListing([session: 111])
        manager.registerForPortScan(pane, resetting: true)
        try FileManager.default.removeItem(at: fixture.release)
        try FileManager.default.removeItem(at: fixture.started)
        let lookup = Task { @MainActor in await manager.lookupShellPIDForPortScan(for: pane) }
        try await fixture.waitUntilStarted()
        let name = ZmxLauncher.sessionName(for: session)
        let log = fixture.launcher.logFile(forSession: name)
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "pty spawned session=\(name) pid=222\n".write(to: log, atomically: true, encoding: .utf8)
        if shellReady { manager.shellBecameReady(for: pane) }
        else { #expect(manager.lookupShellPID(for: pane) == 222) }
        try fixture.unblock()
        #expect(await lookup.value == nil)
        try fixture.setListing([session: 222])
        #expect(await manager.lookupShellPIDForPortScan(for: pane) == 222)
    }

    @Test func missingSessionRejectsObsoletePIDUntilReplacementAppears() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let manager = TerminalManager(socketPath: "/tmp/graftty-port-obsolete-test.sock")
        manager.zmxLauncher = fixture.launcher
        let pane = PaneSlotID(), session = PaneSessionID()
        manager.recordPaneSession(session, for: pane)
        try fixture.setListing([session: 111])
        #expect(await manager.lookupShellPIDForPortScan(for: pane) == 111)
        for (listing, expected) in [([PaneSessionID: Int32](), nil), ([session: 111], nil), ([session: 222], Int32(222))] {
            try fixture.setListing(listing)
            manager.registerForPortScan(pane, resetting: true)
            #expect(await manager.lookupShellPIDForPortScan(for: pane) == expected)
        }
    }
}
