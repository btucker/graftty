import AppKit
import Foundation
import GhosttyKit
import GrafttyKit
import Testing
@testable import Graftty

@MainActor
@Suite("SurfaceHandle host-managed zmx cutover")
struct SurfaceHandleHostManagedTests {
    @Test("""
    @spec ZMX-4.1: When the application creates a zmx-backed native terminal pane, it shall create a libghostty surface with `GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED`, leave both `command` and `initial_input` unset, and start a host-owned `zmx attach graftty-<short-id> <user-shell>` PTY client only after `ghostty_surface_new` succeeds and the view's first layout settles (TERM-11.10). This avoids libghostty's automatic `wait-after-command` behavior while keeping shell exit wired to `close_surface_cb` through `ghostty_surface_process_exit`.
    """)
    func zmxAvailableUsesHostManagedBackendWithoutCommandOrInitialInput() throws {
        let backend = FakeSurfaceHandleZmxBackend()
        let harness = SurfaceHandleTestHarness(surface: fakeSurface())

        let handle = SurfaceHandle(
            terminalID: Self.terminalID(),
            app: fakeApp(),
            worktreePath: "/tmp/worktree",
            socketPath: "/tmp/graftty.sock",
            zmxSpawnConfiguration: testSurfaceHandleSpawnConfiguration(),
            surfaceFactory: harness.factory,
            zmxBackendFactory: { _, _, _ in backend }
        )

        #expect(handle != nil)
        #expect(harness.capturedConfigs.count == 1)
        let captured = try #require(harness.capturedConfigs.first)
        #expect(captured.backend == GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED)
        #expect(captured.receiveUserdata != nil)
        #expect(captured.receiveBuffer != nil)
        #expect(captured.receiveResize != nil)
        #expect(captured.command == nil)
        #expect(captured.initialInput == nil)
        // TERM-11.10: start defers to the first settled layout.
        #expect(backend.startCount == 0)
        let surfaceView = try #require(handle?.view as? SurfaceNSView)
        surfaceView.hostManagedLayoutNotifier?()
        #expect(backend.startCount == 1)
    }

