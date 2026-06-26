import GrafttyProtocol
import Testing
@testable import GrafttyKit

@Suite
struct SessionDisplayOwnershipStoreTests {
    private let sessionName = "main"

    @Test
    func visibleInteractiveAttachStaysOwnerlessUntilExplicitClaim() throws {
        let store = SessionDisplayOwnershipStore()
        let clientID = DisplayClientID("mac-1")
        let grid = try DisplayGrid(cols: 100, rows: 30)

        let snapshot = store.attachClient(
            sessionName: sessionName,
            clientID: clientID,
            kind: .mac,
            role: .interactive,
            visible: true,
            grid: grid
        )

        #expect(snapshot.ownerClientID == nil)
        #expect(snapshot.ownerKind == nil)
        #expect(snapshot.grid == grid)
        #expect(snapshot.epoch == 0)
        #expect(snapshot.isOwnerless)
    }

    @Test("""
    @spec IOS-4.25: Attaching an interactive iOS client to an ownerless session shall not implicitly make the phone the display owner. Mobile ownership changes are explicit: the client observes the ownerless snapshot, shows Take Control, and only `takeControl` may claim owner authority.
    """)
    func iosAttachDoesNotAutoClaimOwnerlessSession() throws {
        let store = SessionDisplayOwnershipStore()
        let clientID = DisplayClientID("ios-1")
        let grid = try DisplayGrid(cols: 90, rows: 28)

        let snapshot = store.attachClient(
            sessionName: sessionName,
            clientID: clientID,
            kind: .ios,
            role: .interactive,
            visible: true,
            grid: grid
        )

        #expect(snapshot.isOwnerless)
        #expect(snapshot.ownerClientID == nil)
        #expect(snapshot.ownerKind == nil)
        #expect(snapshot.grid == grid)
        #expect(snapshot.epoch == 0)
    }

    @Test
    func previewAttachNeverOwns() throws {
        let store = SessionDisplayOwnershipStore()
        let grid = try DisplayGrid(cols: 80, rows: 24)

        let snapshot = store.attachClient(
            sessionName: sessionName,
            clientID: DisplayClientID("preview-1"),
            kind: .preview,
            role: .preview,
            visible: true,
            grid: grid
        )

        #expect(snapshot.ownerClientID == nil)
        #expect(snapshot.ownerKind == nil)
        #expect(snapshot.grid == grid)
        #expect(snapshot.epoch == 0)
        #expect(snapshot.isOwnerless)
    }

    @Test
    func attachedPreviewKindCannotClaimBySupplyingInteractiveKind() throws {
        let store = SessionDisplayOwnershipStore()
        let clientID = DisplayClientID("preview-1")
        let previewGrid = try DisplayGrid(cols: 80, rows: 24)
        let claimGrid = try DisplayGrid(cols: 100, rows: 30)

        _ = store.attachClient(
            sessionName: sessionName,
            clientID: clientID,
            kind: .preview,
            role: .interactive,
            visible: true,
            grid: previewGrid
        )

        let result = store.claimOwner(
            sessionName: sessionName,
            clientID: clientID,
            kind: .web,
            grid: claimGrid
        )

        #expect(result.accepted == false)
        let snapshot = result.snapshot
        #expect(snapshot.isOwnerless)
        #expect(snapshot.ownerClientID == nil)
        #expect(snapshot.ownerKind == nil)
        #expect(snapshot.epoch == 0)
    }

