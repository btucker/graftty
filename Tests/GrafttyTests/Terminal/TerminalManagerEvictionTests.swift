import AppKit
import Foundation
import GhosttyKit
import Testing
@testable import Graftty
@testable import GrafttyKit

@MainActor
@Suite("TerminalManager.evictSurface")
struct TerminalManagerEvictionTests {

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
            zmxBackendFactory: { _, _ in backend }
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
            zmxBackendFactory: { _, _ in backend }
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
            zmxBackendFactory: { _, _ in backend }
        ))
        manager.insertSurfaceForTesting(handle, for: terminalID)

        manager.evictSurface(terminalID: terminalID)
        #expect(manager.evictedGridSize(for: terminalID) != nil)

        manager.destroySurface(terminalID: terminalID)
        #expect(manager.evictedGridSize(for: terminalID) == nil)
    }
}
