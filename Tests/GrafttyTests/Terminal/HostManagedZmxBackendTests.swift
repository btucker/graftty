import Foundation
import GhosttyKit
import GrafttyProtocol
import Testing
@testable import Graftty
@testable import GrafttyKit

@Suite("HostManagedZmxBackend — Ghostty host-managed adapter", .serialized)
struct HostManagedZmxBackendTests {
    @Test("Mac owner forwards viewport resizes and PTY-bound input through the ownership gate.")
    func macOwnerForwardsResizeAndInput() throws {
        let store = SessionDisplayOwnershipStore()
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(
            session: session,
            ownership: Self.ownership(store: store, clientID: "mac-owner")
        )
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        backend.bindSurfaceSync(currentGridSize: { (cols: 100, rows: 30) }, requestRefresh: {})

        try backend.start(surface: Self.fakeSurface())
        backend.markLayoutSettled()

        HostManagedZmxBackend.receiveResizeCallback(
            backend.userdataForTesting,
            120,
            40,
            1440,
            960
        )
        try backend.write(Data("x".utf8))

        #expect(session.resizes().contains(Resize(cols: 120, rows: 40)))
        #expect(session.writes() == [Data("x".utf8)])
    }

    @Test("Mac follower suppresses PTY resizes and programmatic PTY-bound input.")
    func macFollowerSuppressesResizeAndProgrammaticInput() throws {
        let store = SessionDisplayOwnershipStore()
        let owner = FakeHostManagedSession()
        let ownerBackend = Self.makeBackend(
            session: owner,
            ownership: Self.ownership(store: store, clientID: "mac-owner")
        )
        defer { ownerBackend.releaseReceiveUserdataAfterSurfaceFree() }
        ownerBackend.bindSurfaceSync(currentGridSize: { (cols: 100, rows: 30) }, requestRefresh: {})
        try ownerBackend.start(surface: Self.fakeSurface())
        ownerBackend.markLayoutSettled()

        let follower = FakeHostManagedSession()
        let followerBackend = Self.makeBackend(
            session: follower,
            ownership: Self.ownership(store: store, clientID: "mac-follower")
        )
        defer { followerBackend.releaseReceiveUserdataAfterSurfaceFree() }
        followerBackend.bindSurfaceSync(currentGridSize: { (cols: 140, rows: 50) }, requestRefresh: {})
        try followerBackend.start(surface: Self.fakeSurface())
        followerBackend.markLayoutSettled()

        HostManagedZmxBackend.receiveResizeCallback(
            followerBackend.userdataForTesting,
            140,
            50,
            1680,
            1200
        )
        try followerBackend.write(Data("blocked".utf8), claimEngagement: false)

        #expect(follower.resizes().isEmpty)
        #expect(follower.writes().isEmpty)
        #expect(store.snapshot(sessionName: "graftty-test").ownerClientID == DisplayClientID("mac-owner"))
    }

    @Test("Mac follower user input takes ownership before forwarding bytes.")
    func macFollowerUserInputTakesOwnershipBeforeForwardingBytes() throws {
        let store = SessionDisplayOwnershipStore()
        let ownerSession = FakeHostManagedSession()
        let owner = Self.makeBackend(
            session: ownerSession,
            ownership: Self.ownership(store: store, clientID: "mac-owner")
        )
        defer { owner.releaseReceiveUserdataAfterSurfaceFree() }
        owner.bindSurfaceSync(currentGridSize: { (cols: 100, rows: 30) }, requestRefresh: {})
        try owner.start(surface: Self.fakeSurface())
        owner.markLayoutSettled()

        let followerSession = FakeHostManagedSession()
        let follower = Self.makeBackend(
            session: followerSession,
            ownership: Self.ownership(store: store, clientID: "mac-follower")
        )
        defer { follower.releaseReceiveUserdataAfterSurfaceFree() }
        follower.bindSurfaceSync(currentGridSize: { (cols: 140, rows: 50) }, requestRefresh: {})
        try follower.start(surface: Self.fakeSurface())
        follower.markLayoutSettled()

        try follower.write(Data("x".utf8), claimEngagement: true)

        let snapshot = store.snapshot(sessionName: "graftty-test")
        #expect(snapshot.ownerClientID == DisplayClientID("mac-follower"))
        #expect(followerSession.resizes() == [Resize(cols: 140, rows: 50)])
        #expect(followerSession.writes() == [Data("x".utf8)])
    }

    @Test("First visible interactive Mac attach explicitly claims only when the session is ownerless.")
    func firstVisibleMacAttachExplicitlyClaimsOnlyWhenOwnerless() throws {
        let store = SessionDisplayOwnershipStore()
        let firstSession = FakeHostManagedSession()
        let first = Self.makeBackend(
            session: firstSession,
            ownership: Self.ownership(store: store, clientID: "mac-first")
        )
        defer { first.releaseReceiveUserdataAfterSurfaceFree() }
        first.bindSurfaceSync(currentGridSize: { (cols: 90, rows: 25) }, requestRefresh: {})
        try first.start(surface: Self.fakeSurface())
        first.markLayoutSettled()

        #expect(store.snapshot(sessionName: "graftty-test").ownerClientID == DisplayClientID("mac-first"))

        let secondSession = FakeHostManagedSession()
        let second = Self.makeBackend(
            session: secondSession,
            ownership: Self.ownership(store: store, clientID: "mac-second")
        )
        defer { second.releaseReceiveUserdataAfterSurfaceFree() }
        second.bindSurfaceSync(currentGridSize: { (cols: 140, rows: 50) }, requestRefresh: {})
        try second.start(surface: Self.fakeSurface())
        second.markLayoutSettled()

        #expect(store.snapshot(sessionName: "graftty-test").ownerClientID == DisplayClientID("mac-first"))
        #expect(secondSession.resizes().isEmpty)
    }

    @Test("Show-time reconcile refreshes a follower presentation without stealing ownership or resizing the PTY.")
    func showTimeReconcileDoesNotStealOwnership() throws {
        let store = SessionDisplayOwnershipStore()
        let ownerSession = FakeHostManagedSession()
        let owner = Self.makeBackend(
            session: ownerSession,
            ownership: Self.ownership(store: store, clientID: "mac-owner")
        )
        defer { owner.releaseReceiveUserdataAfterSurfaceFree() }
        owner.bindSurfaceSync(currentGridSize: { (cols: 100, rows: 30) }, requestRefresh: {})
        try owner.start(surface: Self.fakeSurface())
        owner.markLayoutSettled()

        let followerSession = FakeHostManagedSession()
        let follower = Self.makeBackend(
            session: followerSession,
            ownership: Self.ownership(store: store, clientID: "mac-follower")
        )
        defer { follower.releaseReceiveUserdataAfterSurfaceFree() }
        follower.bindSurfaceSync(currentGridSize: { (cols: 140, rows: 50) }, requestRefresh: {})
        try follower.start(surface: Self.fakeSurface())
        follower.markLayoutSettled()

        follower.resyncVisibleGrid()

        #expect(store.snapshot(sessionName: "graftty-test").ownerClientID == DisplayClientID("mac-owner"))
        #expect(followerSession.resizes().isEmpty)
    }

    @Test("Mac Take Control swaps owner, increments epoch, and immediately sends the new natural grid.")
    func takeControlSwapsOwnerIncrementsEpochAndSendsGrid() throws {
        let store = SessionDisplayOwnershipStore()
        let ownerSession = FakeHostManagedSession()
        let owner = Self.makeBackend(
            session: ownerSession,
            ownership: Self.ownership(store: store, clientID: "mac-owner")
        )
        defer { owner.releaseReceiveUserdataAfterSurfaceFree() }
        owner.bindSurfaceSync(currentGridSize: { (cols: 100, rows: 30) }, requestRefresh: {})
        try owner.start(surface: Self.fakeSurface())
        owner.markLayoutSettled()
        let epochBefore = store.snapshot(sessionName: "graftty-test").epoch

        let followerSession = FakeHostManagedSession()
        let follower = Self.makeBackend(
            session: followerSession,
            ownership: Self.ownership(store: store, clientID: "mac-follower")
        )
        defer { follower.releaseReceiveUserdataAfterSurfaceFree() }
        follower.bindSurfaceSync(currentGridSize: { (cols: 140, rows: 50) }, requestRefresh: {})
        try follower.start(surface: Self.fakeSurface())
        follower.markLayoutSettled()

        #expect(follower.takeControl())

        let snapshot = store.snapshot(sessionName: "graftty-test")
        #expect(snapshot.ownerClientID == DisplayClientID("mac-follower"))
        #expect(snapshot.epoch == epochBefore + 1)
        #expect(followerSession.resizes() == [Resize(cols: 140, rows: 50)])
    }