    @Test
    func unattachedClaimIsRejectedAndLaterAttachCanExplicitlyClaim() throws {
        let store = SessionDisplayOwnershipStore()
        let clientID = DisplayClientID("web-1")
        let claimGrid = try DisplayGrid(cols: 100, rows: 30)
        let attachGrid = try DisplayGrid(cols: 120, rows: 40)

        let fallbackGrid = try DisplayGrid(cols: 132, rows: 43)
        let rejected = store.claimOwner(
            sessionName: sessionName,
            clientID: clientID,
            kind: .web,
            grid: claimGrid,
            fallbackGrid: fallbackGrid
        )

        #expect(rejected.accepted == false)
        #expect(rejected.snapshot.isOwnerless)
        #expect(rejected.snapshot.ownerClientID == nil)
        #expect(rejected.snapshot.ownerKind == nil)
        #expect(rejected.snapshot.grid == fallbackGrid)
        #expect(rejected.snapshot.epoch == 0)

        let attached = store.attachClient(
            sessionName: sessionName,
            clientID: clientID,
            kind: .web,
            role: .interactive,
            visible: true,
            grid: attachGrid
        )

        #expect(attached.ownerClientID == nil)
        #expect(attached.ownerKind == nil)
        #expect(attached.grid == attachGrid)
        #expect(attached.epoch == 0)

        let accepted = store.claimOwner(
            sessionName: sessionName,
            clientID: clientID,
            kind: .web,
            grid: attachGrid
        )
        #expect(accepted.accepted)
        #expect(accepted.snapshot.ownerClientID == clientID)
        #expect(accepted.snapshot.ownerKind == .web)
        #expect(accepted.snapshot.grid == attachGrid)
        #expect(accepted.snapshot.epoch == 1)
    }

    @Test
    func hiddenInteractiveClientCannotClaimUntilVisibleAndExplicitlyClaimed() throws {
        let store = SessionDisplayOwnershipStore()
        let clientID = DisplayClientID("web-1")
        let hiddenGrid = try DisplayGrid(cols: 90, rows: 28)
        let visibleGrid = try DisplayGrid(cols: 100, rows: 30)
        let claimGrid = try DisplayGrid(cols: 120, rows: 40)
        let fallbackGrid = try DisplayGrid(cols: 132, rows: 43)

        let hidden = store.attachClient(
            sessionName: sessionName,
            clientID: clientID,
            kind: .web,
            role: .interactive,
            visible: false,
            grid: hiddenGrid
        )
        #expect(hidden.isOwnerless)
        #expect(hidden.epoch == 0)

        let hiddenClaim = store.claimOwner(
            sessionName: sessionName,
            clientID: clientID,
            kind: .web,
            grid: claimGrid,
            fallbackGrid: fallbackGrid
        )
        #expect(hiddenClaim.accepted == false)
        #expect(hiddenClaim.snapshot.isOwnerless)
        #expect(hiddenClaim.snapshot.grid == fallbackGrid)
        #expect(hiddenClaim.snapshot.epoch == 0)

        let visible = store.attachClient(
            sessionName: sessionName,
            clientID: clientID,
            kind: .web,
            role: .interactive,
            visible: true,
            grid: visibleGrid
        )
        #expect(visible.isOwnerless)
        #expect(visible.grid == visibleGrid)
        #expect(visible.epoch == 0)

        let accepted = store.claimOwner(
            sessionName: sessionName,
            clientID: clientID,
            kind: .web,
            grid: claimGrid
        )
        #expect(accepted.accepted)
        #expect(accepted.snapshot.ownerClientID == clientID)
        #expect(accepted.snapshot.ownerKind == .web)
        #expect(accepted.snapshot.grid == claimGrid)
        #expect(accepted.snapshot.epoch == 1)
    }

    @Test
    func rejectedClaimPreservesStoredAuthoritativeGrid() throws {
        let store = SessionDisplayOwnershipStore()
        let owner = DisplayClientID("mac-1")
        let hidden = DisplayClientID("web-1")
        let ownerGrid = try DisplayGrid(cols: 100, rows: 30)
        let hiddenGrid = try DisplayGrid(cols: 90, rows: 28)
        let rejectedGrid = try DisplayGrid(cols: 140, rows: 50)

        _ = store.attachClient(
            sessionName: sessionName,
            clientID: owner,
            kind: .mac,
            role: .interactive,
            visible: true,
            grid: ownerGrid
        )
        let ownerClaim = store.claimOwner(sessionName: sessionName, clientID: owner, kind: .mac, grid: ownerGrid)
        #expect(ownerClaim.accepted)
        _ = store.attachClient(
            sessionName: sessionName,
            clientID: hidden,
            kind: .web,
            role: .interactive,
            visible: false,
            grid: hiddenGrid
        )

        let result = store.claimOwner(
            sessionName: sessionName,
            clientID: hidden,
            kind: .web,
            grid: rejectedGrid
        )

        #expect(result.accepted == false)
        #expect(result.snapshot.ownerClientID == owner)
        #expect(result.snapshot.grid == ownerGrid)
        #expect(result.snapshot.epoch == 1)
    }

