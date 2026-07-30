import Combine
import Foundation
import Testing
@testable import Graftty
@testable import GrafttyKit

@MainActor
@Suite("TerminalManager pane metadata")
struct TerminalManagerMetadataTests {

    @Test("""
@spec LAYOUT-2.19: When repeated terminal title or PWD actions leave a pane's rendered sidebar title unchanged, the application shall retain the latest raw metadata without publishing a sidebar invalidation.
""")
    func rawPWDUpdatesWithoutPublishingWhenRenderedTitleIsUnchanged() {
        let manager = TerminalManager(socketPath: "/tmp/graftty-test.sock")
        let terminalID = PaneSlotID(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        var publishCount = 0
        let cancellable = manager.paneTitleInvalidations.objectWillChange.sink { publishCount += 1 }

        #expect(manager.recordPWD("/tmp/work", for: terminalID))
        #expect(manager.displayTitle(for: terminalID) == "work")
        #expect(manager.pwds[terminalID] == "/tmp/work")
        #expect(manager.paneTitleInvalidations.flushPendingForTests())
        #expect(publishCount == 1)

        #expect(!manager.recordPWD("/var/work", for: terminalID))
        #expect(manager.displayTitle(for: terminalID) == "work")
        #expect(manager.pwds[terminalID] == "/var/work")
        #expect(!manager.paneTitleInvalidations.flushPendingForTests())
        #expect(publishCount == 1)

        _ = cancellable
    }

    @Test("""
@spec LAYOUT-2.20: While a program-set pane title is the rendered sidebar title, incoming PWD actions shall update the raw pane PWD without publishing sidebar invalidations.
""")
    func pwdUpdatesUnderProgramTitleDoNotPublishSidebarTitleChanges() {
        let manager = TerminalManager(socketPath: "/tmp/graftty-test.sock")
        let terminalID = PaneSlotID(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        var publishCount = 0
        let cancellable = manager.paneTitleInvalidations.objectWillChange.sink { publishCount += 1 }

        #expect(manager.recordTitle("claude", for: terminalID))
        #expect(manager.displayTitle(for: terminalID) == "claude")
        #expect(manager.paneTitleInvalidations.flushPendingForTests())
        #expect(publishCount == 1)

        #expect(!manager.recordPWD("/tmp/work", for: terminalID))
        #expect(manager.displayTitle(for: terminalID) == "claude")
        #expect(manager.pwds[terminalID] == "/tmp/work")
        #expect(!manager.paneTitleInvalidations.flushPendingForTests())
        #expect(publishCount == 1)

        _ = cancellable
    }

    @Test("""
@spec LAYOUT-2.21: When a terminal title action sanitizes to a rendered sidebar title equal to the current fallback title, the application shall store the raw title without publishing a sidebar invalidation.
""")
    func whitespaceTitleStoresWithoutPublishingWhenFallbackTitleIsUnchanged() {
        let manager = TerminalManager(socketPath: "/tmp/graftty-test.sock")
        let terminalID = PaneSlotID(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
        var publishCount = 0
        let cancellable = manager.paneTitleInvalidations.objectWillChange.sink { publishCount += 1 }

        #expect(manager.recordPWD("/tmp/work", for: terminalID))
        #expect(manager.displayTitle(for: terminalID) == "work")
        #expect(manager.paneTitleInvalidations.flushPendingForTests())
        #expect(publishCount == 1)

        #expect(!manager.recordTitle("   ", for: terminalID))
        #expect(manager.titles[terminalID] == "   ")
        #expect(manager.displayTitle(for: terminalID) == "work")
        #expect(!manager.paneTitleInvalidations.flushPendingForTests())
        #expect(publishCount == 1)

        _ = cancellable
    }

    @Test("""
@spec PERF-1.6: Pane title metadata changes shall not publish through TerminalManager itself, so title churn does not invalidate MainWindow observers.
""")
    func paneTitleChangesDoNotPublishTerminalManagerObjectWillChange() {
        let manager = TerminalManager(socketPath: "/tmp/graftty-test.sock")
        let terminalID = PaneSlotID(id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!)
        var managerPublishCount = 0
        let cancellable = manager.objectWillChange.sink { managerPublishCount += 1 }

        #expect(manager.recordTitle("claude", for: terminalID))
        #expect(manager.paneTitleInvalidations.flushPendingForTests())
        #expect(managerPublishCount == 0)

        _ = cancellable
    }

    @Test("""
@spec PERF-1.7: Multiple rendered pane-title changes in one debounce window shall coalesce into one sidebar invalidation.
""")
    func paneTitleInvalidationsCoalesce() {
        let manager = TerminalManager(socketPath: "/tmp/graftty-test.sock")
        let terminalID = PaneSlotID(id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!)
        var publishCount = 0
        let cancellable = manager.paneTitleInvalidations.objectWillChange.sink { publishCount += 1 }

        #expect(manager.recordTitle("one", for: terminalID))
        #expect(manager.recordTitle("two", for: terminalID))
        #expect(manager.recordTitle("three", for: terminalID))
        #expect(manager.paneTitleInvalidations.flushPendingForTests())
        #expect(publishCount == 1)
        #expect(manager.displayTitle(for: terminalID) == "three")

        _ = cancellable
    }

    @Test func zmxSpawnConfigurationUsesPaneSessionIDNotSlotID() throws {
        let manager = TerminalManager(socketPath: "/tmp/graftty-test.sock")
        manager.zmxLauncher = ZmxLauncher(
            executable: URL(fileURLWithPath: "/bin/sh"),
            zmxDir: URL(fileURLWithPath: "/tmp/zmx-dir", isDirectory: true)
        )
        let slotID = PaneSlotID(id: UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000000")!)
        let sessionID = PaneSessionID(id: UUID(uuidString: "01234567-89AB-CDEF-FEDC-BA9876543210")!)

        let config = try #require(manager.resolveZmxSpawnConfiguration(
            for: slotID,
            paneSessionID: sessionID,
            worktreePath: "/tmp/worktree"
        ))

        #expect(config.sessionName == "graftty-01234567")
        #expect(config.argv[2] == "graftty-01234567")
    }

    @Test func liveZmxSessionNameUsesRecordedPaneSessionIDNotSlotID() {
        let manager = TerminalManager(socketPath: "/tmp/graftty-test.sock")
        let slotID = PaneSlotID(id: UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000000")!)
        let sessionID = PaneSessionID(id: UUID(uuidString: "01234567-89AB-CDEF-FEDC-BA9876543210")!)

        manager.recordPaneSession(sessionID, for: slotID)

        #expect(manager.zmxSessionName(for: slotID) == "graftty-01234567")
    }

    @Test func currentSessionNameChangesWhenSlotGetsNewSession() {
        let manager = TerminalManager(socketPath: "/tmp/graftty-test.sock")
        let slot = PaneSlotID(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let first = PaneSessionID(id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000000")!)
        let second = PaneSessionID(id: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000000")!)

        manager.recordPaneSession(first, for: slot)
        #expect(manager.paneID(forSessionName: "graftty-aaaaaaaa") == slot.id)

        manager.recordPaneSession(second, for: slot)
        #expect(manager.paneID(forSessionName: "graftty-aaaaaaaa") == nil)
        #expect(manager.paneID(forSessionName: "graftty-bbbbbbbb") == slot.id)
    }

    @Test("""
    @spec REMOTE-13.16: When a remote client wins the race to create a pane's \
    zmx daemon, the host shall start that daemon in the pane's owning \
    worktree directory.
    """)
    func sessionLookupRetainsOwningWorktreeForRemoteAttach() {
        let manager = TerminalManager(socketPath: "/tmp/graftty-test.sock")
        let slot = PaneSlotID()
        let session = PaneSessionID(
            id: UUID(
                uuidString: "CCCCCCCC-0000-0000-0000-000000000000"
            )!
        )

        manager.recordPaneSession(
            session,
            for: slot,
            worktreePath: "/repos/app/.worktrees/feature"
        )

        #expect(
            manager.worktreePath(forSessionName: "graftty-cccccccc")
                == "/repos/app/.worktrees/feature"
        )
    }

    @Test("failable surfaces retain authoritative metadata until rollback")
    func failableSurfaceMetadataCanBeExplicitlyDiscarded() {
        let manager = TerminalManager(socketPath: "/tmp/graftty-test.sock")
        let slot = PaneSlotID()
        let session = PaneSessionID(
            id: UUID(
                uuidString: "DDDDDDDD-0000-0000-0000-000000000000"
            )!
        )

        #expect(manager.createSurface(
            terminalID: slot,
            paneSessionID: session,
            worktreePath: "/repos/app/.worktrees/feature"
        ) == nil)
        #expect(
            manager.paneID(forSessionName: "graftty-dddddddd") == slot.id
        )

        manager.discardPaneSessionMetadata(for: slot)
        #expect(
            manager.paneID(forSessionName: "graftty-dddddddd") == nil
        )
    }

    @Test("Explicit worktree launch waits for first shell-ready signal and is delivered once")
    func explicitLaunchWaitsForFirstShellReadySignal() async throws {
        let manager = TerminalManager(socketPath: "/tmp/graftty-test.sock")
        let terminalID = PaneSlotID()
        let backend = FakeSurfaceHandleZmxBackend()
        let harness = SurfaceHandleTestHarness(surface: fakeSurface())
        let handle = try #require(SurfaceHandle(
            terminalID: terminalID,
            app: fakeApp(),
            worktreePath: "/tmp/worktree",
            socketPath: "/tmp/graftty.sock",
            zmxSpawnConfiguration: testSurfaceHandleSpawnConfiguration(),
            surfaceFactory: harness.factory,
            hostManagedBackend: backend
        ))
        manager.insertSurfaceForTesting(handle, for: terminalID)
        manager.queueInitialInputUntilShellReadyForTesting(
            "claude -- task\r",
            for: terminalID
        )