    @Test("A stale pending resize from the old Mac owner is rejected after takeover.")
    func stalePendingResizeFromOldOwnerRejectedAfterTakeover() throws {
        let store = SessionDisplayOwnershipStore()
        let coalescer = ManualResizeCoalescer()
        let oldOwnerSession = FakeHostManagedSession()
        let oldOwner = Self.makeBackend(
            session: oldOwnerSession,
            ownership: Self.ownership(store: store, clientID: "mac-old-owner"),
            coalescer: coalescer
        )
        defer { oldOwner.releaseReceiveUserdataAfterSurfaceFree() }
        oldOwner.bindSurfaceSync(currentGridSize: { (cols: 100, rows: 30) }, requestRefresh: {})
        try oldOwner.start(surface: Self.fakeSurface())
        oldOwner.markLayoutSettled()

        HostManagedZmxBackend.receiveResizeCallback(oldOwner.userdataForTesting, 110, 30, 0, 0)
        HostManagedZmxBackend.receiveResizeCallback(oldOwner.userdataForTesting, 120, 30, 0, 0)

        let newOwnerSession = FakeHostManagedSession()
        let newOwner = Self.makeBackend(
            session: newOwnerSession,
            ownership: Self.ownership(store: store, clientID: "mac-new-owner")
        )
        defer { newOwner.releaseReceiveUserdataAfterSurfaceFree() }
        newOwner.bindSurfaceSync(currentGridSize: { (cols: 90, rows: 24) }, requestRefresh: {})
        try newOwner.start(surface: Self.fakeSurface())
        newOwner.markLayoutSettled()

        #expect(newOwner.takeControl())
        coalescer.fireAll()

        #expect(store.snapshot(sessionName: "graftty-test").ownerClientID == DisplayClientID("mac-new-owner"))
        #expect(oldOwnerSession.resizes() == [Resize(cols: 100, rows: 30), Resize(cols: 110, rows: 30)])
        #expect(newOwnerSession.resizes() == [Resize(cols: 90, rows: 24)])
    }

    @Test("A pending resize queued while the old Mac owner is starting is revalidated and rejected after takeover.")
    func staleStartingPendingResizeFromOldOwnerRejectedAfterTakeover() throws {
        let store = SessionDisplayOwnershipStore()
        let oldStartEntered = DispatchSemaphore(value: 0)
        let releaseOldStart = DispatchSemaphore(value: 0)
        let oldOwnerSession = FakeHostManagedSession(
            startHook: {
                oldStartEntered.signal()
                _ = releaseOldStart.wait(timeout: .now() + 2)
            }
        )
        let oldOwner = Self.makeBackend(
            session: oldOwnerSession,
            ownership: Self.ownership(store: store, clientID: "mac-old-starting-owner")
        )
        defer { oldOwner.releaseReceiveUserdataAfterSurfaceFree() }
        oldOwner.bindSurfaceSync(currentGridSize: { (cols: 100, rows: 30) }, requestRefresh: {})

        let oldStartFinished = DispatchSemaphore(value: 0)
        Self.runOnDedicatedThread {
            try? oldOwner.start(surface: Self.fakeSurface())
            oldStartFinished.signal()
        }
        #expect(oldStartEntered.wait(timeout: .now() + 2) == .success)

        oldOwner.markLayoutSettled()
        HostManagedZmxBackend.receiveResizeCallback(oldOwner.userdataForTesting, 120, 30, 0, 0)

        let newOwnerSession = FakeHostManagedSession()
        let newOwner = Self.makeBackend(
            session: newOwnerSession,
            ownership: Self.ownership(store: store, clientID: "mac-new-owner")
        )
        defer { newOwner.releaseReceiveUserdataAfterSurfaceFree() }
        newOwner.bindSurfaceSync(currentGridSize: { (cols: 90, rows: 24) }, requestRefresh: {})
        try newOwner.start(surface: Self.fakeSurface())
        newOwner.markLayoutSettled()
        #expect(newOwner.takeControl())

        releaseOldStart.signal()
        #expect(oldStartFinished.wait(timeout: .now() + 2) == .success)

        #expect(store.snapshot(sessionName: "graftty-test").ownerClientID == DisplayClientID("mac-new-owner"))
        #expect(oldOwnerSession.resizes().isEmpty)
        #expect(newOwnerSession.resizes() == [Resize(cols: 90, rows: 24)])
    }

    @Test("A failed Take Control resize does not leave the failed taker as display owner.")
    func failedTakeControlResizePreservesPreviousOwner() throws {
        let store = SessionDisplayOwnershipStore()
        let ownerSession = FakeHostManagedSession()
        let owner = Self.makeBackend(
            session: ownerSession,
            ownership: Self.ownership(store: store, clientID: "mac-owner")
        )
        defer { owner.releaseReceiveUserdataAfterSurfaceFree() }
        owner.bindSurfaceSync(currentGridSize: { (cols: 100, rows: 30) }, requestRefresh: {})
        try owner.start(surface: Self.fakeSurface())
        owner.markLayoutSettled()

        let followerSession = FakeHostManagedSession()
        let follower = Self.makeBackend(
            session: followerSession,
            ownership: Self.ownership(store: store, clientID: "mac-failed-taker")
        )
        defer { follower.releaseReceiveUserdataAfterSurfaceFree() }
        follower.bindSurfaceSync(currentGridSize: { (cols: 140, rows: 50) }, requestRefresh: {})
        try follower.start(surface: Self.fakeSurface())
        follower.markLayoutSettled()

        followerSession.setFailNextResize(true)
        #expect(!follower.takeControl())

        let snapshot = store.snapshot(sessionName: "graftty-test")
        let previousGrid = try DisplayGrid(cols: 100, rows: 30)
        #expect(snapshot.ownerClientID == DisplayClientID("mac-owner"))
        #expect(snapshot.grid == previousGrid)
        #expect(followerSession.resizes().isEmpty)

        try owner.write(Data("still-owner".utf8))
        try follower.write(Data("blocked".utf8), claimEngagement: false)
        #expect(ownerSession.writes() == [Data("still-owner".utf8)])
        #expect(followerSession.writes().isEmpty)
    }

    @Test("Mac follower user input is dropped when the takeover resize fails.")
    func macFollowerUserInputIsDroppedWhenTakeoverResizeFails() throws {
        let store = SessionDisplayOwnershipStore()
        let ownerSession = FakeHostManagedSession()
        let owner = Self.makeBackend(
            session: ownerSession,
            ownership: Self.ownership(store: store, clientID: "mac-owner")
        )
        defer { owner.releaseReceiveUserdataAfterSurfaceFree() }
        owner.bindSurfaceSync(currentGridSize: { (cols: 100, rows: 30) }, requestRefresh: {})
        try owner.start(surface: Self.fakeSurface())
        owner.markLayoutSettled()

        let followerSession = FakeHostManagedSession()
        let follower = Self.makeBackend(
            session: followerSession,
            ownership: Self.ownership(store: store, clientID: "mac-failed-input")
        )
        defer { follower.releaseReceiveUserdataAfterSurfaceFree() }
        follower.bindSurfaceSync(currentGridSize: { (cols: 140, rows: 50) }, requestRefresh: {})
        try follower.start(surface: Self.fakeSurface())
        follower.markLayoutSettled()

        followerSession.setFailNextResize(true)
        try follower.write(Data("x".utf8), claimEngagement: true)

        let snapshot = store.snapshot(sessionName: "graftty-test")
        #expect(snapshot.ownerClientID == DisplayClientID("mac-owner"))
        #expect(followerSession.writes().isEmpty)
    }