    @Test
    func existingFollowerDoesNotAutoClaimAfterOwnerDisconnect() throws {
        let store = SessionDisplayOwnershipStore()
        let owner = DisplayClientID("mac-1")
        let follower = DisplayClientID("web-1")
        let ownerGrid = try DisplayGrid(cols: 100, rows: 30)
        let followerGrid = try DisplayGrid(cols: 90, rows: 28)

        _ = store.attachClient(
            sessionName: sessionName,
            clientID: owner,
            kind: .mac,
            role: .interactive,
            visible: true,
            grid: ownerGrid
        )
        let ownerClaim = store.claimOwner(sessionName: sessionName, clientID: owner, kind: .mac, grid: ownerGrid)
        #expect(ownerClaim.accepted)
        _ = store.attachClient(
            sessionName: sessionName,
            clientID: follower,
            kind: .web,
            role: .interactive,
            visible: true,
            grid: followerGrid
        )
        let ownerless = store.detachClient(sessionName: sessionName, clientID: owner)
        #expect(ownerless.isOwnerless)
        #expect(ownerless.grid == ownerGrid)

        let reattach = store.attachClient(
            sessionName: sessionName,
            clientID: follower,
            kind: .web,
            role: .interactive,
            visible: true,
            grid: followerGrid
        )

        #expect(reattach.isOwnerless)
        #expect(reattach.grid == ownerGrid)
        #expect(reattach.epoch == 2)
    }

    @Test
    func takeoverIncrementsEpochAndSwapsOwner() throws {
        let store = SessionDisplayOwnershipStore()
        let mac = DisplayClientID("mac-1")
        let web = DisplayClientID("web-1")
        let macGrid = try DisplayGrid(cols: 100, rows: 30)
        let webGrid = try DisplayGrid(cols: 120, rows: 40)

        _ = store.attachClient(sessionName: sessionName, clientID: mac, kind: .mac, role: .interactive, visible: true, grid: macGrid)
        let initialOwner = store.claimOwner(sessionName: sessionName, clientID: mac, kind: .mac, grid: macGrid)
        #expect(initialOwner.accepted)
        _ = store.attachClient(sessionName: sessionName, clientID: web, kind: .web, role: .interactive, visible: true, grid: webGrid)

        let result = store.claimOwner(sessionName: sessionName, clientID: web, kind: .web, grid: webGrid)

        #expect(result.accepted)
        #expect(result.snapshot.ownerClientID == web)
        #expect(result.snapshot.ownerKind == .web)
        #expect(result.snapshot.grid == webGrid)
        #expect(result.snapshot.epoch == 2)
    }

    @Test
    func implicitClaimOnlyAcceptsOwnerlessOrCurrentOwner() throws {
        let store = SessionDisplayOwnershipStore()
        let web = DisplayClientID("web-1")
        let mac = DisplayClientID("mac-1")
        let otherMac = DisplayClientID("mac-2")
        let macInitialGrid = try DisplayGrid(cols: 90, rows: 28)
        let webGrid = try DisplayGrid(cols: 100, rows: 30)
        let webResizeGrid = try DisplayGrid(cols: 110, rows: 33)
        let macGrid = try DisplayGrid(cols: 120, rows: 40)
        let rejectedGrid = try DisplayGrid(cols: 132, rows: 43)

        _ = store.attachClient(
            sessionName: sessionName,
            clientID: mac,
            kind: .mac,
            role: .interactive,
            visible: true,
            grid: macInitialGrid
        )
        let macClaim = store.claimOwner(sessionName: sessionName, clientID: mac, kind: .mac, grid: macInitialGrid)
        #expect(macClaim.accepted)
        _ = store.attachClient(
            sessionName: sessionName,
            clientID: web,
            kind: .web,
            role: .interactive,
            visible: true,
            grid: webGrid
        )
        _ = store.detachClient(sessionName: sessionName, clientID: mac)

        let ownerlessClaim = store.claimOwnerIfOwnerlessOrCurrent(
            sessionName: sessionName,
            clientID: web,
            kind: .web,
            grid: webGrid
        )
        #expect(ownerlessClaim.accepted)
        #expect(ownerlessClaim.snapshot.ownerClientID == web)
        #expect(ownerlessClaim.snapshot.grid == webGrid)
        let ownerlessClaimEpoch = ownerlessClaim.snapshot.epoch

        let currentOwnerClaim = store.claimOwnerIfOwnerlessOrCurrent(
            sessionName: sessionName,
            clientID: web,
            kind: .web,
            grid: webResizeGrid
        )
        #expect(currentOwnerClaim.accepted)
        #expect(currentOwnerClaim.snapshot.ownerClientID == web)
        #expect(currentOwnerClaim.snapshot.grid == webResizeGrid)
        #expect(currentOwnerClaim.snapshot.epoch == ownerlessClaimEpoch)

        _ = store.attachClient(
            sessionName: sessionName,
            clientID: otherMac,
            kind: .mac,
            role: .interactive,
            visible: true,
            grid: macGrid
        )

        let rejectedTakeover = store.claimOwnerIfOwnerlessOrCurrent(
            sessionName: sessionName,
            clientID: otherMac,
            kind: .mac,
            grid: rejectedGrid
        )
        #expect(rejectedTakeover.accepted == false)
        #expect(rejectedTakeover.snapshot.ownerClientID == web)
        #expect(rejectedTakeover.snapshot.grid == webResizeGrid)
        #expect(rejectedTakeover.snapshot.epoch == ownerlessClaimEpoch)
    }