    @Test("""
    @spec TERM-11.10: When a zmx-backed pane's surface is created or recreated, the application shall defer spawning the `zmx attach` client until the owning view's first layout settles, so the attach replay is parsed into a grid already at its settled size rather than the pre-layout placeholder.
    """)
    func zmxAttachSpawnDefersUntilFirstSettledLayout() throws {
        let backend = FakeSurfaceHandleZmxBackend()
        let harness = SurfaceHandleTestHarness(surface: fakeSurface())
        let handle = try #require(SurfaceHandle(
            terminalID: Self.terminalID(),
            app: fakeApp(),
            worktreePath: "/tmp/worktree",
            socketPath: "/tmp/graftty.sock",
            zmxSpawnConfiguration: testSurfaceHandleSpawnConfiguration(),
            extraInitialInput: "claude\r",
            surfaceFactory: harness.factory,
            zmxBackendFactory: { _, _, _ in backend }
        ))

        // No layout yet: no attach client, no initial input.
        #expect(backend.startCount == 0)
        #expect(backend.writes.isEmpty)

        let surfaceView = try #require(handle.view as? SurfaceNSView)
        let notifier = try #require(surfaceView.hostManagedLayoutNotifier)
        notifier()
        // First settled layout: start, then the spawn-time injection, and
        // the layout-settled signal still reaches the backend.
        #expect(backend.startCount == 1)
        #expect(backend.writes == [Data("claude\r".utf8)])
        #expect(backend.markLayoutSettledCount == 1)

        // Subsequent layout events must not re-start.
        notifier()
        #expect(backend.startCount == 1)
        #expect(backend.writes.count == 1)
    }

    @Test func directShellFallbackPreservesExtraInitialInput() throws {
        let harness = SurfaceHandleTestHarness(surface: fakeSurface())

        let handle = SurfaceHandle(
            terminalID: Self.terminalID(),
            app: fakeApp(),
            worktreePath: "/tmp/worktree",
            socketPath: "/tmp/graftty.sock",
            zmxSpawnConfiguration: nil,
            extraInitialInput: "nvim README.md\r",
            surfaceFactory: harness.factory
        )

        #expect(handle != nil)
        let captured = try #require(harness.capturedConfigs.first)
        #expect(captured.backend != GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED)
        #expect(captured.initialInput == "nvim README.md\r")
    }

    @Test func zmxBackedExtraInitialInputWritesThroughBackendAfterStart() throws {
        let backend = FakeSurfaceHandleZmxBackend()
        let harness = SurfaceHandleTestHarness(surface: fakeSurface())

        let handle = SurfaceHandle(
            terminalID: Self.terminalID(),
            app: fakeApp(),
            worktreePath: "/tmp/worktree",
            socketPath: "/tmp/graftty.sock",
            zmxSpawnConfiguration: testSurfaceHandleSpawnConfiguration(),
            extraInitialInput: "nvim Sources/main.swift\r",
            surfaceFactory: harness.factory,
            zmxBackendFactory: { _, _, _ in backend }
        )

        #expect(handle != nil)
        let captured = try #require(harness.capturedConfigs.first)
        #expect(captured.initialInput == nil)
        let surfaceView = try #require(handle?.view as? SurfaceNSView)
        surfaceView.hostManagedLayoutNotifier?()
        #expect(backend.startCount == 1)
        #expect(backend.writes == [Data("nvim Sources/main.swift\r".utf8)])
    }

    @Test("SurfaceHandle.init shall bind the surface-sync closures exactly once, wire the layout-settled notifier to the backend, and forward remoteClientsDidDetach and resyncVisibleGrid to the backend (TERM-11.1/11.3/11.4/11.13 glue).")
    func surfaceSyncAndDetachWiring() throws {
        let backend = FakeSurfaceHandleZmxBackend()
        let harness = SurfaceHandleTestHarness(surface: fakeSurface())
        let handle = try #require(SurfaceHandle(
            terminalID: Self.terminalID(),
            app: fakeApp(),
            worktreePath: "/tmp/worktree",
            socketPath: "/tmp/graftty.sock",
            zmxSpawnConfiguration: testSurfaceHandleSpawnConfiguration(),
            surfaceFactory: harness.factory,
            zmxBackendFactory: { _, _, _ in backend }
        ))

        #expect(backend.bindSurfaceSyncCount == 1)
        #expect(handle.zmxSessionName == testSurfaceHandleSpawnConfiguration().sessionName)

        let surfaceView = try #require(handle.view as? SurfaceNSView)
        let notifier = try #require(surfaceView.hostManagedLayoutNotifier)
        notifier()
        // TERM-11.10: the first settled layout both starts the deferred
        // attach and delivers the layout-settled signal.
        #expect(backend.startCount == 1)
        #expect(backend.markLayoutSettledCount == 1)

        handle.remoteClientsDidDetach()
        #expect(backend.remoteClientsDidDetachCount == 1)

        handle.resyncVisibleGrid()
        #expect(backend.resyncVisibleGridCount == 1)
    }

    @Test func typeTextUsesBackendForZmxBackedSurface() throws {
        let backend = FakeSurfaceHandleZmxBackend()
        let harness = SurfaceHandleTestHarness(surface: fakeSurface())
        let handle = try #require(SurfaceHandle(
            terminalID: Self.terminalID(),
            app: fakeApp(),
            worktreePath: "/tmp/worktree",
            socketPath: "/tmp/graftty.sock",
            zmxSpawnConfiguration: testSurfaceHandleSpawnConfiguration(),
            surfaceFactory: harness.factory,
            zmxBackendFactory: { _, _, _ in backend }
        ))

        handle.typeText("abc")

        #expect(backend.writes == [Data("abc".utf8)])
        #expect(harness.textWrites.isEmpty)
    }

    @Test func typeTextKeepsGhosttyTextForNonZmxSurface() throws {
        let harness = SurfaceHandleTestHarness(surface: fakeSurface())
        let handle = try #require(SurfaceHandle(
            terminalID: Self.terminalID(),
            app: fakeApp(),
            worktreePath: "/tmp/worktree",
            socketPath: "/tmp/graftty.sock",
            zmxSpawnConfiguration: nil,
            surfaceFactory: harness.factory
        ))

        handle.typeText("abc")

        #expect(harness.textWrites == [Data("abc".utf8)])
    }

    @Test func hostManagedBackspaceWritesDELDirectlyToBackend() throws {
        let view = SurfaceNSView()
        view.surface = fakeSurface()
        var writes: [Data] = []
        view.hostManagedInputWriter = { writes.append($0) }

        let event = try #require(Self.keyEvent(
            keyCode: 0x33,
            characters: "\u{7F}"
        ))

        view.keyDown(with: event)

        #expect(writes == [Data([0x7F])])
    }

    @Test func hostManagedDirectInputSkipsCommandControlAndOptionModifiedKeys() {
        #expect(SurfaceNSView.hostManagedDirectInput(forKeyCode: 0x33, modifierFlags: []) == Data([0x7F]))
        #expect(SurfaceNSView.hostManagedDirectInput(forKeyCode: 0x7B, modifierFlags: []) == Data("\u{1B}[D".utf8))
        #expect(SurfaceNSView.hostManagedDirectInput(forKeyCode: 0x33, modifierFlags: [.command]) == nil)
        #expect(SurfaceNSView.hostManagedDirectInput(forKeyCode: 0x33, modifierFlags: [.control]) == nil)
        #expect(SurfaceNSView.hostManagedDirectInput(forKeyCode: 0x33, modifierFlags: [.option]) == nil)
    }

    @Test func surfaceNewFailureDoesNotStartBackendAndReleasesBackendState() {
        let backend = FakeSurfaceHandleZmxBackend()
        let harness = SurfaceHandleTestHarness(surface: nil)

        let handle = SurfaceHandle(
            terminalID: Self.terminalID(),
            app: fakeApp(),
            worktreePath: "/tmp/worktree",
            socketPath: "/tmp/graftty.sock",
            zmxSpawnConfiguration: testSurfaceHandleSpawnConfiguration(),
            surfaceFactory: harness.factory,
            zmxBackendFactory: { _, _, _ in backend }
        )

        #expect(handle == nil)
        #expect(backend.startCount == 0)
        #expect(backend.closeCount == 1)
        #expect(backend.releaseCount == 1)
        #expect(harness.freeCalls.isEmpty)
    }

    @Test func backendStartFailureReportsDiagnosticAndNonzeroExitWithoutImmediateFree() {
        struct ForcedStartFailure: Error {}

        let backend = FakeSurfaceHandleZmxBackend(startError: ForcedStartFailure())
        let surface = fakeSurface()
        let harness = SurfaceHandleTestHarness(surface: surface)

        let handle = SurfaceHandle(
            terminalID: Self.terminalID(),
            app: fakeApp(),
            worktreePath: "/tmp/worktree",
            socketPath: "/tmp/graftty.sock",
            zmxSpawnConfiguration: testSurfaceHandleSpawnConfiguration(),
            surfaceFactory: harness.factory,
            zmxBackendFactory: { _, _, _ in backend }
        )

        #expect(handle != nil)
        let surfaceView = try? #require(handle?.view as? SurfaceNSView)
        surfaceView?.hostManagedLayoutNotifier?()
        #expect(backend.startCount == 1)
        #expect(backend.closeCount == 1)
        #expect(backend.releaseCount == 0)
        #expect(harness.freeCalls.isEmpty)
        #expect(harness.writeBufferCalls.count == 1)
        #expect(
            String(data: harness.writeBufferCalls[0].data, encoding: .utf8)?
                .contains("zmx attach failed") == true
        )
        #expect(harness.processExitCalls == [
            ProcessExitCall(surface: surface, exitCode: 1)
        ])
    }

    @Test("""
    @spec ZMX-4.4: When the application quits, it shall close each native host-managed `zmx attach` client and shall not invoke `zmx kill` — detaching the short-lived client while leaving zmx daemons and their shells alive is the desired survival behavior.
    """)
    func deinitClosesNativeAttachClientWithoutZmxKillPath() throws {
        let backend = FakeSurfaceHandleZmxBackend()
        let surface = fakeSurface()
        let harness = SurfaceHandleTestHarness(surface: surface)
        var handle: SurfaceHandle? = SurfaceHandle(
            terminalID: Self.terminalID(),
            app: fakeApp(),
            worktreePath: "/tmp/worktree",
            socketPath: "/tmp/graftty.sock",
            zmxSpawnConfiguration: testSurfaceHandleSpawnConfiguration(),
            surfaceFactory: harness.factory,
            zmxBackendFactory: { _, _, _ in backend }
        )
        _ = try #require(handle)

        handle = nil

        #expect(backend.closeCount == 1)
        #expect(backend.releaseCount == 1)
        #expect(harness.freeCalls == [surface])
    }

    @Test func queryGridSizeReturnsValueFromFactorySizeClosure() throws {
        let backend = FakeSurfaceHandleZmxBackend()
        let harness = SurfaceHandleTestHarness(surface: fakeSurface())
        harness.sizeStub = .testSize132x43

        let handle = try #require(SurfaceHandle(
            terminalID: Self.terminalID(),
            app: fakeApp(),
            worktreePath: "/tmp/worktree",
            socketPath: "/tmp/graftty.sock",
            zmxSpawnConfiguration: testSurfaceHandleSpawnConfiguration(),
            surfaceFactory: harness.factory,
            zmxBackendFactory: { _, _, _ in backend }
        ))

        let size = handle.queryGridSize()
        #expect(size.columns == 132)
        #expect(size.rows == 43)
        #expect(size.width_px == 1584)
        #expect(size.height_px == 688)
    }

    @Test("""
    @spec MEM-1.7: When a previously-evicted pane is re-attached via the rehydration path, the application shall spawn its outer `zmx attach` PTY with `initialSize` equal to the captured grid size, so the underlying shell PTY winsize remains stable across the evict / re-attach cycle.
    """)
    func initialGridSizePropagatesThroughBackendFactory() throws {
        var observedInitialSize: (cols: UInt16, rows: UInt16)?
        let backend = FakeSurfaceHandleZmxBackend()
        let harness = SurfaceHandleTestHarness(surface: fakeSurface())

        let handle = SurfaceHandle(
            terminalID: Self.terminalID(),
            app: fakeApp(),
            worktreePath: "/tmp/worktree",
            socketPath: "/tmp/graftty.sock",
            zmxSpawnConfiguration: testSurfaceHandleSpawnConfiguration(),
            surfaceFactory: harness.factory,
            zmxBackendFactory: { _, initialSize, _ in
                observedInitialSize = initialSize
                return backend
            },
            initialGridSize: .testSize132x43
        )

        #expect(handle != nil)
        #expect(observedInitialSize?.cols == 132)
        #expect(observedInitialSize?.rows == 43)
    }

    @Test("""
    @spec MEM-1.8: When a previously-evicted pane is re-attached via the rehydration path, the application shall pre-size the new libghostty surface to the captured pixel dimensions before starting its host-managed backend, so the first post-layout resize event is a no-op when the layout container has not changed.
    """)
    func initialGridSizePreSetsSurfaceBeforeBackendStart() throws {
        let surface = fakeSurface()
        let harness = SurfaceHandleTestHarness(surface: surface)
        let backend = FakeSurfaceHandleZmxBackend(
            setSizeCountSource: { harness.setSizeCalls.count }
        )

        let handle = SurfaceHandle(
            terminalID: Self.terminalID(),
            app: fakeApp(),
            worktreePath: "/tmp/worktree",
            socketPath: "/tmp/graftty.sock",
            zmxSpawnConfiguration: testSurfaceHandleSpawnConfiguration(),
            surfaceFactory: harness.factory,
            zmxBackendFactory: { _, _, _ in backend },
            initialGridSize: .testSize132x43
        )

        #expect(handle != nil)
        #expect(harness.setSizeCalls == [
            SetSizeCall(surface: surface, width: 1584, height: 688)
        ])
        let surfaceView = try? #require(handle?.view as? SurfaceNSView)
        surfaceView?.hostManagedLayoutNotifier?()
        #expect(backend.observedSetSizeCountAtStart == 1)
    }

    @Test("""
    @spec TERM-11.16: When AppKit resizes a zmx-backed terminal view, the application shall update libghostty's surface size before marking the pane visible and reconciling zmx to the live grid, so the show-time reconcile cannot forward the previous row count during a real resize.
    """)
    func frameResizeSetsLibghosttySizeBeforeVisibleReconcile() throws {
        let backend = FakeSurfaceHandleZmxBackend()
        let harness = SurfaceHandleTestHarness(surface: fakeSurface())
        var resyncCountsObservedDuringSetSize: [Int] = []
        harness.onSetSize = {
            resyncCountsObservedDuringSetSize.append(backend.resyncVisibleGridCount)
        }
        let terminalID = Self.terminalID()
        let handle = try #require(SurfaceHandle(
            terminalID: terminalID,
            app: fakeApp(),
            worktreePath: "/tmp/worktree",
            socketPath: "/tmp/graftty.sock",
            zmxSpawnConfiguration: testSurfaceHandleSpawnConfiguration(),
            surfaceFactory: harness.factory,
            zmxBackendFactory: { _, _, _ in backend }
        ))
        let surfaceView = try #require(handle.view as? SurfaceNSView)
        surfaceView.surfaceOperations = SurfaceNSViewGhosttySurfaceOperations(
            setSize: harness.factory.setSize,
            size: harness.factory.size,
            refresh: { _ in }
        )
        surfaceView.visibleForInputNotifier = {
            backend.resyncVisibleGrid()
        }

        surfaceView.setFrameSize(NSSize(width: 800, height: 400))

        #expect(resyncCountsObservedDuringSetSize == [0])
        #expect(backend.resyncVisibleGridCount == 1)
    }

    private static func terminalID() -> PaneSlotID {
        PaneSlotID(id: UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000000")!)
    }

    private static func keyEvent(
        keyCode: UInt16,
        characters: String,
        modifierFlags: NSEvent.ModifierFlags = []
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )
    }
}