    @Test("A Take Control resize rejected after a newer owner claims repairs the PTY back to the authoritative grid.")
    func takeControlRejectedAfterPhysicalResizeRepairsToAuthoritativeGrid() throws {
        let store = SessionDisplayOwnershipStore()
        let initialOwnerSession = FakeHostManagedSession()
        let initialOwner = Self.makeBackend(
            session: initialOwnerSession,
            ownership: Self.ownership(store: store, clientID: "mac-initial-owner")
        )
        defer { initialOwner.releaseReceiveUserdataAfterSurfaceFree() }
        initialOwner.bindSurfaceSync(currentGridSize: { (cols: 100, rows: 30) }, requestRefresh: {})
        try initialOwner.start(surface: Self.fakeSurface())
        initialOwner.markLayoutSettled()

        let finalOwnerSession = FakeHostManagedSession()
        let finalOwner = Self.makeBackend(
            session: finalOwnerSession,
            ownership: Self.ownership(store: store, clientID: "mac-final-owner")
        )
        defer { finalOwner.releaseReceiveUserdataAfterSurfaceFree() }
        finalOwner.bindSurfaceSync(currentGridSize: { (cols: 90, rows: 24) }, requestRefresh: {})
        try finalOwner.start(surface: Self.fakeSurface())
        finalOwner.markLayoutSettled()

        let didRace = LockedFlag(false)
        let staleTakerSession = FakeHostManagedSession(
            resizeHook: { _, _ in
                guard !didRace.value() else { return }
                didRace.set(true)
                #expect(finalOwner.takeControl())
            }
        )
        let staleTaker = Self.makeBackend(
            session: staleTakerSession,
            ownership: Self.ownership(store: store, clientID: "mac-stale-taker")
        )
        defer { staleTaker.releaseReceiveUserdataAfterSurfaceFree() }
        staleTaker.bindSurfaceSync(currentGridSize: { (cols: 140, rows: 50) }, requestRefresh: {})
        try staleTaker.start(surface: Self.fakeSurface())
        staleTaker.markLayoutSettled()

        #expect(!staleTaker.takeControl())

        let snapshot = store.snapshot(sessionName: "graftty-test")
        let finalGrid = try DisplayGrid(cols: 90, rows: 24)
        #expect(snapshot.ownerClientID == DisplayClientID("mac-final-owner"))
        #expect(snapshot.grid == finalGrid)
        #expect(finalOwnerSession.resizes() == [Resize(cols: 90, rows: 24)])
        #expect(staleTakerSession.resizes() == [
            Resize(cols: 140, rows: 50),
            Resize(cols: 90, rows: 24),
        ])
    }

    @Test("A failed pending resize drained after start does not publish an unaccepted grid to the ownership store.")
    func failedStartingPendingResizeDoesNotAdvanceOwnershipGrid() throws {
        let store = SessionDisplayOwnershipStore()
        let startEntered = DispatchSemaphore(value: 0)
        let releaseStart = DispatchSemaphore(value: 0)
        let session = FakeHostManagedSession(
            startHook: {
                startEntered.signal()
                _ = releaseStart.wait(timeout: .now() + 2)
            }
        )
        let backend = Self.makeBackend(
            session: session,
            ownership: Self.ownership(store: store, clientID: "mac-owner")
        )
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        backend.bindSurfaceSync(currentGridSize: { (cols: 100, rows: 30) }, requestRefresh: {})

        let startFinished = DispatchSemaphore(value: 0)
        Self.runOnDedicatedThread {
            try? backend.start(surface: Self.fakeSurface())
            startFinished.signal()
        }
        #expect(startEntered.wait(timeout: .now() + 2) == .success)

        backend.markLayoutSettled()
        HostManagedZmxBackend.receiveResizeCallback(backend.userdataForTesting, 120, 30, 0, 0)
        session.setFailNextResize(true)

        releaseStart.signal()
        #expect(startFinished.wait(timeout: .now() + 2) == .success)

        let snapshot = store.snapshot(sessionName: "graftty-test")
        let spawnedGrid = try DisplayGrid(cols: 100, rows: 30)
        #expect(snapshot.ownerClientID == DisplayClientID("mac-owner"))
        #expect(snapshot.grid == spawnedGrid)
        #expect(session.resizes().isEmpty)
    }

    @Test func configureSetsHostManagedBackendAndReceiveCallbacks() {
        let backend = Self.makeBackend(session: FakeHostManagedSession())
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }

        var config = ghostty_surface_config_new()
        backend.configure(&config)

        #expect(config.backend == GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED)
        #expect(config.receive_userdata != nil)
        #expect(config.receive_buffer != nil)
        #expect(config.receive_resize != nil)
    }

    @Test func receiveBufferCallbackForwardsBytesToStartedSession() throws {
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(session: session)
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        try backend.start(surface: Self.fakeSurface())

        let bytes = Array("abc".utf8)
        bytes.withUnsafeBufferPointer { ptr in
            HostManagedZmxBackend.receiveBufferCallback(
                backend.userdataForTesting,
                ptr.baseAddress,
                ptr.count
            )
        }

        #expect(session.writes() == [Data("abc".utf8)])
    }

    @Test("Remote attachment accounting does not gate native viewport callbacks when no explicit ownership gate is installed.")
    func receiveResizeCallbackIgnoresRemoteAttachmentAccountingWithoutOwnershipGate() throws {
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(session: session, hasRemoteClient: { true })
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        try backend.start(surface: Self.fakeSurface())
        backend.markLayoutSettled()

        HostManagedZmxBackend.receiveResizeCallback(
            backend.userdataForTesting,
            132,
            43,
            2112,
            1032
        )
        #expect(session.resizes() == [Resize(cols: 132, rows: 43)])

        try backend.write(Data([0x68]))
        #expect(session.resizes() == [Resize(cols: 132, rows: 43)])

        HostManagedZmxBackend.receiveResizeCallback(
            backend.userdataForTesting,
            120,
            40,
            1440,
            960
        )
        #expect(session.resizes() == [Resize(cols: 132, rows: 43)])
    }

    @Test("`start(surface:)` discards stale pre-start viewport callbacks; nothing leaks to the PTY across attaches.")
    func startDiscardsPreStartViewportCallbacks() throws {
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(session: session)
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }

        HostManagedZmxBackend.receiveResizeCallback(
            backend.userdataForTesting,
            100,
            31,
            1200,
            744
        )
        HostManagedZmxBackend.receiveResizeCallback(
            backend.userdataForTesting,
            120,
            40,
            1440,
            960
        )

        try backend.start(surface: Self.fakeSurface())

        // Pre-start viewport measurements are stale w.r.t. the new surface
        // session and are dropped.
        #expect(session.resizes().isEmpty)

        // A user input alone does not synthesize a resize — there was no
        // post-start viewport callback to flush.
        try backend.write(Data([0x68]))
        #expect(session.resizes().isEmpty)
    }

    @Test func receiveCallbacksIgnoreNilUserdataAndPointers() {
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(session: session)
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }

        HostManagedZmxBackend.receiveBufferCallback(nil, nil, 3)
        HostManagedZmxBackend.receiveResizeCallback(nil, 80, 24, 800, 600)
        HostManagedZmxBackend.receiveBufferCallback(backend.userdataForTesting, nil, 3)

        #expect(session.writes().isEmpty)
        #expect(session.resizes().isEmpty)
    }

    @Test func startCreatesAndStartsNativeSessionFromSpawnConfigurationAndSurface() throws {
        let session = FakeHostManagedSession()
        let observedSurfaces = LockedRecorder<UnsafeMutableRawPointer>()
        let observedConfigurations = LockedRecorder<ZmxSpawnConfiguration>()
        let surface = Self.fakeSurface()
        let spawnConfiguration = Self.spawnConfiguration()
        let backend = HostManagedZmxBackend(
            spawnConfiguration: spawnConfiguration,
            sessionFactory: { startedSurface, configuration, _ in
                observedSurfaces.append(startedSurface)
                observedConfigurations.append(configuration)
                return session
            }
        )
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }

        try backend.start(surface: surface)

        #expect(session.startCount() == 1)
        #expect(observedSurfaces.values() == [surface])
        #expect(observedConfigurations.values() == [spawnConfiguration])
    }

    @Test func concurrentStartCreatesAndStartsOnlyOneSession() throws {
        let session = FakeHostManagedSession()
        let factoryCalls = LockedCounter()
        let factoryEntered = DispatchSemaphore(value: 0)
        let releaseFactory = DispatchSemaphore(value: 0)
        let backend = HostManagedZmxBackend(
            spawnConfiguration: Self.spawnConfiguration(),
            sessionFactory: { _, _, _ in
                _ = factoryCalls.increment()
                factoryEntered.signal()
                _ = releaseFactory.wait(timeout: .now() + 2)
                return session
            }
        )
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }

        let group = DispatchGroup()
        group.enter()
        Self.runOnDedicatedThread {
            try? backend.start(surface: Self.fakeSurface())
            group.leave()
        }

        #expect(factoryEntered.wait(timeout: .now() + 2) == .success)

        do {
            try backend.start(surface: Self.fakeSurface())
            Issue.record("concurrent start unexpectedly succeeded")
        } catch HostManagedZmxBackend.Error.alreadyStarted {
        } catch {
            Issue.record("concurrent start threw \(error) instead of alreadyStarted")
        }

        releaseFactory.signal()

        #expect(group.wait(timeout: .now() + 2) == .success)
        #expect(factoryCalls.value() == 1)
        #expect(session.startCount() == 1)
    }

    @Test func closeWhileSessionFactoryIsRunningClosesCreatedSessionWithoutStartingIt() {
        let session = FakeHostManagedSession()
        let factoryEntered = DispatchSemaphore(value: 0)
        let releaseFactory = DispatchSemaphore(value: 0)
        let backend = HostManagedZmxBackend(
            spawnConfiguration: Self.spawnConfiguration(),
            sessionFactory: { _, _, _ in
                factoryEntered.signal()
                _ = releaseFactory.wait(timeout: .now() + 2)
                return session
            }
        )
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }

        let startFinished = DispatchSemaphore(value: 0)
        let outcomes = LockedRecorder<Bool>()
        Self.runOnDedicatedThread {
            outcomes.append((try? backend.start(surface: Self.fakeSurface())) != nil)
            startFinished.signal()
        }

        #expect(factoryEntered.wait(timeout: .now() + 2) == .success)

        backend.close()
        releaseFactory.signal()

        #expect(startFinished.wait(timeout: .now() + 2) == .success)
        #expect(outcomes.values() == [false])
        #expect(session.startCount() == 0)
        #expect(session.closeCount() == 1)
    }

    @Test func startFailureClosesCreatedSessionAndRethrows() {
        struct ForcedStartFailure: Error {}

        let session = FakeHostManagedSession(startError: ForcedStartFailure())
        let backend = Self.makeBackend(session: session)
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }

        #expect(throws: Error.self) {
            try backend.start(surface: Self.fakeSurface())
        }

        #expect(session.startCount() == 1)
        #expect(session.closeCount() == 1)
    }

    @Test func closeRacingWithStartClosesCreatedSessionOnce() {
        let startEntered = DispatchSemaphore(value: 0)
        let releaseStart = DispatchSemaphore(value: 0)
        let session = FakeHostManagedSession(
            startHook: {
                startEntered.signal()
                _ = releaseStart.wait(timeout: .now() + 2)
            }
        )
        let backend = Self.makeBackend(session: session)
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }

        let startFinished = DispatchSemaphore(value: 0)
        let outcomes = LockedRecorder<Bool>()
        Self.runOnDedicatedThread {
            outcomes.append((try? backend.start(surface: Self.fakeSurface())) != nil)
            startFinished.signal()
        }

        #expect(startEntered.wait(timeout: .now() + 2) == .success)

        backend.close()
        backend.close()
        releaseStart.signal()

        #expect(startFinished.wait(timeout: .now() + 2) == .success)
        #expect(outcomes.values() == [false])
        #expect(session.startCount() == 1)
        #expect(session.closeCount() == 1)
    }

    @Test func writeForwardsExtraInputToStartedSession() throws {
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(session: session)
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        try backend.start(surface: Self.fakeSurface())

        try backend.write(Data("after-start\n".utf8))

        #expect(session.writes() == [Data("after-start\n".utf8)])
    }

    @Test func closeIsIdempotentAndClosesOwnedSessionOnce() throws {
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(session: session)
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        try backend.start(surface: Self.fakeSurface())

        backend.close()
        backend.close()

        #expect(session.closeCount() == 1)
    }

    @Test func releaseReceiveUserdataAfterSurfaceFreeIsIdempotentAndCallbacksWithNilAreSafe() {
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(session: session)

        backend.releaseReceiveUserdataAfterSurfaceFree()
        backend.releaseReceiveUserdataAfterSurfaceFree()

        #expect(backend.userdataForTesting == nil)
        HostManagedZmxBackend.receiveBufferCallback(nil, nil, 0)
        HostManagedZmxBackend.receiveResizeCallback(nil, 80, 24, 800, 600)
    }

    @Test("A remote attachment flag alone shall not suppress native resize authority; explicit display ownership is the only gate.")
    func remoteAttachmentFlagDoesNotSuppressNativeResizeAuthority() throws {
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(session: session, hasRemoteClient: { true })
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        try backend.start(surface: Self.fakeSurface())
        backend.markLayoutSettled()

        HostManagedZmxBackend.receiveResizeCallback(
            backend.userdataForTesting,
            80, 24, 960, 576
        )

        #expect(session.resizes() == [Resize(cols: 80, rows: 24)])
    }

    @Test("User input no longer claims hidden resize ownership after a remote-accounted viewport callback.")
    func userInputDoesNotClaimHiddenResizeOwnership() throws {
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(session: session, hasRemoteClient: { true })
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        try backend.start(surface: Self.fakeSurface())
        backend.markLayoutSettled()

        HostManagedZmxBackend.receiveResizeCallback(
            backend.userdataForTesting,
            80,
            24,
            960,
            576
        )
        #expect(session.resizes() == [Resize(cols: 80, rows: 24)])

        try backend.write(Data([0x68]))   // 'h'

        #expect(session.resizes() == [Resize(cols: 80, rows: 24)])
    }

    @Test("Post-layout libghostty viewport callbacks propagate to the PTY immediately on the leading edge, or as the coalesced trailing resize (TERM-11.9).")
    func postLayoutResizesArePropagated() throws {
        let session = FakeHostManagedSession()
        let coalescer = ManualResizeCoalescer()
        let backend = Self.makeBackend(session: session, coalescer: coalescer)
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        try backend.start(surface: Self.fakeSurface())
        backend.markLayoutSettled()

        try backend.write(Data([0x68]))

        HostManagedZmxBackend.receiveResizeCallback(
            backend.userdataForTesting,
            120,
            40,
            1440,
            960
        )
        HostManagedZmxBackend.receiveResizeCallback(
            backend.userdataForTesting,
            100,
            40,
            1200,
            960
        )
        coalescer.fireAll()

        #expect(session.resizes() == [Resize(cols: 120, rows: 40), Resize(cols: 100, rows: 40)])
    }

    @Test func defaultSessionFactoryReceivesInitialSizeFromBackend() throws {
        final class CapturingSession: HostManagedZmxSession {
            var startCount = 0
            func start() throws { startCount += 1 }
            func write(_ data: Data) throws {}
            func resize(cols: UInt16, rows: UInt16) throws {}
            func close() {}
        }
        let captured = LockedRecorder<(cols: UInt16, rows: UInt16)?>()
        let session = CapturingSession()
        let backend = HostManagedZmxBackend(
            spawnConfiguration: Self.spawnConfiguration(),
            initialSize: (cols: 132, rows: 43),
            sessionFactory: { _, _, initialSize in
                captured.append(initialSize)
                return session
            }
        )
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }

        try backend.start(surface: Self.fakeSurface())

        #expect(session.startCount == 1)
        let recorded = captured.values()
        #expect(recorded.count == 1)
        #expect(recorded.first??.cols == 132)
        #expect(recorded.first??.rows == 43)
    }

    @Test("`write(_:claimEngagement:)` does not control resize ownership; explicit display ownership does.")
    func programmaticWriteDoesNotControlResizeOwnership() throws {
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(session: session, hasRemoteClient: { true })
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        try backend.start(surface: Self.fakeSurface())
        backend.markLayoutSettled()

        HostManagedZmxBackend.receiveResizeCallback(
            backend.userdataForTesting,
            132, 43, 2112, 1032
        )
        #expect(session.resizes() == [Resize(cols: 132, rows: 43)])

        try backend.write(Data("hello".utf8), claimEngagement: false)
        #expect(session.resizes() == [Resize(cols: 132, rows: 43)])
        #expect(session.writes() == [Data("hello".utf8)])

        try backend.write(Data([0x68]))
        #expect(session.resizes() == [Resize(cols: 132, rows: 43)])
    }

    @Test("""
    @spec TERM-11.12: While the zmx session has not yet started, the application shall queue PTY writes and deliver them in order once the session starts (after any queued resize) — a `pane add --command` issued before the pane's first layout shall not be dropped.
    """)
    func preStartWritesAreQueuedAndDeliveredOnStart() throws {
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(session: session)
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        // Note: no start() — backend is in .idle, as when `graftty pane
        // add --command` types before the pane's first layout.

        try backend.write(Data("claude\r".utf8), claimEngagement: false)
        try backend.write(Data("hello".utf8), claimEngagement: false)
        #expect(session.writes().isEmpty)

        try backend.start(surface: Self.fakeSurface())
        #expect(session.writes() == [Data("claude\r".utf8), Data("hello".utf8)])
    }

    @Test("A queued pre-start write is delivered after start and a write on a closed backend still throws (TERM-11.12).")
    func queuedWriteDefersToDeliveryAndClosedStillThrows() throws {
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(session: session, hasRemoteClient: { true })
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        backend.bindSurfaceSync(
            currentGridSize: { (cols: 142, rows: 38) },
            requestRefresh: {}
        )

        try backend.write(Data([0x68]))
        #expect(session.resizes().isEmpty)

        try backend.start(surface: Self.fakeSurface())
        backend.markLayoutSettled()
        #expect(session.writes() == [Data([0x68])])
        HostManagedZmxBackend.receiveResizeCallback(
            backend.userdataForTesting,
            132, 43, 2112, 1032
        )
        #expect(session.resizes().contains(Resize(cols: 132, rows: 43)))

        backend.close()
        #expect(throws: HostManagedZmxBackend.Error.closed) {
            try backend.write(Data("x".utf8))
        }
    }

    // MARK: - TERM-11.x — PTY/grid size sync

    @Test("@spec TERM-11.1: When pane layout settles and no remote client is attached to the zmx session, the application shall resize the zmx PTY to the current libghostty grid size without waiting for user input.")
    func layoutSettleSyncsPtyToGridWhenNoRemoteAttached() throws {
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(session: session)
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        backend.bindSurfaceSync(
            currentGridSize: { (cols: 142, rows: 38) },
            requestRefresh: {}
        )
        try backend.start(surface: Self.fakeSurface())

        backend.markLayoutSettled()

        #expect(session.resizes() == [Resize(cols: 142, rows: 38)])
    }

    @Test("@spec TERM-11.2: While no remote client is attached and layout has settled, a libghostty viewport callback shall resize the zmx PTY immediately, before any user input.")
    func postLayoutViewportCallbackForwardsImmediatelyWhenNoRemoteAttached() throws {
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(session: session)
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        backend.bindSurfaceSync(currentGridSize: { nil }, requestRefresh: {})
        try backend.start(surface: Self.fakeSurface())
        backend.markLayoutSettled()

        HostManagedZmxBackend.receiveResizeCallback(
            backend.userdataForTesting,
            132, 43, 2112, 1032
        )

        #expect(session.resizes() == [Resize(cols: 132, rows: 43)])
    }

    @Test("Remote attachment accounting does not re-arm resize withholding after a standalone viewport callback.")
    func remoteAttachmentDoesNotRearmResizeWithholding() throws {
        let session = FakeHostManagedSession()
        let coalescer = ManualResizeCoalescer()
        let remoteAttached = LockedFlag(false)
        let backend = Self.makeBackend(
            session: session,
            hasRemoteClient: { remoteAttached.value() },
            coalescer: coalescer
        )
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        backend.bindSurfaceSync(currentGridSize: { nil }, requestRefresh: {})
        try backend.start(surface: Self.fakeSurface())
        backend.markLayoutSettled()

        HostManagedZmxBackend.receiveResizeCallback(
            backend.userdataForTesting,
            132, 43, 2112, 1032
        )
        #expect(session.resizes() == [Resize(cols: 132, rows: 43)])
        coalescer.fireAll()

        remoteAttached.set(true)
        HostManagedZmxBackend.receiveResizeCallback(
            backend.userdataForTesting,
            100, 30, 1200, 720
        )
        #expect(session.resizes() == [Resize(cols: 132, rows: 43), Resize(cols: 100, rows: 30)])
    }

    @Test("Ownerless standalone backends resize from layout/viewport callbacks, not first user input.")
    func standaloneBackendDoesNotResizeOnFirstUserInput() throws {
        let session = FakeHostManagedSession()
        let refreshes = LockedCounter()
        let backend = Self.makeBackend(session: session, hasRemoteClient: { true })
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        backend.bindSurfaceSync(
            currentGridSize: { (cols: 142, rows: 38) },
            requestRefresh: { _ = refreshes.increment() }
        )
        try backend.start(surface: Self.fakeSurface())
        backend.markLayoutSettled()
        #expect(session.resizes() == [Resize(cols: 142, rows: 38)])

        HostManagedZmxBackend.receiveResizeCallback(
            backend.userdataForTesting,
            132, 43, 2112, 1032
        )
        #expect(session.resizes() == [Resize(cols: 142, rows: 38), Resize(cols: 132, rows: 43)])

        try backend.write(Data([0x68]))
        #expect(session.resizes() == [Resize(cols: 142, rows: 38), Resize(cols: 132, rows: 43)])
        #expect(refreshes.value() == 0)
    }

    @Test("A viewport callback supplies the resize target when no grid size provider is bound.")
    func viewportCallbackSuppliesSizeWhenNoGridProviderIsBound() throws {
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(session: session, hasRemoteClient: { true })
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        try backend.start(surface: Self.fakeSurface())
        backend.markLayoutSettled()

        HostManagedZmxBackend.receiveResizeCallback(
            backend.userdataForTesting,
            132, 43, 2112, 1032
        )
        try backend.write(Data([0x68]))
        #expect(session.resizes() == [Resize(cols: 132, rows: 43)])
    }

    @Test("Remote detach notification is connection accounting only and does not resize the native PTY.")
    func lastRemoteDetachDoesNotResizeNativePty() throws {
        let session = FakeHostManagedSession()
        let remoteAttached = LockedFlag(true)
        let backend = Self.makeBackend(
            session: session,
            hasRemoteClient: { remoteAttached.value() }
        )
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        backend.bindSurfaceSync(
            currentGridSize: { (cols: 142, rows: 38) },
            requestRefresh: {}
        )
        try backend.start(surface: Self.fakeSurface())
        backend.markLayoutSettled()
        #expect(session.resizes() == [Resize(cols: 142, rows: 38)])

        remoteAttached.set(false)
        backend.remoteClientsDidDetach()

        #expect(session.resizes() == [Resize(cols: 142, rows: 38)])
    }

    @Test("remoteClientsDidDetach shall remain a no-op even when another client is present.")
    func remoteDetachWithImmediateReattachDoesNotSync() throws {
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(session: session, hasRemoteClient: { true })
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        backend.bindSurfaceSync(
            currentGridSize: { (cols: 142, rows: 38) },
            requestRefresh: {}
        )
        try backend.start(surface: Self.fakeSurface())
        backend.markLayoutSettled()
        #expect(session.resizes() == [Resize(cols: 142, rows: 38)])

        backend.remoteClientsDidDetach()   // hasRemoteClient still true
        #expect(session.resizes() == [Resize(cols: 142, rows: 38)])
    }

    @Test("remoteClientsDidDetach shall be a no-op after local viewport callbacks are already flowing.")
    func remoteDetachAfterEngagementDoesNothing() throws {
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(session: session)
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        try backend.start(surface: Self.fakeSurface())
        try backend.write(Data([0x68]))   // engage, nothing queued
        let countAfterEngage = session.resizes().count

        backend.remoteClientsDidDetach()
        #expect(session.resizes().count == countAfterEngage)
    }

    @Test("markLayoutSettled shall be idempotent — only the first call performs the one-shot sync.")
    func markLayoutSettledIsIdempotent() throws {
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(session: session)
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        backend.bindSurfaceSync(
            currentGridSize: { (cols: 142, rows: 38) },
            requestRefresh: {}
        )
        try backend.start(surface: Self.fakeSurface())

        backend.markLayoutSettled()
        backend.markLayoutSettled()
        #expect(session.resizes() == [Resize(cols: 142, rows: 38)])
    }

    @Test("While layout has not settled, a viewport callback shall be withheld even with no remote client attached — protection against the pre-layout libghostty callback that PR 201 fixed.")
    func preLayoutCallbackIsWithheldEvenWithoutRemote() throws {
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(session: session)
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        try backend.start(surface: Self.fakeSurface())

        // No markLayoutSettled() — the pre-layout phase.
        HostManagedZmxBackend.receiveResizeCallback(
            backend.userdataForTesting,
            80, 24, 960, 576
        )
        #expect(session.resizes().isEmpty)
    }

    @Test("start(surface:) shall spawn the PTY at the live grid size when a grid provider is bound, falling back to the construction-time initialSize — so a deferred start (TERM-11.10) attaches at the settled dims, not the stale eviction cache.")
    func startSpawnsAtLiveGridSizeWhenBound() throws {
        let captured = LockedRecorder<(cols: UInt16, rows: UInt16)?>()
        let session = FakeHostManagedSession()
        let backend = HostManagedZmxBackend(
            spawnConfiguration: Self.spawnConfiguration(),
            initialSize: (cols: 49, rows: 17),
            sessionFactory: { _, _, initialSize in
                captured.append(initialSize)
                return session
            }
        )
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        backend.bindSurfaceSync(
            currentGridSize: { (cols: 224, rows: 82) },
            requestRefresh: {}
        )

        try backend.start(surface: Self.fakeSurface())

        let recorded = captured.values()
        #expect(recorded.count == 1)
        #expect(recorded.first??.cols == 224)
        #expect(recorded.first??.rows == 82)
    }

    // MARK: - TERM-11.11 / TERM-11.14 — no synthetic bounce on agreeing grid; real delta only

    @Test("@spec TERM-11.11: A show-time reconcile shall forward the live libghostty grid to the zmx PTY unconditionally, not short-circuiting on an in-sync comparison against the optimistic last-forwarded record — a same-size forward is a kernel no-op (no SIGWINCH) so it never churns the TUI, while a Mac/daemon size divergence is always corrected on the next show instead of being hidden by a false in-sync check. The failure case that makes the optimistic record unsafe to trust is exercised by `TERM-11.15`.")
    func showReconcileForwardsLiveGridUnconditionally() throws {
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(session: session)
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        backend.bindSurfaceSync(currentGridSize: { (cols: 108, rows: 90) }, requestRefresh: {})
        try backend.start(surface: Self.fakeSurface())
        backend.markLayoutSettled()
        #expect(session.resizes() == [Resize(cols: 108, rows: 90)])
        backend.resyncVisibleGrid()
        #expect(session.resizes() == [Resize(cols: 108, rows: 90), Resize(cols: 108, rows: 90)])
    }

    @Test("@spec TERM-11.14: When a kept-alive pane is switched back to and the live grid differs from the PTY, the application shall forward exactly that live grid once (a single real resize / SIGWINCH) and never a synthetic rows-1/rows bounce.")
    func reShowAtDriftedGridForwardsOneRealResizeNoBounce() throws {
        let session = FakeHostManagedSession()
        let coalescer = ManualResizeCoalescer()
        let drifted = LockedFlag(false)
        let backend = Self.makeBackend(session: session, coalescer: coalescer)
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        backend.bindSurfaceSync(
            currentGridSize: { drifted.value() ? (cols: 108, rows: 88) : (cols: 108, rows: 90) },
            requestRefresh: {}
        )
        try backend.start(surface: Self.fakeSurface())
        backend.markLayoutSettled()
        drifted.set(true)

        backend.resyncVisibleGrid()
        coalescer.fireAll()
        #expect(session.resizes() == [Resize(cols: 108, rows: 90), Resize(cols: 108, rows: 88)])
        #expect(!session.resizes().contains(Resize(cols: 108, rows: 87)))
    }

    // MARK: - TERM-11.13 — re-show resync (stale PTY size latched while occluded)

    @Test("@spec TERM-11.13: When a pane re-enters the visible set, the application shall forward the live libghostty grid to the zmx PTY unconditionally — so a row count latched while the surface was occluded (which libghostty never re-reported because the grid had no delta to emit) is corrected on every show rather than hidden by an optimistic last-forwarded record. A same-size forward is a kernel no-op (no SIGWINCH), so plain focus switches do not churn the TUI; a drifted grid produces exactly one real resize.")
    func reShowResyncsPtyToLiveGridUnconditionally() throws {
        let session = FakeHostManagedSession()
        let refreshes = LockedCounter()
        let drifted = LockedFlag(false)
        let backend = Self.makeBackend(session: session)
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        backend.bindSurfaceSync(
            currentGridSize: { drifted.value() ? (cols: 108, rows: 88) : (cols: 108, rows: 90) },
            requestRefresh: { _ = refreshes.increment() }
        )
        try backend.start(surface: Self.fakeSurface())

        // Attach settles at 108x90 — the PTY adopts the grid libghostty is
        // rendering. (Settle drops its refresh; setFrameSize already issued
        // one on the same frame event.)
        backend.markLayoutSettled()
        #expect(session.resizes() == [Resize(cols: 108, rows: 90)])
        #expect(refreshes.value() == 0)

        // While the pane is occluded the window's row count drifts to 88, but
        // libghostty emits no viewport callback — the occluded surface already
        // held that grid, so there was no delta to report. The PTY keeps its
        // stale 90 rows; nothing has reconciled it.
        drifted.set(true)
        #expect(session.resizes() == [Resize(cols: 108, rows: 90)])

        // The pane is shown again: the re-show resync forwards the live grid
        // (108x88) to the PTY and forces a refresh, re-anchoring the TUI.
        backend.resyncVisibleGrid()
        #expect(session.resizes() == [Resize(cols: 108, rows: 90), Resize(cols: 108, rows: 88)])
        #expect(refreshes.value() == 1)

        // A further show at the same (now-agreed) grid still forwards unconditionally —
        // the same-size ioctl is a kernel no-op (no SIGWINCH), so forwarding costs one
        // syscall but never churns the TUI, while it guarantees divergence recovery.
        backend.resyncVisibleGrid()
        #expect(session.resizes() == [Resize(cols: 108, rows: 90), Resize(cols: 108, rows: 88), Resize(cols: 108, rows: 88)])
        #expect(refreshes.value() == 2)
    }

    @Test("The re-show resync shall ignore remote attachment accounting; explicit ownership is the only native resize gate.")
    func reShowResyncIgnoresRemoteAttachmentAccounting() throws {
        let session = FakeHostManagedSession()
        let remoteAttached = LockedFlag(true)
        let backend = Self.makeBackend(session: session, hasRemoteClient: { remoteAttached.value() })
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        backend.bindSurfaceSync(
            currentGridSize: { (cols: 108, rows: 88) },
            requestRefresh: {}
        )
        try backend.start(surface: Self.fakeSurface())
        backend.markLayoutSettled()
        #expect(session.resizes() == [Resize(cols: 108, rows: 88)])

        backend.resyncVisibleGrid()
        #expect(session.resizes() == [Resize(cols: 108, rows: 88), Resize(cols: 108, rows: 88)])
    }

    @Test("@spec TERM-11.15: When a forward to the PTY fails (a swallowed resize error), the application shall not record it as the last-forwarded size; a subsequent show reconcile shall re-forward the live grid and correct the divergence rather than treat the failed size as in sync.")
    func failedForwardDoesNotLatchInSyncAndShowReForwards() throws {
        let session = FakeHostManagedSession()
        let coalescer = ManualResizeCoalescer()
        let drifted = LockedFlag(false)
        let backend = Self.makeBackend(session: session, coalescer: coalescer)
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        backend.bindSurfaceSync(
            currentGridSize: { drifted.value() ? (cols: 80, rows: 30) : (cols: 80, rows: 24) },
            requestRefresh: {}
        )
        try backend.start(surface: Self.fakeSurface())
        backend.markLayoutSettled()                       // forwards 80x24 OK
        #expect(session.resizes() == [Resize(cols: 80, rows: 24)])

        // The grid drifts to 80x30 and the forward FAILS (transient bad fd):
        // the PTY never adopts 80x30, and lastForwardedResize must NOT latch
        // a value the PTY never received.
        drifted.set(true)
        session.setFailNextResize(true)
        HostManagedZmxBackend.receiveResizeCallback(backend.userdataForTesting, 80, 30, 0, 0)
        session.setFailNextResize(false)
        coalescer.fireAll()
        // The failed resize never reached the PTY.
        #expect(!session.resizes().contains(Resize(cols: 80, rows: 30)))

        // The next show must RE-FORWARD the live grid (now 80x30) and correct
        // the divergence — proving a failed forward did not poison the reconcile
        // into a false in-sync state. Under the pre-fix code this no-op'd
        // (live grid == stale lastForwardedResize) and the desync persisted.
        backend.resyncVisibleGrid()
        #expect(session.resizes().last == Resize(cols: 80, rows: 30))
    }

    // MARK: - TERM-11.9 — resize coalescing (divider-drag SIGWINCH storms)

    @Test("@spec TERM-11.9: While a rapid sequence of libghostty viewport callbacks arrives, the application shall forward the first resize to the zmx PTY immediately and coalesce the remainder, delivering at most one trailing resize with the latest dimensions per quiet window, so a divider drag emits a bounded SIGWINCH stream that always ends at the final size.")
    func resizeBurstForwardsLeadingEdgeAndLatestTrailing() throws {
        let session = FakeHostManagedSession()
        let coalescer = ManualResizeCoalescer()
        let backend = Self.makeBackend(session: session, coalescer: coalescer)
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        try backend.start(surface: Self.fakeSurface())
        backend.markLayoutSettled()

        // Drag burst: 213 → 200 → 150 → 106 within one quiet window.
        for cols in [213, 200, 150, 106] {
            HostManagedZmxBackend.receiveResizeCallback(
                backend.userdataForTesting,
                UInt16(cols), 82, 0, 0
            )
        }
        // Leading edge forwarded immediately; the rest held.
        #expect(session.resizes() == [Resize(cols: 213, rows: 82)])

        // Quiet window elapses: exactly one trailing resize, latest dims.
        coalescer.fireAll()
        #expect(session.resizes() == [Resize(cols: 213, rows: 82), Resize(cols: 106, rows: 82)])
    }

    @Test("Coalescing shall skip the trailing resize when the latest burst size equals the last forwarded size — no redundant SIGWINCH (TERM-11.9).")
    func trailingResizeSkippedWhenSizeUnchanged() throws {
        let session = FakeHostManagedSession()
        let coalescer = ManualResizeCoalescer()
        let backend = Self.makeBackend(session: session, coalescer: coalescer)
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        try backend.start(surface: Self.fakeSurface())
        backend.markLayoutSettled()

        HostManagedZmxBackend.receiveResizeCallback(backend.userdataForTesting, 213, 82, 0, 0)
        HostManagedZmxBackend.receiveResizeCallback(backend.userdataForTesting, 150, 82, 0, 0)
        HostManagedZmxBackend.receiveResizeCallback(backend.userdataForTesting, 213, 82, 0, 0)

        coalescer.fireAll()
        #expect(session.resizes() == [Resize(cols: 213, rows: 82)])
    }

    @Test("A sustained drag shall keep throttling: each trailing forward reopens the quiet window so later burst events coalesce again (TERM-11.9).")
    func sustainedDragKeepsThrottling() throws {
        let session = FakeHostManagedSession()
        let coalescer = ManualResizeCoalescer()
        let backend = Self.makeBackend(session: session, coalescer: coalescer)
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        try backend.start(surface: Self.fakeSurface())
        backend.markLayoutSettled()

        HostManagedZmxBackend.receiveResizeCallback(backend.userdataForTesting, 213, 82, 0, 0)
        HostManagedZmxBackend.receiveResizeCallback(backend.userdataForTesting, 180, 82, 0, 0)
        #expect(session.resizes() == [Resize(cols: 213, rows: 82)])
        #expect(coalescer.scheduleCount == 1)

        // First window elapses → trailing 180 forwarded, NEW window opens.
        coalescer.fireNext()
        #expect(session.resizes() == [Resize(cols: 213, rows: 82), Resize(cols: 180, rows: 82)])
        #expect(coalescer.scheduleCount == 2)

        // Events inside the reopened window coalesce instead of forwarding.
        HostManagedZmxBackend.receiveResizeCallback(backend.userdataForTesting, 140, 82, 0, 0)
        HostManagedZmxBackend.receiveResizeCallback(backend.userdataForTesting, 106, 82, 0, 0)
        #expect(session.resizes().count == 2)
        coalescer.fireAll()
        #expect(session.resizes().last == Resize(cols: 106, rows: 82))
    }

    @Test("A sync flush (layout-settle / show reconcile) shall supersede any pending coalesced resize so a stale mid-drag size cannot land after the flush (TERM-11.9).")
    func flushSupersedesPendingCoalescedResize() throws {
        let session = FakeHostManagedSession()
        let coalescer = ManualResizeCoalescer()
        let backend = Self.makeBackend(session: session, coalescer: coalescer)
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        backend.bindSurfaceSync(
            currentGridSize: { (cols: 106, rows: 82) },
            requestRefresh: {}
        )
        try backend.start(surface: Self.fakeSurface())
        backend.markLayoutSettled()
        // Settle flush shipped the grid (106x82).
        #expect(session.resizes() == [Resize(cols: 106, rows: 82)])

        // Silent-state burst: leading edge forwards, 150x82 left pending.
        HostManagedZmxBackend.receiveResizeCallback(backend.userdataForTesting, 213, 82, 0, 0)
        HostManagedZmxBackend.receiveResizeCallback(backend.userdataForTesting, 150, 82, 0, 0)

        // Show-time reconcile ships the current grid and clears the pending
        // coalesced size — the stale 150x82 must never land afterwards.
        backend.resyncVisibleGrid()
        let afterFlush = session.resizes()
        #expect(afterFlush.last == Resize(cols: 106, rows: 82))

        coalescer.fireAll()
        #expect(session.resizes() == afterFlush)
    }

    @Test("close() shall cancel a scheduled trailing resize; a fire that races close shall not resize a closed backend (TERM-11.9).")
    func closeCancelsPendingTrailingResize() throws {
        let session = FakeHostManagedSession()
        let coalescer = ManualResizeCoalescer()
        let backend = Self.makeBackend(session: session, coalescer: coalescer)
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        try backend.start(surface: Self.fakeSurface())
        backend.markLayoutSettled()

        HostManagedZmxBackend.receiveResizeCallback(backend.userdataForTesting, 213, 82, 0, 0)
        HostManagedZmxBackend.receiveResizeCallback(backend.userdataForTesting, 150, 82, 0, 0)
        let beforeClose = session.resizes()

        backend.close()
        #expect(coalescer.cancelCount == 1)
        coalescer.fireAll()
        #expect(session.resizes() == beforeClose)
    }

    // MARK: - TERM-11.6/11.7/11.8 — pre-layout protection + input classification

    @Test("@spec TERM-11.6: When input arrives before layout has settled, the application shall still defer PTY sync until layout settles rather than resize the PTY to the pre-layout grid.")
    func preLayoutInputDoesNotFlushUntilLayoutSettles() throws {
        let session = FakeHostManagedSession()
        let settled = LockedFlag(false)
        let backend = Self.makeBackend(session: session)
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        // The grid reports the bogus pre-layout placeholder (49x17) until
        // layout lands, then the real dims — mirroring the trace captured
        // on 2026-06-10.
        backend.bindSurfaceSync(
            currentGridSize: { settled.value() ? (cols: 194, rows: 74) : (cols: 49, rows: 17) },
            requestRefresh: {}
        )
        try backend.start(surface: Self.fakeSurface())

        HostManagedZmxBackend.receiveResizeCallback(
            backend.userdataForTesting,
            49, 17, 588, 272
        )
        // Input before the first real layout.
        try backend.write(Data([0x68]))
        #expect(session.resizes().isEmpty)

        settled.set(true)
        backend.markLayoutSettled()
        #expect(session.resizes() == [Resize(cols: 194, rows: 74)])
    }

    @Test("@spec TERM-11.7: While layout has not settled, the application shall not forward viewport callbacks to the zmx PTY even after input.")
    func preLayoutCallbackWithheldEvenAfterInput() throws {
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(session: session)
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        try backend.start(surface: Self.fakeSurface())

        try backend.write(Data([0x68]))
        HostManagedZmxBackend.receiveResizeCallback(
            backend.userdataForTesting,
            49, 17, 588, 272
        )
        #expect(session.resizes().isEmpty)

        // Settling flushes the best available size (the withheld callback,
        // since no grid provider is bound), then live callbacks flow.
        backend.markLayoutSettled()
        #expect(session.resizes() == [Resize(cols: 49, rows: 17)])
        HostManagedZmxBackend.receiveResizeCallback(
            backend.userdataForTesting,
            120, 40, 1440, 960
        )
        #expect(session.resizes() == [Resize(cols: 49, rows: 17), Resize(cols: 120, rows: 40)])
    }

    @Test("@spec TERM-11.8: User-input scopes annotate libghostty callback bytes for input routing only; they no longer claim resize ownership.")
    func callbackBytesInsideUserInputScopeDoNotClaimResizeOwnership() throws {
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(session: session, hasRemoteClient: { true })
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        backend.bindSurfaceSync(
            currentGridSize: { (cols: 142, rows: 38) },
            requestRefresh: {}
        )
        try backend.start(surface: Self.fakeSurface())
        backend.markLayoutSettled()
        #expect(session.resizes() == [Resize(cols: 142, rows: 38)])

        // A terminal-query auto-response (e.g. DA1 reply) arrives through
        // the receive-buffer callback with no key event in flight.
        let response = Array("\u{1b}[?1;2c".utf8)
        response.withUnsafeBufferPointer { ptr in
            HostManagedZmxBackend.receiveBufferCallback(
                backend.userdataForTesting,
                ptr.baseAddress,
                ptr.count
            )
        }
        // The callback forwards based on layout/ownership, not the user-input
        // scope that produced the previous bytes.
        HostManagedZmxBackend.receiveResizeCallback(
            backend.userdataForTesting,
            132, 43, 2112, 1032
        )
        #expect(session.resizes() == [Resize(cols: 142, rows: 38), Resize(cols: 132, rows: 43)])

        let key = Array("h".utf8)
        backend.withUserInputScope {
            key.withUnsafeBufferPointer { ptr in
                HostManagedZmxBackend.receiveBufferCallback(
                    backend.userdataForTesting,
                    ptr.baseAddress,
                    ptr.count
                )
            }
        }
        #expect(session.resizes() == [Resize(cols: 142, rows: 38), Resize(cols: 132, rows: 43)])
    }

    private static func makeBackend(
        session: FakeHostManagedSession,
        hasRemoteClient: @escaping () -> Bool = { false },
        ownership: HostManagedZmxOwnership? = nil,
        coalescer: ManualResizeCoalescer? = nil
    ) -> HostManagedZmxBackend {
        // Tests that don't pump a ManualResizeCoalescer get an inert
        // scheduler (records, never fires) — the production GCD
        // scheduler would arm real 75ms timers that can race assertions
        // on a loaded CI runner.
        let effective = coalescer ?? ManualResizeCoalescer()
        return HostManagedZmxBackend(
            spawnConfiguration: spawnConfiguration(),
            hasRemoteClient: hasRemoteClient,
            ownership: ownership,
            scheduleCoalescedResize: { delay, fire in effective.schedule(delay, fire) },
            sessionFactory: { _, _, _ in session }
        )
    }

    private static func ownership(
        store: SessionDisplayOwnershipStore,
        clientID: String,
        sessionName: String = "graftty-test"
    ) -> HostManagedZmxOwnership {
        HostManagedZmxOwnership(
            store: store,
            sessionName: sessionName,
            clientID: DisplayClientID(clientID),
            kind: .mac
        )
    }

    private static func spawnConfiguration() -> ZmxSpawnConfiguration {
        // ZMX-6.6: argv shape for zsh drops the positional shell —
        // zmx's default-spawn picks up env["SHELL"].
        ZmxSpawnConfiguration(
            sessionName: "graftty-test",
            argv: ["/tmp/zmx", "attach", "graftty-test"],
            env: ["ZMX_DIR": "/tmp/zmx-dir", "SHELL": "/bin/zsh"],
            workingDirectory: URL(fileURLWithPath: "/tmp/worktree", isDirectory: true)
        )
    }

    private static func fakeSurface() -> ghostty_surface_t {
        UnsafeMutableRawPointer(bitPattern: 0x1234)!
    }

    @discardableResult
    private static func runOnDedicatedThread(_ body: @escaping () -> Void) -> Thread {
        let thread = Thread(block: body)
        thread.start()
        return thread
    }

    @Test("When two threads race to `write` after a viewport callback, the already-forwarded resize remains ordered before the write bytes.")
    func forwardedResizeOrdersBeforeConcurrentWriteBytes() throws {
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(session: session, hasRemoteClient: { true })
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        try backend.start(surface: Self.fakeSurface())
        backend.markLayoutSettled()

        HostManagedZmxBackend.receiveResizeCallback(
            backend.userdataForTesting,
            132, 43, 2112, 1032
        )

        let barrier = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        var threadAFinished = false
        var threadBFinished = false

        // Thread A enters write first; the resize was already forwarded by
        // the viewport callback before either write can reach the PTY.
        Self.runOnDedicatedThread {
            try? backend.write(Data("a".utf8))
            threadAFinished = true
            barrier.signal()
        }
        // Thread B races in behind A.
        Self.runOnDedicatedThread {
            // Tiny stagger so A enters write first.
            Thread.sleep(forTimeInterval: 0.001)
            try? backend.write(Data("b".utf8))
            threadBFinished = true
            done.signal()
        }

        barrier.wait()
        done.wait()
        #expect(threadAFinished)
        #expect(threadBFinished)

        #expect(session.resizes() == [Resize(cols: 132, rows: 43)])
        #expect(session.writes().count == 2)
    }
}

