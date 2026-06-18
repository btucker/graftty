import Foundation
import GhosttyKit
import Testing
@testable import Graftty
@testable import GrafttyKit

@Suite("HostManagedZmxBackend — Ghostty host-managed adapter", .serialized)
struct HostManagedZmxBackendTests {
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

    @Test("Remote-gated viewport callbacks are withheld; the first user input flushes the last one, then later callbacks pass through (IOS-12.1).")
    func receiveResizeCallbackForwardsGridSizeToStartedSessionOnlyAfterUserInputEngagement() throws {
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(session: session, hasRemoteClient: { true })
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        try backend.start(surface: Self.fakeSurface())
        backend.markLayoutSettled()

        // IOS-12.1: remote attached — pre-engagement viewport callbacks are
        // recorded but not forwarded to the PTY. The PTY dims persist.
        HostManagedZmxBackend.receiveResizeCallback(
            backend.userdataForTesting,
            132,
            43,
            2112,
            1032
        )
        #expect(session.resizes().isEmpty)

        // First user input engages the attach and flushes the last viewport
        // size — the PTY now adopts what libghostty has been measuring.
        try backend.write(Data([0x68]))
        #expect(session.resizes() == [Resize(cols: 132, rows: 43)])

        // Post-engagement viewport callbacks propagate immediately.
        HostManagedZmxBackend.receiveResizeCallback(
            backend.userdataForTesting,
            120,
            40,
            1440,
            960
        )
        #expect(session.resizes() == [Resize(cols: 132, rows: 43), Resize(cols: 120, rows: 40)])
    }