    @Test
    func ownerResizeAcceptsOnlyMatchingOwnerAndEpoch() throws {
        let store = SessionDisplayOwnershipStore()
        let owner = DisplayClientID("mac-1")
        let follower = DisplayClientID("web-1")
        let initialGrid = try DisplayGrid(cols: 100, rows: 30)
        let ownerGrid = try DisplayGrid(cols: 110, rows: 33)
        let followerGrid = try DisplayGrid(cols: 120, rows: 40)

        _ = store.attachClient(sessionName: sessionName, clientID: owner, kind: .mac, role: .interactive, visible: true, grid: initialGrid)
        let initial = store.claimOwner(sessionName: sessionName, clientID: owner, kind: .mac, grid: initialGrid)
        #expect(initial.accepted)
        _ = store.attachClient(sessionName: sessionName, clientID: follower, kind: .web, role: .interactive, visible: true, grid: followerGrid)

        let rejectedFollower = store.ownerResize(sessionName: sessionName, clientID: follower, epoch: initial.snapshot.epoch, grid: followerGrid)
        #expect(rejectedFollower.accepted == false)
        #expect(rejectedFollower.snapshot.grid == initialGrid)

        let acceptedOwner = store.ownerResize(sessionName: sessionName, clientID: owner, epoch: initial.snapshot.epoch, grid: ownerGrid)
        #expect(acceptedOwner.accepted)
        #expect(acceptedOwner.snapshot.grid == ownerGrid)
        #expect(acceptedOwner.snapshot.epoch == initial.snapshot.epoch)
    }

    @Test
    func staleResizeFromOldEpochIsRejectedAfterTakeover() throws {
        let store = SessionDisplayOwnershipStore()
        let mac = DisplayClientID("mac-1")
        let web = DisplayClientID("web-1")
        let macGrid = try DisplayGrid(cols: 100, rows: 30)
        let webGrid = try DisplayGrid(cols: 120, rows: 40)
        let staleGrid = try DisplayGrid(cols: 88, rows: 22)

        _ = store.attachClient(sessionName: sessionName, clientID: mac, kind: .mac, role: .interactive, visible: true, grid: macGrid)
        let initial = store.claimOwner(sessionName: sessionName, clientID: mac, kind: .mac, grid: macGrid)
        #expect(initial.accepted)
        _ = store.attachClient(sessionName: sessionName, clientID: web, kind: .web, role: .interactive, visible: true, grid: webGrid)
        let takeover = store.claimOwner(sessionName: sessionName, clientID: web, kind: .web, grid: webGrid)

        let result = store.ownerResize(sessionName: sessionName, clientID: mac, epoch: initial.snapshot.epoch, grid: staleGrid)

        #expect(result.accepted == false)
        #expect(result.snapshot.ownerClientID == web)
        #expect(result.snapshot.epoch == takeover.snapshot.epoch)
        #expect(result.snapshot.grid == webGrid)
    }