        #expect(handle.startForBackgroundLaunch())
        #expect(backend.writes.isEmpty)

        let delivery = Task { @MainActor in
            await manager.waitForExplicitInitialInputDelivery(
                for: terminalID,
                timeout: 1
            )
        }
        await Task.yield()
        #expect(backend.writes.isEmpty)

        manager.shellBecameReady(for: terminalID)
        #expect(await delivery.value)
        #expect(backend.writes == [Data("claude -- task\r".utf8)])

        manager.shellBecameReady(for: terminalID)
        #expect(backend.writes.count == 1)
    }

    @Test("Initial input only waits when the configured shell can emit readiness")
    func initialInputReadinessGateMatchesSpawnConfiguration() {
        let unsupported = testSurfaceHandleSpawnConfiguration()
        let supported = ZmxSpawnConfiguration(
            sessionName: unsupported.sessionName,
            argv: unsupported.argv,
            env: unsupported.env,
            workingDirectory: unsupported.workingDirectory,
            shellReadySignalAvailable: true
        )

        #expect(!TerminalManager.shouldWaitForShellReady(
            extraInitialInput: "claude\r",
            configuration: unsupported
        ))
        #expect(TerminalManager.shouldWaitForShellReady(
            extraInitialInput: "claude\r",
            configuration: supported
        ))
        #expect(!TerminalManager.shouldWaitForShellReady(
            extraInitialInput: nil,
            configuration: supported
        ))
    }
}