    @Test("`start(surface:)` resets the engagement gate and discards stale pre-start viewport callbacks; nothing leaks to the PTY across attaches (IOS-12.1).")
    func startResetsSilentGateAndDiscardsPreStartViewportCallbacks() throws {
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

        // IOS-12.1: start resets the engagement window. Pre-start viewport
        // measurements are stale w.r.t. the new surface session and are
        // dropped. No resize reaches the PTY without user input.
        #expect(session.resizes().isEmpty)

        // A user input alone does not synthesise a resize — there was no
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

    @Test("@spec IOS-12.1: While a remote client is attached to the zmx session, a fresh attach with a libghostty viewport callback but no user input shall not resize the zmx PTY. This is the Mac mirror of IOS-6.5 — the PTY cols/rows persist until the Mac user engages or the last remote client detaches.")
    func reattachWithoutUserInputDoesNotResizeWhileRemoteAttached() throws {
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(session: session, hasRemoteClient: { true })
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        try backend.start(surface: Self.fakeSurface())
        backend.markLayoutSettled()

        HostManagedZmxBackend.receiveResizeCallback(
            backend.userdataForTesting,
            80, 24, 960, 576
        )

        #expect(session.resizes().isEmpty)
    }

    @Test("First user-input write after a remote-withheld viewport callback flushes the queued size to the PTY as a single resize (IOS-12.1).")
    func userInputFlushesPendingResize() throws {
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
        #expect(session.resizes().isEmpty)

        try backend.write(Data([0x68]))   // 'h'

        #expect(session.resizes() == [Resize(cols: 80, rows: 24)])
    }

    @Test("Once engaged by user input, every subsequent libghostty viewport callback propagates to the PTY as a resize — immediately on the leading edge, or as the coalesced trailing resize (IOS-12.1 / TERM-11.9).")
    func postEngagementResizesArePropagated() throws {
        let session = FakeHostManagedSession()
        let coalescer = ManualResizeCoalescer()
        let backend = Self.makeBackend(session: session, coalescer: coalescer)
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        try backend.start(surface: Self.fakeSurface())
        backend.markLayoutSettled()

        try backend.write(Data([0x68]))   // engagement, no queued resize

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

    @Test("`write(_:claimEngagement: false)` shall not flip attachState to .engaged — used by programmatic callers (extraInitialInput, typeText for splitPane/send-pane/agent nudges) that should not be treated as IOS-12.1 user input.")
    func programmaticWriteDoesNotEngageGate() throws {
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(session: session, hasRemoteClient: { true })
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        try backend.start(surface: Self.fakeSurface())
        backend.markLayoutSettled()

        // Queue a pre-engagement viewport (withheld: remote attached).
        HostManagedZmxBackend.receiveResizeCallback(
            backend.userdataForTesting,
            132, 43, 2112, 1032
        )
        #expect(session.resizes().isEmpty)

        // Programmatic write must NOT engage the gate — the queued resize stays unflushed.
        try backend.write(Data("hello".utf8), claimEngagement: false)
        #expect(session.resizes().isEmpty)
        #expect(session.writes() == [Data("hello".utf8)])

        // Real user input via the keystroke path DOES engage and flush.
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

    @Test("A queued pre-start write with claimEngagement shall engage the gate only once it actually reaches the PTY at start — and a write on a closed backend shall still throw (TERM-11.12 / IOS-12.1).")
    func queuedWriteEngagementDefersToDeliveryAndClosedStillThrows() throws {
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(session: session, hasRemoteClient: { true })
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        backend.bindSurfaceSync(
            currentGridSize: { (cols: 142, rows: 38) },
            requestRefresh: {}
        )

        // Queued user write pre-start: must not engage yet.
        try backend.write(Data([0x68]))
        #expect(session.resizes().isEmpty)

        try backend.start(surface: Self.fakeSurface())
        backend.markLayoutSettled()
        // Remote attached + silent would withhold callbacks — but the
        // queued user write was delivered at start, so the gate is
        // engaged and the engagement flush ships the current grid once
        // layout settles.
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

    // MARK: - TERM-11.x — PTY/grid size sync (conditional IOS-12.1 gate)

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

    @Test("Forwarding a silent-state viewport callback shall not flip the engagement gate — programmatic-input policy still applies until real user input (IOS-12.1).")
    func silentForwardingDoesNotEngageGate() throws {
        let session = FakeHostManagedSession()
        let remoteAttached = LockedFlag(false)
        let backend = Self.makeBackend(
            session: session,
            hasRemoteClient: { remoteAttached.value() }
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

        // A remote client attaches; the still-silent gate must re-engage
        // withholding because engagement never flipped.
        remoteAttached.set(true)
        HostManagedZmxBackend.receiveResizeCallback(
            backend.userdataForTesting,
            100, 30, 1200, 720
        )
        #expect(session.resizes() == [Resize(cols: 132, rows: 43)])
    }

    @Test("@spec TERM-11.3: When the silent gate disengages on first user input, the application shall resize the PTY to the current libghostty grid size and force a surface refresh.")
    func engagementFlushUsesCurrentGridSizeAndRefreshes() throws {
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

        // Remote attached: viewport callbacks are withheld.
        HostManagedZmxBackend.receiveResizeCallback(
            backend.userdataForTesting,
            132, 43, 2112, 1032
        )
        #expect(session.resizes().isEmpty)

        // First user input flushes the CURRENT grid (142x38), not the stale
        // recorded callback (132x43), and forces a refresh.
        try backend.write(Data([0x68]))
        #expect(session.resizes() == [Resize(cols: 142, rows: 38)])
        #expect(refreshes.value() == 1)
    }

    @Test("Engagement flush shall fall back to the last withheld viewport size when no grid size provider is bound (IOS-12.1 compatibility).")
    func engagementFlushFallsBackToLastWithheldSize() throws {
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

    @Test("@spec TERM-11.4: When the last remote client detaches from a session whose pane has not yet been engaged, the application shall resize the PTY to the current libghostty grid size.")
    func lastRemoteDetachSyncsStillSilentPane() throws {
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
        #expect(session.resizes().isEmpty)   // gated: remote attached

        remoteAttached.set(false)
        backend.remoteClientsDidDetach()

        #expect(session.resizes() == [Resize(cols: 142, rows: 38)])
    }

    @Test("remoteClientsDidDetach shall re-check remote presence — if another client re-attached before the observer ran, the PTY shall not be resized.")
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

        backend.remoteClientsDidDetach()   // hasRemoteClient still true
        #expect(session.resizes().isEmpty)
    }

    @Test("remoteClientsDidDetach shall be a no-op once the pane is engaged — engaged panes already forward every viewport callback.")
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

    @Test("While layout has not settled, a silent-state viewport callback shall be withheld even with no remote client attached — protection against the pre-layout libghostty callback that PR 201 fixed.")
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

    @Test("The re-show resync shall be withheld while a still-silent pane has a remote client attached — the Mac must not steal a shared session's width without user engagement (TERM-11.13 / IOS-12.1).")
    func reShowResyncWithheldWhileSilentWithRemoteClient() throws {
        let session = FakeHostManagedSession()
        let remoteAttached = LockedFlag(true)
        let backend = Self.makeBackend(session: session, hasRemoteClient: { remoteAttached.value() })
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        backend.bindSurfaceSync(
            currentGridSize: { (cols: 108, rows: 88) },
            requestRefresh: {}
        )
        try backend.start(surface: Self.fakeSurface())
        backend.markLayoutSettled()   // gated: remote attached, still silent
        #expect(session.resizes().isEmpty)

        backend.resyncVisibleGrid()
        #expect(session.resizes().isEmpty)
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

    @Test("A sync flush (engagement / layout-settle) shall supersede any pending coalesced resize so a stale mid-drag size cannot land after the flush (TERM-11.9).")
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

        // Engagement flush ships the current grid and clears the pending
        // coalesced size — the stale 150x82 must never land afterwards.
        try backend.write(Data([0x68]))
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

    // MARK: - TERM-11.6/11.7/11.8 — pre-layout engagement + opt-in engagement

    @Test("@spec TERM-11.6: When user input engages the silent gate before layout has settled, the application shall defer the engagement PTY sync until layout settles rather than resize the PTY to the pre-layout grid.")
    func preLayoutEngagementDefersFlushUntilLayoutSettles() throws {
        let session = FakeHostManagedSession()
        let settled = LockedFlag(false)
        let backend = Self.makeBackend(session: session)
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        // The grid reports the bogus pre-layout placeholder (49x17) until
        // layout lands, then the real dims — mirroring the trace captured
        // on 2026-06-10 (flush(engagement) -> 49x17 at attach).
        backend.bindSurfaceSync(
            currentGridSize: { settled.value() ? (cols: 194, rows: 74) : (cols: 49, rows: 17) },
            requestRefresh: {}
        )
        try backend.start(surface: Self.fakeSurface())

        HostManagedZmxBackend.receiveResizeCallback(
            backend.userdataForTesting,
            49, 17, 588, 272
        )
        // Engagement before the first real layout (early keystroke).
        try backend.write(Data([0x68]))
        #expect(session.resizes().isEmpty)

        settled.set(true)
        backend.markLayoutSettled()
        #expect(session.resizes() == [Resize(cols: 194, rows: 74)])
    }

    @Test("@spec TERM-11.7: While layout has not settled, the application shall not forward viewport callbacks to the zmx PTY regardless of engagement state.")
    func preLayoutCallbackWithheldEvenWhenEngaged() throws {
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(session: session)
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        try backend.start(surface: Self.fakeSurface())

        try backend.write(Data([0x68]))   // engaged before layout
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

    @Test("@spec TERM-11.8: If libghostty emits PTY-bound bytes outside a user-input scope (terminal query auto-responses, automation), then the application shall not treat them as engaging user input; bytes emitted inside the scope shall engage.")
    func callbackBytesOutsideUserInputScopeDoNotEngage() throws {
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(session: session, hasRemoteClient: { true })
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        backend.bindSurfaceSync(
            currentGridSize: { (cols: 142, rows: 38) },
            requestRefresh: {}
        )
        try backend.start(surface: Self.fakeSurface())
        backend.markLayoutSettled()

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
        // Still silent: the remote-gated viewport callback stays withheld.
        HostManagedZmxBackend.receiveResizeCallback(
            backend.userdataForTesting,
            132, 43, 2112, 1032
        )
        #expect(session.resizes().isEmpty)

        // The same callback inside a user-input scope (a real key dispatch)
        // engages and flushes the current grid.
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
        #expect(session.resizes() == [Resize(cols: 142, rows: 38)])
    }

    private static func makeBackend(
        session: FakeHostManagedSession,
        hasRemoteClient: @escaping () -> Bool = { false },
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
            scheduleCoalescedResize: { delay, fire in effective.schedule(delay, fire) },
            sessionFactory: { _, _, _ in session }
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

    @Test("When two threads race to `write` after a silent-gated viewport callback, the engagement-flush resize shall land at the PTY before the write bytes do — there shall be no interleaving where bytes hit the PTY at the pre-flush dims.")
    func engagementFlushResizeOrdersBeforeConcurrentWriteBytes() throws {
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

        // Thread A enters write first; the engagement flush should serialize
        // the resize ahead of any other thread's write.
        Self.runOnDedicatedThread {
            try? backend.write(Data("a".utf8))
            threadAFinished = true
            barrier.signal()
        }
        // Thread B races in — once A's markUserInput sets attachState=.engaged,
        // B's markUserInput is a no-op so B proceeds to its write.
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
    private var storedWrites: [Data] = []
    private var storedResizes: [Resize] = []
    private var storedStartCount = 0
    private var storedCloseCount = 0
    private var failNextResize = false

    init(startError: Error? = nil, startHook: (() -> Void)? = nil) {
        self.startError = startError
        self.startHook = startHook
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
        if shouldFail { failNextResize = false } else { storedResizes.append(Resize(cols: cols, rows: rows)) }
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