    @Test
    func ownerDisconnectMakesOwnerlessAndPreservesLastGrid() throws {
        let store = SessionDisplayOwnershipStore()
        let owner = DisplayClientID("ios-1")
        let initialGrid = try DisplayGrid(cols: 90, rows: 28)
        let resizedGrid = try DisplayGrid(cols: 95, rows: 29)

        _ = store.attachClient(sessionName: sessionName, clientID: owner, kind: .ios, role: .interactive, visible: true, grid: initialGrid)
        let claim = store.claimOwner(sessionName: sessionName, clientID: owner, kind: .ios, grid: initialGrid)
        #expect(claim.accepted)
        _ = store.ownerResize(sessionName: sessionName, clientID: owner, epoch: claim.snapshot.epoch, grid: resizedGrid)

        let snapshot = store.detachClient(sessionName: sessionName, clientID: owner)

        #expect(snapshot.isOwnerless)
        #expect(snapshot.ownerClientID == nil)
        #expect(snapshot.ownerKind == nil)
        #expect(snapshot.grid == resizedGrid)
        #expect(snapshot.epoch == 2)
    }

    @Test
    func releaseOwnerMakesOwnerlessAndPreservesLastGrid() throws {
        let store = SessionDisplayOwnershipStore()
        let owner = DisplayClientID("web-1")
        let grid = try DisplayGrid(cols: 100, rows: 31)

        _ = store.attachClient(sessionName: sessionName, clientID: owner, kind: .web, role: .interactive, visible: true, grid: grid)
        let claim = store.claimOwner(sessionName: sessionName, clientID: owner, kind: .web, grid: grid)
        #expect(claim.accepted)

        let snapshot = store.releaseOwner(sessionName: sessionName, clientID: owner)

        #expect(snapshot.ownerless)
        #expect(snapshot.ownerClientID == nil)
        #expect(snapshot.ownerKind == nil)
        #expect(snapshot.grid == grid)
        #expect(snapshot.epoch == 2)
    }

    @Test
    func restoreFailedClaimRestoresPreviousOwnerOnlyWhenFailedClaimStillCurrent() throws {
        let store = SessionDisplayOwnershipStore()
        let previousOwner = DisplayClientID("mac-previous-owner")
        let failedTaker = DisplayClientID("mac-failed-taker")
        let newerOwner = DisplayClientID("mac-newer-owner")
        let previousGrid = try DisplayGrid(cols: 100, rows: 30)
        let failedGrid = try DisplayGrid(cols: 140, rows: 50)
        let newerGrid = try DisplayGrid(cols: 90, rows: 24)

        _ = store.attachClient(
            sessionName: sessionName,
            clientID: previousOwner,
            kind: .mac,
            role: .interactive,
            visible: true,
            grid: previousGrid
        )
        let previousClaim = store.claimOwner(
            sessionName: sessionName,
            clientID: previousOwner,
            kind: .mac,
            grid: previousGrid
        )
        #expect(previousClaim.accepted)
        _ = store.attachClient(
            sessionName: sessionName,
            clientID: failedTaker,
            kind: .mac,
            role: .interactive,
            visible: true,
            grid: failedGrid
        )

        let claim = store.claimOwner(
            sessionName: sessionName,
            clientID: failedTaker,
            kind: .mac,
            grid: previousGrid
        )
        #expect(claim.accepted)

        let restored = store.restoreOwnerAfterFailedClaim(
            sessionName: sessionName,
            failedClientID: failedTaker,
            failedKind: .mac,
            failedEpoch: claim.snapshot.epoch,
            previousOwnerClientID: previousOwner,
            previousOwnerKind: .mac,
            previousGrid: previousGrid
        )
        #expect(restored.ownerClientID == previousOwner)
        #expect(restored.grid == previousGrid)

        let secondClaim = store.claimOwner(
            sessionName: sessionName,
            clientID: failedTaker,
            kind: .mac,
            grid: previousGrid
        )
        #expect(secondClaim.accepted)
        _ = store.attachClient(
            sessionName: sessionName,
            clientID: newerOwner,
            kind: .mac,
            role: .interactive,
            visible: true,
            grid: newerGrid
        )
        let newerClaim = store.claimOwner(
            sessionName: sessionName,
            clientID: newerOwner,
            kind: .mac,
            grid: newerGrid
        )
        #expect(newerClaim.accepted)

        let notRestored = store.restoreOwnerAfterFailedClaim(
            sessionName: sessionName,
            failedClientID: failedTaker,
            failedKind: .mac,
            failedEpoch: secondClaim.snapshot.epoch,
            previousOwnerClientID: previousOwner,
            previousOwnerKind: .mac,
            previousGrid: previousGrid
        )
        #expect(notRestored.ownerClientID == newerOwner)
        #expect(notRestored.grid == newerGrid)
    }

