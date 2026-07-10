import AppKit
import Foundation
import GhosttyKit
import GrafttyKit
import GrafttyProtocol
import Testing
@testable import Graftty

/// OWN-2.x — the Mac pane's Take Control affordance and key-event reclaim.
///
/// Background: display ownership is claimed by remote clients (iOS/web)
/// through the shared `SessionDisplayOwnershipStore`. When the remote
/// owner disconnects, its coordinator detaches and the session becomes
/// ownerless — the Mac does NOT auto-reclaim. The affordance and the
/// key-event reclaim below are what give control back to the Mac.
@MainActor
@Suite("Mac display-control reclaim (OWN-2.x)")
struct MacDisplayControlReclaimTests {
    private static let macClientID = DisplayClientID("mac-pane-client")
    private static let remoteClientID = DisplayClientID("ios-remote-client")

    private struct Fixture {
        let handle: SurfaceHandle
        let backend: FakeSurfaceHandleZmxBackend
        let store: SessionDisplayOwnershipStore
        let sessionName: String
        let view: SurfaceNSView
    }

    private static func makeFixture() throws -> Fixture {
        let backend = FakeSurfaceHandleZmxBackend()
        let store = SessionDisplayOwnershipStore()
        let harness = SurfaceHandleTestHarness(surface: fakeSurface())
        let handle = try #require(SurfaceHandle(
            terminalID: PaneSlotID(id: UUID()),
            app: fakeApp(),
            worktreePath: "/tmp/worktree",
            socketPath: "/tmp/graftty.sock",
            zmxSpawnConfiguration: testSurfaceHandleSpawnConfiguration(),
            displayOwnershipStore: store,
            displayClientID: macClientID,
            surfaceFactory: harness.factory,
            zmxBackendFactory: { _, _, _, _ in backend }
        ))
        let view = try #require(handle.view as? SurfaceNSView)
        let sessionName = try #require(handle.zmxSessionName)
        return Fixture(
            handle: handle,
            backend: backend,
            store: store,
            sessionName: sessionName,
            view: view
        )
    }

    /// Mirrors what the Mac zmx backend does on start: attach the Mac
    /// client and claim the session while it is ownerless.
    private static func attachAndClaimMac(_ fixture: Fixture) {
        let grid = try! DisplayGrid(cols: 140, rows: 50)
        _ = fixture.store.attachClient(
            sessionName: fixture.sessionName,
            clientID: macClientID,
            kind: .mac,
            role: .interactive,
            visible: true,
            grid: grid
        )
        _ = fixture.store.claimOwnerIfOwnerlessOrCurrent(
            sessionName: fixture.sessionName,
            clientID: macClientID,
            kind: .mac,
            grid: grid
        )
    }

    /// Mirrors a remote (iOS) client attaching and taking control via
    /// `TerminalAttachCoordinator`'s claim path.
    private static func remoteTakesControl(_ fixture: Fixture) {
        let grid = try! DisplayGrid(cols: 250, rows: 80)
        _ = fixture.store.attachClient(
            sessionName: fixture.sessionName,
            clientID: remoteClientID,
            kind: .ios,
            role: .interactive,
            visible: true,
            grid: grid
        )
        let claim = fixture.store.claimOwner(
            sessionName: fixture.sessionName,
            clientID: remoteClientID,
            kind: .ios,
            grid: grid
        )
        precondition(claim.accepted, "test fixture: remote claim must be accepted")
    }

    private static func backspaceKeyEvent(
        modifierFlags: NSEvent.ModifierFlags = [],
        isARepeat: Bool = false
    ) throws -> NSEvent {
        try #require(testKeyDownEvent(
            keyCode: 0x33,
            characters: "\u{7F}",
            modifierFlags: modifierFlags,
            isARepeat: isARepeat
        ))
    }

    @Test("""
    @spec OWN-2.1: While a zmx-backed Mac pane's session is owned by another display client, or is ownerless after a prior ownership change, the application shall offer the pane's Take Control affordance (`canTakeDisplayControl()` true); while the Mac pane itself owns the session — including the automatic ownerless claim at first attach — or the session has no ownership history, the affordance shall be hidden.
    """)
    func affordanceTracksOwnerAndOwnerlessAfterHistory() throws {
        let fixture = try Self.makeFixture()

        // No ownership history at all: hidden.
        #expect(!fixture.handle.canTakeDisplayControl())

        // Mac attach + ownerless claim (what backend.start() does): hidden.
        Self.attachAndClaimMac(fixture)
        #expect(!fixture.handle.canTakeDisplayControl())

        // A remote client takes control: offered.
        Self.remoteTakesControl(fixture)
        #expect(fixture.handle.canTakeDisplayControl())

        // The remote owner detaches (app backgrounded / channel closed):
        // the session is ownerless but has history — still offered, so the
        // Mac user can reclaim without typing.
        _ = fixture.store.detachClient(
            sessionName: fixture.sessionName,
            clientID: Self.remoteClientID
        )
        #expect(fixture.store.snapshot(sessionName: fixture.sessionName).ownerClientID == nil)
        #expect(fixture.handle.canTakeDisplayControl())
    }

    @Test("""
    @spec OWN-2.2: When a non-command key press reaches a zmx-backed Mac pane that can take display control (OWN-2.1), the application shall reclaim display ownership at the key event itself — synchronously, before dispatching the key — rather than relying on the asynchronous emitted-bytes classification, which runs on libghostty's IO thread after the user-input scope has already exited.
    """)
    func keyDownReclaimsDisplayControlBeforeDispatch() throws {
        let fixture = try Self.makeFixture()
        Self.attachAndClaimMac(fixture)
        Self.remoteTakesControl(fixture)

        fixture.view.keyDown(with: try Self.backspaceKeyEvent())

        #expect(fixture.backend.takeControlCount == 1)
        // The keystroke itself is still delivered after the reclaim.
        #expect(fixture.backend.writes == [Data([0x7F])])
    }

    @Test("A key press while the Mac pane already owns the session shall not re-claim.")
    func keyDownWhileOwnerDoesNotReclaim() throws {
        let fixture = try Self.makeFixture()
        Self.attachAndClaimMac(fixture)

        fixture.view.keyDown(with: try Self.backspaceKeyEvent())

        #expect(fixture.backend.takeControlCount == 0)
        #expect(fixture.backend.writes == [Data([0x7F])])
    }

    @Test("A key press on an ownerless-after-history session shall reclaim for the Mac.")
    func keyDownOnOwnerlessSessionReclaims() throws {
        let fixture = try Self.makeFixture()
        Self.attachAndClaimMac(fixture)
        Self.remoteTakesControl(fixture)
        _ = fixture.store.detachClient(
            sessionName: fixture.sessionName,
            clientID: Self.remoteClientID
        )

        fixture.view.keyDown(with: try Self.backspaceKeyEvent())

        #expect(fixture.backend.takeControlCount == 1)
    }

    @Test("A command-modified key press shall not steal display ownership (app shortcuts like Cmd+C must not reclaim).")
    func commandModifiedKeyDoesNotReclaim() throws {
        let fixture = try Self.makeFixture()
        Self.attachAndClaimMac(fixture)
        Self.remoteTakesControl(fixture)

        // Calls the reclaim helper directly rather than keyDown: a
        // cmd-modified key is not a direct-input key, so keyDown would
        // forward it to ghostty_surface_key on the fake surface pointer.
        fixture.view.reclaimDisplayControlForUserInputIfNeeded(
            try Self.backspaceKeyEvent(modifierFlags: [.command])
        )

        #expect(fixture.backend.takeControlCount == 0)
    }

    @Test("A key-repeat event shall not re-attempt the reclaim (the initiating press already did).")
    func keyRepeatDoesNotReclaim() throws {
        let fixture = try Self.makeFixture()
        Self.attachAndClaimMac(fixture)
        Self.remoteTakesControl(fixture)

        fixture.view.reclaimDisplayControlForUserInputIfNeeded(
            try Self.backspaceKeyEvent(isARepeat: true)
        )

        #expect(fixture.backend.takeControlCount == 0)
    }

    @Test("""
    @spec OWN-2.3: When a clipboard paste is delivered to a zmx-backed Mac pane that can take display control (OWN-2.1), the application shall reclaim display ownership before completing the clipboard request — the clipboard read completes asynchronously on the main queue after the triggering key or menu event, so neither the OWN-2.2 key-event reclaim (command chords are excluded) nor the emitted-bytes classification can claim ownership for the paste bytes.
    """)
    func pasteDeliveryReclaimsDisplayControl() throws {
        let fixture = try Self.makeFixture()
        Self.attachAndClaimMac(fixture)
        Self.remoteTakesControl(fixture)

        fixture.handle.reclaimDisplayControlForPasteIfNeeded()

        #expect(fixture.backend.takeControlCount == 1)
    }

    @Test("A paste while the Mac pane already owns the session shall not re-claim.")
    func pasteWhileOwnerDoesNotReclaim() throws {
        let fixture = try Self.makeFixture()
        Self.attachAndClaimMac(fixture)

        fixture.handle.reclaimDisplayControlForPasteIfNeeded()

        #expect(fixture.backend.takeControlCount == 0)
    }
}