private struct Resize: Equatable {
    let cols: UInt16
    let rows: UInt16
}

/// Deterministic stand-in for the backend's resize-coalescing scheduler:
/// records each scheduled trailing fire; tests pump them with `fireAll()`.
final class ManualResizeCoalescer: @unchecked Sendable {
    private final class Entry {
        var fire: (() -> Void)?
        init(_ fire: @escaping () -> Void) { self.fire = fire }
    }

    private let lock = NSLock()
    private var queued: [Entry] = []
    private(set) var scheduleCount = 0
    private(set) var cancelCount = 0

    func schedule(_ delay: TimeInterval, _ fire: @escaping () -> Void) -> (() -> Void) {
        let entry = Entry(fire)
        lock.lock()
        queued.append(entry)
        scheduleCount += 1
        lock.unlock()
        return { [weak self] in
            guard let self else { return }
            self.lock.lock()
            entry.fire = nil
            self.cancelCount += 1
            self.lock.unlock()
        }
    }

    /// Runs exactly one queued trailing fire (the oldest), leaving any
    /// window it reopens armed — models a single quiet-window expiry.
    func fireNext() {
        lock.lock()
        guard !queued.isEmpty else {
            lock.unlock()
            return
        }
        let entry = queued.removeFirst()
        let fire = entry.fire
        lock.unlock()
        fire?()
    }

