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

    @Test("Pre-layout viewport callbacks are withheld; the first user input flushes the last one, then later callbacks pass through (IOS-12.1).")
    func receiveResizeCallbackForwardsGridSizeToStartedSessionOnlyAfterUserInputEngagement() throws {
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(session: session)
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        try backend.start(surface: Self.fakeSurface())

        // IOS-12.1: pre-engagement viewport callbacks are recorded but not
        // forwarded to the PTY. The pre-existing PTY dims persist.
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

    @Test("First user-input write after a withheld viewport callback flushes the queued size to the PTY as a single resize (IOS-12.1).")
    func userInputFlushesPendingResize() throws {
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(session: session)
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        try backend.start(surface: Self.fakeSurface())

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

    @Test("Once engaged by user input, every subsequent libghostty viewport callback propagates to the PTY as a resize (IOS-12.1).")
    func postEngagementResizesArePropagated() throws {
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(session: session)
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        try backend.start(surface: Self.fakeSurface())

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
        let backend = Self.makeBackend(session: session)
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        try backend.start(surface: Self.fakeSurface())

        // Queue a pre-engagement viewport.
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

    @Test("If `write` fails (e.g., backend is in `.idle` and `activeSession()` throws .notStarted), attachState shall remain `.silent` — the engagement gate flips only on writes that actually reached the PTY.")
    func failedWriteDoesNotEngageGate() throws {
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(session: session)
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        // Note: no start() — backend is in .idle.

        HostManagedZmxBackend.receiveResizeCallback(
            backend.userdataForTesting,
            132, 43, 2112, 1032
        )

        #expect(throws: HostManagedZmxBackend.Error.notStarted) {
            try backend.write(Data("h".utf8))
        }

        // Start the backend now and engage with a real keystroke.
        try backend.start(surface: Self.fakeSurface())
        // The pre-start callback was wiped by start() per IOS-12.1.
        // A fresh post-start callback shall trigger the flush.
        HostManagedZmxBackend.receiveResizeCallback(
            backend.userdataForTesting,
            80, 24, 960, 576
        )
        try backend.write(Data([0x68]))
        #expect(session.resizes() == [Resize(cols: 80, rows: 24)])
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

    private static func makeBackend(
        session: FakeHostManagedSession,
        hasRemoteClient: @escaping () -> Bool = { false }
    ) -> HostManagedZmxBackend {
        HostManagedZmxBackend(
            spawnConfiguration: spawnConfiguration(),
            hasRemoteClient: hasRemoteClient,
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
        let backend = Self.makeBackend(session: session)
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        try backend.start(surface: Self.fakeSurface())

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

private final class FakeHostManagedSession: HostManagedZmxSession {
    private let lock = NSLock()
    private let startError: Error?
    private let startHook: (() -> Void)?
    private var storedWrites: [Data] = []
    private var storedResizes: [Resize] = []
    private var storedStartCount = 0
    private var storedCloseCount = 0

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
        storedResizes.append(Resize(cols: cols, rows: rows))
        lock.unlock()
    }

    func close() {
        lock.lock()
        storedCloseCount += 1
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
