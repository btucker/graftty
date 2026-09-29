import AppKit
import GhosttyKit
import Testing
@testable import Graftty
@testable import GrafttyKit

@MainActor
@Suite(.serialized)
struct TerminalAttachmentRecoveryTests {
    @Test("Typing k after an attachment failure does not close the native surface", arguments: [false, true])
    func typingAfterFailureKeepsPane(legacyProcessExit: Bool) async throws {
        _ = NSApplication.shared
        #expect(ghostty_init(0, nil) == 0)
        let app = GhosttyApp(config: GhosttyConfig()) { _, _ in true }
        let manager = TerminalManager(socketPath: "/tmp/graftty-attachment-test.sock")
        let id = PaneSlotID()
        let config = ZmxSpawnConfiguration(sessionName: "test", argv: ["/usr/bin/false"],
            env: [:], workingDirectory: URL(fileURLWithPath: "/tmp"), shellReadySignalAvailable: false)
        let backend = HostManagedZmxBackend(spawnConfiguration: config,
            sessionFactory: { surface, config, size in
                if legacyProcessExit { return MacPagedZmxSession(surface: surface, configuration: config, initialSize: size) }
                return FailingSession()
            })
        let handle = try #require(SurfaceHandle(terminalID: id, app: app.app,
            worktreePath: "/tmp", socketPath: manager.socketPath,
            zmxSpawnConfiguration: testSurfaceHandleSpawnConfiguration(), terminalManager: manager,
            zmxBackendFactory: { _, _, _, _ in backend }))
        manager.insertSurfaceForTesting(handle, for: id)
        var closed = false
        manager.onSurfaceClosed = { _ in closed = true }
        #expect(handle.startForBackgroundLaunch() == legacyProcessExit)
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
        manager.recordAttachmentFailure("Disconnected", for: old)
        var closes = 0
        manager.onSurfaceClosed = { _ in closes += 1 }
        #expect(manager.retryAttachment(for: id))
        let replacement = try #require(manager.handle(for: id))
        #expect(replacement !== old)
        #expect(replacement.terminalID == id)
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

    private final class FailingSession: HostManagedZmxSession {
        struct Failure: Error {}
        func start() throws { throw Failure() }
        func write(_ data: Data) throws {}
        func resize(cols: UInt16, rows: UInt16) throws {}
        func close() {}
    }
}