    @Test
    func neverOwnedOwnerlessSessionCanSnapshotDaemonFallbackGrid() throws {
        let store = SessionDisplayOwnershipStore()
        let previewGrid = try DisplayGrid(cols: 60, rows: 18)
        let daemonGrid = try DisplayGrid(cols: 132, rows: 43)

        _ = store.attachClient(
            sessionName: sessionName,
            clientID: DisplayClientID("preview-1"),
            kind: .preview,
            role: .preview,
            visible: true,
            grid: previewGrid
        )
        let snapshot = store.snapshot(sessionName: sessionName, fallbackGrid: daemonGrid)

        #expect(snapshot.isOwnerless)
        #expect(snapshot.grid == daemonGrid)
        #expect(snapshot.epoch == 0)
    }

    @Test
    func ownerMutationsNotifyRegisteredObservers() throws {
        let store = SessionDisplayOwnershipStore()
        final class Box: @unchecked Sendable { var snapshots: [DisplayOwnershipSnapshot] = [] }
        let box = Box()
        let token = store.addObserver { box.snapshots.append($0) }

        _ = store.attachClient(
            sessionName: sessionName,
            clientID: DisplayClientID("mac-1"),
            kind: .mac,
            role: .interactive,
            visible: true,
            grid: try DisplayGrid(cols: 100, rows: 30)
        )
        #expect(box.snapshots.isEmpty)

        let claim = store.claimOwner(
            sessionName: sessionName,
            clientID: DisplayClientID("mac-1"),
            kind: .mac,
            grid: try DisplayGrid(cols: 100, rows: 30)
        )
        #expect(claim.accepted)
        #expect(box.snapshots.count == 1)
        #expect(box.snapshots.last?.ownerKind == .mac)

        _ = store.detachClient(sessionName: sessionName, clientID: DisplayClientID("mac-1"))
        #expect(box.snapshots.count == 2)
        #expect(box.snapshots.last?.isOwnerless == true)

        // After cancellation, further mutations are not delivered.
        token.cancel()
        _ = store.attachClient(
            sessionName: sessionName,
            clientID: DisplayClientID("mac-2"),
            kind: .mac,
            role: .interactive,
            visible: true,
            grid: try DisplayGrid(cols: 100, rows: 30)
        )
        #expect(box.snapshots.count == 2)
    }

    @Test
    func nonOwnerChangingMutationsDoNotNotifyObservers() throws {
        let store = SessionDisplayOwnershipStore()
        _ = store.attachClient(
            sessionName: sessionName,
            clientID: DisplayClientID("owner"),
            kind: .web,
            role: .interactive,
            visible: true,
            grid: try DisplayGrid(cols: 80, rows: 24)
        )

        final class Counter: @unchecked Sendable { var count = 0 }
        let counter = Counter()
        let token = store.addObserver { _ in counter.count += 1 }
        defer { token.cancel() }

        // A second client attaching does not change ownership.
        _ = store.attachClient(
            sessionName: sessionName,
            clientID: DisplayClientID("follower"),
            kind: .web,
            role: .interactive,
            visible: true,
            grid: try DisplayGrid(cols: 80, rows: 24)
        )
        // A resize with the wrong epoch is rejected, changing nothing.
        _ = store.ownerResize(
            sessionName: sessionName,
            clientID: DisplayClientID("owner"),
            epoch: 999,
            grid: try DisplayGrid(cols: 90, rows: 24)
        )

        #expect(counter.count == 0)
    }
}
