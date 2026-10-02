import AppKit
import GhosttyKit
import Testing
@testable import Graftty
@testable import GrafttyKit

@MainActor
@Suite(.serialized)
struct TerminalAttachmentRecoveryTests {
    @Test("@spec AGENT-5.23: When CLI creation starts an asynchronous terminal backend, the application shall wait for backend startup acceptance before reporting the worktree ready, and shall report a failed startup instead of releasing ownership of the staged agent prompt.")
    func asynchronousStartupFailureIsAcknowledged() async throws {
        _ = NSApplication.shared
        let manager = TerminalManager(socketPath: "/tmp/graftty-startup-test.sock")
        manager.initialize()
        let id = PaneSlotID()
        manager.zmxLauncher = ZmxLauncher(executable: URL(fileURLWithPath: "/usr/bin/true"), zmxDir: URL(fileURLWithPath: "/tmp/graftty-unused"))
        let handle = try #require(manager.createSurface(terminalID: id, paneSessionID: PaneSessionID(), worktreePath: "/tmp"))
        defer { manager.evictSurface(terminalID: id, forRetry: true) }
        let config = ZmxSpawnConfiguration(sessionName: "startup", argv: ["/nonexistent/graftty-zmx"],
            env: [:], workingDirectory: URL(fileURLWithPath: "/tmp"), shellReadySignalAvailable: false)
        let session = MacPagedZmxSession(surface: handle.surface, configuration: config, initialSize: nil)
        defer { session.close() }
        try session.start()
        #expect(!(await session.waitForStartup()))
        #expect(!(await session.waitForStartup()), "Failed startup remains observable to a late waiter")
    }

    @Test("A command accepted by the shell remains accepted when it exits before startup polling resumes")
    func immediatelyExitedCommandWasAccepted() async throws {
        _ = NSApplication.shared
        let manager = TerminalManager(socketPath: "/tmp/graftty-startup-test.sock")
        manager.initialize()
        let id = PaneSlotID()
        manager.zmxLauncher = ZmxLauncher(executable: URL(fileURLWithPath: "/usr/bin/true"), zmxDir: URL(fileURLWithPath: "/tmp/graftty-unused"))
        let handle = try #require(manager.createSurface(terminalID: id, paneSessionID: PaneSessionID(), worktreePath: "/tmp"))
        defer { manager.evictSurface(terminalID: id, forRetry: true) }
        let executable = try makeFakeZmx(attachCommand: ": > started; /bin/sleep 0.03; : > \"$GRAFTTY_STARTUP_RECEIPT\"; exit 0")
        let root = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = ZmxSpawnConfiguration(sessionName: "startup", argv: [executable.path, "attach"],
            env: ["ZMX_DIR": root.path, "GRAFTTY_STARTUP_RECEIPT": root.appendingPathComponent("accepted").path],
            workingDirectory: root, shellReadySignalAvailable: false)
        let session = MacPagedZmxSession(surface: handle.surface, configuration: config, initialSize: nil)
        defer { session.close() }
        try session.start()
        let deadline = ContinuousClock.now + .seconds(3)
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("started").path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(FileManager.default.fileExists(atPath: root.appendingPathComponent("started").path))
        // Exit callbacks run off-main while the receipt poll is suspended.
        usleep(150_000)
        #expect(await session.waitForStartup())
    }