    /// Runs every queued (uncancelled) trailing fire, including any that
    /// get scheduled BY a fire (sustained-drag windows reopen).
    func fireAll() {
        while true {
            lock.lock()
            guard !queued.isEmpty else {
                lock.unlock()
                return
            }
            let entry = queued.removeFirst()
            let fire = entry.fire
            lock.unlock()
            fire?()
        }
    }
}

private final class FakeHostManagedSession: HostManagedZmxSession {
    private struct FakeResizeError: Error {}

    private let lock = NSLock()
    private let startError: Error?
    private let startHook: (() -> Void)?
    private let resizeHook: ((UInt16, UInt16) -> Void)?
    private var storedWrites: [Data] = []
    private var storedResizes: [Resize] = []
    private var storedStartCount = 0
    private var storedCloseCount = 0
    private var failNextResize = false

    init(
        startError: Error? = nil,
        startHook: (() -> Void)? = nil,
        resizeHook: ((UInt16, UInt16) -> Void)? = nil
    ) {
        self.startError = startError
        self.startHook = startHook
        self.resizeHook = resizeHook
    }

    func start() throws {
        lock.lock()
        storedStartCount += 1
        let error = startError
        let hook = startHook
        lock.unlock()

        hook?()
        if let error {
            throw error
        }
    }

