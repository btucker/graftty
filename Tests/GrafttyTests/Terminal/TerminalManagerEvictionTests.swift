import AppKit
import Foundation
import GhosttyKit
import Testing
@testable import Graftty
@testable import GrafttyKit

@MainActor
@Suite("TerminalManager.evictSurface")
struct TerminalManagerEvictionTests {

    @Test("@spec PORTS-5.12: When a pane's daemon log lacks a shell-spawn record, the application shall resolve its shell PID from the live daemon session listing and discover its listening ports.", arguments: [false, true])
    func liveSessionPIDResolvesWithoutSpawnLog(restoring: Bool) async throws {
        actor Runner: LsofRunner {
            func run(pids: String) async -> String? {
                pids == "1234" ? "node 1234 alice 23u IPv4 0x1 0t0 TCP 127.0.0.1:3000 (LISTEN)" : ""
            }
        }
        struct Walker: ProcessTreeWalking {
            func descendants(of root: pid_t) -> [pid_t] { [root] }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("zmx")
        let pane = PaneSlotID(), session = PaneSessionID()
        let name = ZmxLauncher.sessionName(for: session)
        try "#!/bin/sh\nprintf '→ name=\(name)\\tpid=1234\\tclients=0\\n'\n"
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let manager = TerminalManager(socketPath: "/tmp/graftty-port-live-pid-test.sock")
        manager.zmxLauncher = ZmxLauncher(executable: executable, zmxDir: directory)
        manager.recordPaneSession(session, for: pane)
        if restoring { manager.markRehydrated(pane) }
        let scanner = PortScanner(runner: Runner(), walker: Walker())
        await scanner.setPIDResolver { [weak manager] id in await manager?.lookupShellPIDForPortScan(for: id) }
        await scanner.registerPanePending(pane)
        await scanner.tick()
        #expect(await scanner.bindings(for: pane).map(\.port) == [3000])
    }

    @Test func resettingPortRegistrationDiscardsCachedLiveListing() async throws {
        actor Runner: LsofRunner {
            func run(pids: String) async -> String? { "" }
        }
        struct Walker: ProcessTreeWalking {
            func descendants(of root: pid_t) -> [pid_t] { [root] }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("zmx")
        let listing = directory.appendingPathComponent("listing")
        try "#!/bin/sh\n/bin/cat '\(listing.path)'\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let manager = TerminalManager(socketPath: "/tmp/graftty-port-reset-test.sock")
        manager.zmxLauncher = ZmxLauncher(executable: executable, zmxDir: directory)
        manager.portScanner = PortScanner(runner: Runner(), walker: Walker())
        let first = PaneSlotID(), second = PaneSlotID()
        let firstSession = PaneSessionID(), secondSession = PaneSessionID()
        let firstName = ZmxLauncher.sessionName(for: firstSession), secondName = ZmxLauncher.sessionName(for: secondSession)
        manager.recordPaneSession(firstSession, for: first)
        manager.recordPaneSession(secondSession, for: second)
        try "name=\(firstName)\tpid=111\nname=\(secondName)\tpid=222\n".write(to: listing, atomically: true, encoding: .utf8)
        #expect(await manager.lookupShellPIDForPortScan(for: first) == 111)
        try "name=\(firstName)\tpid=111\nname=\(secondName)\tpid=333\n".write(to: listing, atomically: true, encoding: .utf8)
        manager.registerForPortScan(second, resetting: true)
        #expect(await manager.lookupShellPIDForPortScan(for: second) == 333)
    }

    @Test func restoredLivePIDOverridesHistoricalLog() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("zmx")
        let pane = PaneSlotID(), session = PaneSessionID()
        let name = ZmxLauncher.sessionName(for: session)
        try "#!/bin/sh\nprintf 'name=\(name)\\tpid=222\\n'\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let launcher = ZmxLauncher(executable: executable, zmxDir: directory)
        let log = launcher.logFile(forSession: name)
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "pty spawned session=\(name) pid=111\n".write(to: log, atomically: true, encoding: .utf8)
        let manager = TerminalManager(socketPath: "/tmp/graftty-port-historical-test.sock")
        manager.zmxLauncher = launcher
        manager.recordPaneSession(session, for: pane)
        manager.markRehydrated(pane)
        #expect(await manager.lookupShellPIDForPortScan(for: pane) == 222)
    }

    @Test("@spec PORTS-4.8: If a pane session changes during asynchronous port registration, then the application shall discard the obsolete session result without restoring a destroyed pane or invalidating a replacement shell.", arguments: [false, true])
    func asynchronousRegistrationDiscardsChangedSessions(replacing: Bool) async throws {
        actor Runner: LsofRunner {
            func run(pids: String) async -> String? { "" }
        }
        struct Walker: ProcessTreeWalking {
            func descendants(of root: pid_t) -> [pid_t] { [root] }
        }
        actor Resolver {
            var calls = 0
            func resolve() -> pid_t? { calls += 1; return 1234 }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("zmx")
        let started = directory.appendingPathComponent("started")
        try "#!/bin/sh\n[ \"$1\" = list ] || exit 0\n: > '\(started.path)'\n/bin/sleep 0.1\n"
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let launcher = ZmxLauncher(executable: executable, zmxDir: directory)
        let manager = TerminalManager(socketPath: "/tmp/graftty-port-query-race-test.sock")
        manager.zmxLauncher = launcher
        let pane = PaneSlotID(), session = PaneSessionID()
        manager.recordPaneSession(session, for: pane)
        manager.markRehydrated(pane)
        let scanner = PortScanner(runner: Runner(), walker: Walker())
        manager.portScanner = scanner
        let resolver = Resolver()
        await scanner.setPIDResolver { _ in await resolver.resolve() }
        let lookup = Task { @MainActor in await manager.lookupShellPIDForPortScan(for: pane) }
        if !replacing { manager.registerForPortScan(pane) }
        let deadline = ContinuousClock.now + .seconds(3)
        while !FileManager.default.fileExists(atPath: started.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(FileManager.default.fileExists(atPath: started.path))
        if replacing {
            manager.clearRehydrated(pane)
            let name = ZmxLauncher.sessionName(for: session)
            let log = launcher.logFile(forSession: name)
            try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "pty spawned session=\(name) pid=222\n".write(to: log, atomically: true, encoding: .utf8)
            #expect(await lookup.value == 222)
            #expect(manager.lookupShellPID(for: pane) == 222)
        } else {
            manager.destroySurface(terminalID: pane)
            #expect(await lookup.value == nil)
            for _ in 0..<20 { await Task.yield(); await scanner.tick() }
            #expect(await resolver.calls == 0)
        }
    }

    @Test("@spec PORTS-5.11: While resolving restored pane ports, the application shall share live-session queries across panes and perform those queries off the main actor.")
    func restoredPortSessionQueriesAreSharedAndDoNotBlockUI() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("zmx")
        let calls = directory.appendingPathComponent("calls")
        let first = PaneSlotID(), second = PaneSlotID(), session = PaneSessionID()
        let name = ZmxLauncher.sessionName(for: session)
        try "#!/bin/sh\n/bin/sleep 0.05\nprintf x >> '\(calls.path)'\nprintf 'name=\(name)\\tpid=1234\\tclients=0\\n'\n"
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let launcher = ZmxLauncher(executable: executable, zmxDir: directory)
        let manager = TerminalManager(socketPath: "/tmp/graftty-port-query-test.sock")
        manager.zmxLauncher = launcher
        for pane in [first, second] {
            manager.recordPaneSession(session, for: pane)
            manager.markRehydrated(pane)
        }
        let log = launcher.logFile(forSession: name)
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "pty spawned session=\(name) pid=1234\n".write(to: log, atomically: true, encoding: .utf8)
        var progressed = false
        let progress = Task { @MainActor in progressed = true }
        let firstPID = await manager.lookupShellPIDForPortScan(for: first)
        #expect(firstPID == 1234)
        #expect(progressed)
        await progress.value
        #expect(await manager.lookupShellPIDForPortScan(for: second) == 1234)
        #expect(try String(contentsOf: calls, encoding: .utf8) == "x")
    }

    @Test("@spec PORTS-5.10: When restoring an unselected worktree whose pane session is absent, the application shall exclude historical shell PIDs from port discovery until a live session is confirmed.")
    func absentRestoredSessionDoesNotScanHistoricalPID() async throws {
        actor Runner: LsofRunner {
            func run(pids: String) async -> String? {
                "node 1234 alice 23u IPv4 0x1 0t0 TCP 127.0.0.1:3000 (LISTEN)"
            }
        }
        struct Walker: ProcessTreeWalking {
            func descendants(of root: pid_t) -> [pid_t] { [root] }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let launcher = ZmxLauncher(executable: URL(fileURLWithPath: "/usr/bin/true"), zmxDir: directory)
        let manager = TerminalManager(socketPath: "/tmp/graftty-port-restore-test.sock")
        manager.zmxLauncher = launcher
        let pane = PaneSlotID(), session = PaneSessionID()
        let name = ZmxLauncher.sessionName(for: session)
        let log = launcher.logFile(forSession: name)
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "pty spawned session=\(name) pid=1234\n".write(to: log, atomically: true, encoding: .utf8)
        var worktree = WorktreeEntry(path: "/repo/ports", branch: "ports", state: .running)
        worktree.splitTree = SplitTree(root: .leaf(pane))
        worktree.paneSessions[pane] = session
        let scanner = PortScanner(runner: Runner(), walker: Walker())
        manager.portScanner = scanner
        await scanner.setPIDResolver { [weak manager] id in await manager?.lookupShellPIDForPortScan(for: id) }
        GrafttyApp.prepareRunningWorktreeForRestore(&worktree, terminalManager: manager)
        for _ in 0..<20 { await Task.yield(); await scanner.tick() }
        #expect(await scanner.bindings(for: pane).isEmpty)
    }

    @Test("@spec PORTS-5.9: While a running worktree retains its pane sessions after restoration or surface eviction, the application shall continue discovering its listening ports independently of whether its terminal views are loaded.")
    func discoverySurvivesEvictionAndUnselectedRestore() async throws {
        actor Runner: LsofRunner {
            func run(pids: String) async -> String? {
                "node 1234 alice 23u IPv4 0x1 0t0 TCP 127.0.0.1:3000 (LISTEN)"
            }
        }
        struct Walker: ProcessTreeWalking {
            func descendants(of root: pid_t) -> [pid_t] { [root] }
        }
        for restoring in [false, true] {
            let manager = TerminalManager(socketPath: "/tmp/graftty-port-lifecycle-test.sock")
            let scanner = PortScanner(runner: Runner(), walker: Walker())
            manager.portScanner = scanner
            await scanner.setPIDResolver { _ in 1234 }
            var worktree = WorktreeEntry(path: "/repo/ports", branch: "ports", state: .running)
            let pane = PaneSlotID()
            worktree.splitTree = SplitTree(root: .leaf(pane))
            if restoring {
                GrafttyApp.prepareRunningWorktreeForRestore(&worktree, terminalManager: manager)
                // Registration runs asynchronously on the scanner actor.
                for _ in 0..<20 { await Task.yield(); await scanner.tick() }
            } else {
                await scanner.registerPane(pane, shellPID: 1234)
                await scanner.tick()
                manager.evictSurface(terminalID: pane)
                for _ in 0..<20 { await Task.yield(); await scanner.tick() }
            }
            #expect(await scanner.bindings(for: pane).map(\.port) == [3000])
            #expect(manager.handle(for: pane) == nil)
            manager.destroySurface(terminalID: pane)
            for _ in 0..<20 { await Task.yield(); await scanner.tick() }
            #expect(await scanner.bindings(for: pane).isEmpty)
        }
    }

    @Test("""
@spec MEM-1.2: When a worktree's surfaces are evicted via the LRU budget, the application shall preserve its zmx sessions, pane-to-session mapping, titles, PWDs, and rehydration state so re-selection re-attaches transparently.
""")
    func evictPreservesMetadata() {
        let manager = TerminalManager(socketPath: "/tmp/graftty-evict-test.sock")
        let terminalID = PaneSlotID(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!)
        let sessionID = PaneSessionID(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!)

        manager.recordPaneSession(sessionID, for: terminalID)
        _ = manager.recordTitle("claude", for: terminalID)
        _ = manager.recordPWD("/repo/work", for: terminalID)
        manager.markFirstPane(terminalID)

        manager.evictSurface(terminalID: terminalID)

        #expect(manager.titles[terminalID] == "claude")
        #expect(manager.pwds[terminalID] == "/repo/work")
        #expect(manager.zmxSessionName(for: terminalID) != nil)
        #expect(manager.isFirstPane(terminalID))
        #expect(manager.wasRehydrated(terminalID))
    }

    @Test("""
@spec MEM-1.5: When the LRU budget evicts a worktree, the application shall not kill its zmx sessions or fire `paneClosed` callbacks.
""")
    func evictDoesNotFirePaneClosed() {
        let manager = TerminalManager(socketPath: "/tmp/graftty-evict-test.sock")
        let terminalID = PaneSlotID(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!)
        let sessionID = PaneSessionID(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!)
        manager.recordPaneSession(sessionID, for: terminalID)

        var paneClosedCalls: [(PaneSlotID, String?)] = []
        manager.paneClosed = { id, name in paneClosedCalls.append((id, name)) }

        manager.evictSurface(terminalID: terminalID)

        #expect(paneClosedCalls.isEmpty)
    }

    @Test func evictWithoutSurfaceStillMarksRehydrated() {
        // Defensive: if the budget asks to evict a leaf that never had a
        // surface materialized (e.g. it lived in an unselected worktree),
        // the rehydration flag still gets set so a future surface creation
        // takes the zmx-attach path.
        let manager = TerminalManager(socketPath: "/tmp/graftty-evict-test.sock")
        let terminalID = PaneSlotID(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A3")!)
        #expect(!manager.wasRehydrated(terminalID))
        manager.evictSurface(terminalID: terminalID)
        #expect(manager.wasRehydrated(terminalID))
    }

    @Test("""
    @spec MEM-1.6: When the LRU budget evicts a worktree's surfaces, the application shall capture each evicted pane's current grid size (columns, rows, pixel width, pixel height) for use on subsequent re-attach.
    """)
    func evictCapturesGridSizeFromLiveSurface() throws {
        let manager = TerminalManager(socketPath: "/tmp/graftty-evict-size-test.sock")
        let terminalID = PaneSlotID(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!)
        let sessionID = PaneSessionID(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!)
        manager.recordPaneSession(sessionID, for: terminalID)

        let backend = FakeSurfaceHandleZmxBackend()
        let harness = SurfaceHandleTestHarness(surface: fakeSurface())
        harness.sizeStub = .testSize132x43

        let handle = try #require(SurfaceHandle(
            terminalID: terminalID,
            app: fakeApp(),
            worktreePath: "/tmp/worktree",
            socketPath: "/tmp/graftty.sock",
            zmxSpawnConfiguration: testSurfaceHandleSpawnConfiguration(),
            surfaceFactory: harness.factory,
            zmxBackendFactory: { _, _, _, _ in backend }
        ))
        manager.insertSurfaceForTesting(handle, for: terminalID)

        manager.evictSurface(terminalID: terminalID)

        let cached = try #require(manager.evictedGridSize(for: terminalID))
        #expect(cached.cols == 132)
        #expect(cached.rows == 43)
        #expect(cached.widthPx == 1584)
        #expect(cached.heightPx == 688)
    }

    @Test func zeroGridSizeIsDiscardedAndNotCached() throws {
        let manager = TerminalManager(socketPath: "/tmp/graftty-evict-size-test.sock")
        let terminalID = PaneSlotID(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000C2")!)
        manager.recordPaneSession(PaneSessionID(), for: terminalID)

        let backend = FakeSurfaceHandleZmxBackend()
        let harness = SurfaceHandleTestHarness(surface: fakeSurface())
        // sizeStub defaults to (0, 0, ...) — represents "never laid out"

        let handle = try #require(SurfaceHandle(
            terminalID: terminalID,
            app: fakeApp(),
            worktreePath: "/tmp/worktree",
            socketPath: "/tmp/graftty.sock",
            zmxSpawnConfiguration: testSurfaceHandleSpawnConfiguration(),
            surfaceFactory: harness.factory,
            zmxBackendFactory: { _, _, _, _ in backend }
        ))
        manager.insertSurfaceForTesting(handle, for: terminalID)

        manager.evictSurface(terminalID: terminalID)

        #expect(manager.evictedGridSize(for: terminalID) == nil)
    }

    @Test("""
@spec MEM-1.9: When a previously-evicted pane is destroyed (rather than re-attached), the application shall drop its captured grid size from the cache.
""")
    func destroyClearsEvictedGridSize() throws {
        let manager = TerminalManager(socketPath: "/tmp/graftty-destroy-cache-test.sock")
        let terminalID = PaneSlotID(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000C3")!)
        manager.recordPaneSession(PaneSessionID(), for: terminalID)

        let backend = FakeSurfaceHandleZmxBackend()
        let harness = SurfaceHandleTestHarness(surface: fakeSurface())
        harness.sizeStub = ghostty_surface_size_s(
            columns: 120, rows: 40, width_px: 1440, height_px: 640,
            cell_width_px: 12, cell_height_px: 16
        )
        let handle = try #require(SurfaceHandle(
            terminalID: terminalID,
            app: fakeApp(),
            worktreePath: "/tmp/worktree",
            socketPath: "/tmp/graftty.sock",
            zmxSpawnConfiguration: testSurfaceHandleSpawnConfiguration(),
            surfaceFactory: harness.factory,
            zmxBackendFactory: { _, _, _, _ in backend }
        ))
        manager.insertSurfaceForTesting(handle, for: terminalID)

        manager.evictSurface(terminalID: terminalID)
        #expect(manager.evictedGridSize(for: terminalID) != nil)

        manager.destroySurface(terminalID: terminalID)
        #expect(manager.evictedGridSize(for: terminalID) == nil)
    }
}