    @Test("Typing k after an attachment failure does not close the native surface", arguments: [FailureMode.start, .queryUnavailable, .missingDaemon])
    func typingAfterFailureKeepsPane(mode: FailureMode) async throws {
        _ = NSApplication.shared
        #expect(ghostty_init(0, nil) == 0)
        let app = GhosttyApp(config: GhosttyConfig()) { _, _ in true }
        let manager = TerminalManager(socketPath: "/tmp/graftty-attachment-test.sock")
        let id = PaneSlotID()
        let fixture = try makeFakeZmx(attachCommand: "exit 1")
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let executable = mode == .missingDaemon ? fixture.path : "/usr/bin/false"
        let config = ZmxSpawnConfiguration(sessionName: "test", argv: [executable, "attach"],
            env: [:], workingDirectory: URL(fileURLWithPath: "/tmp"), shellReadySignalAvailable: false)
        let backend = HostManagedZmxBackend(spawnConfiguration: config,
            sessionFactory: { surface, config, size in
                if mode != .start { return MacPagedZmxSession(surface: surface, configuration: config, initialSize: size) }
                return FailingSession()
            })
        let handle = try #require(SurfaceHandle(terminalID: id, app: app.app,
            worktreePath: "/tmp", socketPath: manager.socketPath,
            zmxSpawnConfiguration: testSurfaceHandleSpawnConfiguration(), terminalManager: manager,
            zmxBackendFactory: { _, _, _, _ in backend }))
        manager.insertSurfaceForTesting(handle, for: id)
        var closed = false
        manager.onSurfaceClosed = { _ in closed = true }
        #expect(handle.startForBackgroundLaunch() == (mode != .start))
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while manager.attachmentFailures[id] == nil, ContinuousClock.now < deadline {
            app.tick()
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(manager.attachmentFailures[id] != nil)
        var key = ghostty_input_key_s()
        key.action = GHOSTTY_ACTION_PRESS
        key.keycode = 40 // macOS virtual key for k
        key.unshifted_codepoint = 107
        "k".withCString {
            key.text = $0
            _ = ghostty_surface_key(handle.surface, key)
        }
        for _ in 0..<20 {
            app.tick()
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!closed)
        #expect(manager.handle(for: id) === handle)
        withExtendedLifetime(app) {}
    }

    @Test("@spec TERM-5.12: When the user retries a failed terminal attachment, the application shall preserve the pane identity and session mapping, and ignore failure or close callbacks from its replaced surface.")
    func retryPreservesIdentityAndRejectsStaleCallbacks() throws {
        _ = NSApplication.shared
        let manager = TerminalManager(socketPath: "/tmp/graftty-attachment-test.sock")
        manager.initialize()
        // Real host-managed surfaces, but no layout/start and no real daemon.
        manager.zmxLauncher = ZmxLauncher(executable: URL(fileURLWithPath: "/usr/bin/false"),
            zmxDir: URL(fileURLWithPath: "/tmp/graftty-attachment-unused"))
        let id = PaneSlotID()
        defer { manager.evictSurface(terminalID: id, forRetry: true) }
        let session = PaneSessionID()
        let old = try #require(manager.createSurface(terminalID: id, paneSessionID: session,
            worktreePath: "/tmp"))
        let userdata = try #require(ghostty_surface_userdata(old.surface))
        let oldBox = Unmanaged<SurfaceUserdataBox>.fromOpaque(userdata).takeUnretainedValue()
        _ = manager.recordTitle("Existing terminal", for: id)
        // PWD reassignment changes the owner while preserving the surface.
        manager.recordPaneSession(session, for: id, worktreePath: "/tmp/new-owner")
        manager.recordAttachmentFailure("Disconnected", for: old)
        var closes = 0
        manager.onSurfaceClosed = { _ in closes += 1 }
        #expect(manager.retryAttachment(for: id))
        let replacement = try #require(manager.handle(for: id))
        #expect(replacement !== old)
        #expect(replacement.terminalID == id)
        #expect(replacement.worktreePath == "/tmp/new-owner")
        #expect(manager.worktreePath(forSessionName: ZmxLauncher.sessionName(for: session)) == "/tmp/new-owner")
        #expect(manager.zmxSessionName(for: id) == ZmxLauncher.sessionName(for: session))
        #expect(manager.titles[id] == "Existing terminal")
        #expect(manager.wasRehydrated(id))
        #expect(manager.attachmentFailures[id] == nil)
        manager.receiveSurfaceClosed(oldBox)
        manager.recordAttachmentFailure("Late failure", for: old)
        #expect(closes == 0)
        #expect(manager.attachmentFailures[id] == nil)
        let currentBox = Unmanaged<SurfaceUserdataBox>.fromOpaque(
            try #require(ghostty_surface_userdata(replacement.surface))).takeUnretainedValue()
        manager.receiveSurfaceClosed(currentBox)
        #expect(closes == 1, "Current-surface close requests still work")
    }

    @Test("Retry allocation failure keeps the failed pane available for another retry")
    func retryAllocationFailurePreservesPane() throws {
        _ = NSApplication.shared
        let manager = TerminalManager(socketPath: "/tmp/graftty-attachment-test.sock")
        manager.initialize()
        manager.zmxLauncher = ZmxLauncher(executable: URL(fileURLWithPath: "/usr/bin/false"),
            zmxDir: URL(fileURLWithPath: "/tmp/graftty-attachment-unused"))
        let id = PaneSlotID()
        defer { manager.evictSurface(terminalID: id, forRetry: true) }
        let old = try #require(manager.createSurface(terminalID: id, paneSessionID: PaneSessionID(), worktreePath: "/tmp"))
        manager.recordAttachmentFailure("Disconnected", for: old)
        manager.ptyDeviceAvailability = { .unavailable }
        #expect(!manager.retryAttachment(for: id))
        #expect(manager.handle(for: id) === old)
        #expect(manager.attachmentFailures[id] != nil)
        manager.ptyDeviceAvailability = { .available }
        #expect(manager.retryAttachment(for: id))
        #expect(manager.handle(for: id) !== old)
    }

    @Test("Normal legacy completion preserves elapsed runtime and closes the surface")
    func normalLegacyExitClosesPane() async throws {
        _ = NSApplication.shared
        #expect(ghostty_init(0, nil) == 0)
        let app = GhosttyApp(config: GhosttyConfig()) { _, _ in true }
        let manager = TerminalManager(socketPath: "/tmp/graftty-attachment-test.sock")
        let fixture = try makeFakeZmx(attachCommand: "sleep 0.4; exit 0")
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let id = PaneSlotID()
        let config = ZmxSpawnConfiguration(sessionName: "test", argv: [fixture.path, "attach"],
            env: [:], workingDirectory: URL(fileURLWithPath: "/tmp"), shellReadySignalAvailable: false)
        let backend = HostManagedZmxBackend(spawnConfiguration: config)
        let handle = try #require(SurfaceHandle(terminalID: id, app: app.app,
            worktreePath: "/tmp", socketPath: manager.socketPath,
            zmxSpawnConfiguration: config, terminalManager: manager,
            zmxBackendFactory: { _, _, _, _ in backend }))
        manager.insertSurfaceForTesting(handle, for: id)
        var closed = false
        manager.onSurfaceClosed = { _ in closed = true }
        #expect(handle.startForBackgroundLaunch())
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !closed, ContinuousClock.now < deadline {
            app.tick()
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(closed)
        #expect(manager.attachmentFailures[id] == nil)
        withExtendedLifetime(app) {}
    }

    @Test("""
    @spec TERM-5.13: When attachment recovery confirms that the previous daemon is gone, the application shall reset shell readiness and exclude the previous shell PID until a replacement shell is observed.
    """)
    func retryMissingDaemonResetsShellState() throws {
        _ = NSApplication.shared
        let fixture = try makeFakeZmx(attachCommand: "exit 1")
        let directory = fixture.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = TerminalManager(socketPath: "/tmp/graftty-attachment-test.sock")
        manager.initialize()
        let launcher = ZmxLauncher(executable: fixture, zmxDir: directory)
        manager.zmxLauncher = launcher
        let id = PaneSlotID()
        defer { manager.evictSurface(terminalID: id, forRetry: true) }
        let session = PaneSessionID()
        let name = ZmxLauncher.sessionName(for: session)
        let log = launcher.logFile(forSession: name)
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "pty spawned session=\(name) pid=111\n".write(to: log, atomically: true, encoding: .utf8)
        let old = try #require(manager.createSurface(terminalID: id, paneSessionID: session, worktreePath: "/tmp"))
        var ready = 0
        manager.onShellReady = { _ in ready += 1 }
        manager.shellBecameReady(for: id)
        #expect(manager.lookupShellPID(for: id) == 111)
        manager.recordAttachmentFailure("Disconnected", for: old)
        #expect(manager.retryAttachment(for: id))
        #expect(manager.lookupShellPID(for: id) == nil, "An old log must not repopulate the PID cache")
        try "pty spawned session=\(name) pid=222\n".write(to: log, atomically: true, encoding: .utf8)
        #expect(manager.lookupShellPID(for: id) == 222)
        manager.shellBecameReady(for: id)
        #expect(ready == 2, "The replacement shell must initialize normally")
    }

    enum FailureMode: Sendable { case start, queryUnavailable, missingDaemon }

    private func makeFakeZmx(attachCommand: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("zmx")
        try "#!/bin/sh\nif [ \"$1\" = list ]; then exit 0; fi\n\(attachCommand)\n"
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }

    private final class FailingSession: HostManagedZmxSession {
        struct Failure: Error {}
        func start() throws { throw Failure() }
        func write(_ data: Data) throws {}
        func resize(cols: UInt16, rows: UInt16) throws {}
        func close() {}
    }
}