    func write(_ data: Data) throws {
        lock.lock()
        storedWrites.append(data)
        lock.unlock()
    }

    func resize(cols: UInt16, rows: UInt16) throws {
        lock.lock()
        let shouldFail = failNextResize
        if shouldFail { failNextResize = false }
        lock.unlock()

        resizeHook?(cols, rows)

        lock.lock()
        if !shouldFail { storedResizes.append(Resize(cols: cols, rows: rows)) }
        lock.unlock()
        if shouldFail { throw FakeResizeError() }
    }

    func close() {
        lock.lock()
        storedCloseCount += 1
        lock.unlock()
    }

    func setFailNextResize(_ fail: Bool) {
        lock.lock()
        failNextResize = fail
        lock.unlock()
    }

    func writes() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return storedWrites
    }

    func resizes() -> [Resize] {
        lock.lock()
        defer { lock.unlock() }
        return storedResizes
    }

    func startCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return storedStartCount
    }

    func closeCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCloseCount
    }
}

private final class LockedRecorder<Value> {
    private let lock = NSLock()
    private var stored: [Value] = []

    func append(_ value: Value) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }

    func values() -> [Value] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool

    init(_ value: Bool) {
        self.stored = value
    }

    func value() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: Bool) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}

private final class LockedCounter {
    private let lock = NSLock()
    private var stored = 0

    func increment() -> Int {
        lock.lock()
        stored += 1
        let value = stored
        lock.unlock()
        return value
    }

    func value() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
