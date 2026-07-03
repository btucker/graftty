import Testing
@testable import GrafttyHostAgent
import GrafttyProtocol

/// Records close-closure invocations without touching any WebRTC/NIOSSH
/// types — pure spy for `SSHConnectionRegistry`'s actor logic.
private actor CloseSpy {
    private(set) var closeCount = 0

    func close() {
        closeCount += 1
    }
}

/// Lets a test suspend a closure at a precise point and resume it later,
/// with a companion signal (`waitUntilArrived`) so the test can block until
/// the closure has actually reached the gate before proceeding — avoiding
/// a `Task.yield()`-based race to synchronize the interleaving under test.
private actor Gate {
    private var isOpen = false
    private var openWaiters: [CheckedContinuation<Void, Never>] = []
    private var hasArrived = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

    /// Called from inside the closure under test. Signals arrival, then
    /// suspends until `open()` is called (or returns immediately if
    /// `open()` already ran).
    func wait() async {
        hasArrived = true
        let toResume = arrivalWaiters
        arrivalWaiters = []
        for waiter in toResume { waiter.resume() }

        if isOpen { return }
        await withCheckedContinuation { continuation in
            openWaiters.append(continuation)
        }
    }

    /// Called from the test. Blocks until some Task has called `wait()`
    /// and is parked on the gate (or already arrived).
    func waitUntilArrived() async {
        if hasArrived { return }
        await withCheckedContinuation { continuation in
            arrivalWaiters.append(continuation)
        }
    }

    /// Releases every Task currently parked in `wait()`, and any that
    /// call it afterward return immediately.
    func open() {
        isOpen = true
        let toResume = openWaiters
        openWaiters = []
        for waiter in toResume { waiter.resume() }
    }
}

@Suite("SSHConnectionRegistry tracks peer-keyed closable SSH connections")
struct SSHConnectionRegistryTests {

    @Test func revokeInvokesCloseAndRemoves() async {
        let registry = SSHConnectionRegistry()
        let device = RemoteDeviceID.generate()
        let spy = CloseSpy()

        await registry.register(deviceID: device, close: { await spy.close() })
        #expect(await registry.count == 1)

        await registry.revoke(deviceID: device)
        #expect(await spy.closeCount == 1)
        #expect(await registry.count == 0)
    }

    @Test func revokeOfUnregisteredIDIsNoOp() async {
        let registry = SSHConnectionRegistry()
        let device = RemoteDeviceID.generate()

        await registry.revoke(deviceID: device)
        #expect(await registry.count == 0)
    }

    @Test func reregisteringSameDeviceClosesPriorConnection() async {
        let registry = SSHConnectionRegistry()
        let device = RemoteDeviceID.generate()
        let firstSpy = CloseSpy()
        let secondSpy = CloseSpy()

        await registry.register(deviceID: device, close: { await firstSpy.close() })
        await registry.register(deviceID: device, close: { await secondSpy.close() })

        #expect(await firstSpy.closeCount == 1)
        #expect(await secondSpy.closeCount == 0)
        #expect(await registry.count == 1)
    }

    @Test func deregisterRemovesWithoutClosing() async {
        let registry = SSHConnectionRegistry()
        let device = RemoteDeviceID.generate()
        let spy = CloseSpy()

        let token = await registry.register(deviceID: device, close: { await spy.close() })
        await registry.deregister(deviceID: device, token: token)

        #expect(await registry.count == 0)
        #expect(await spy.closeCount == 0)
    }

    /// Reproduces the W4 review finding empirically: `WebRTCHostAgent.close()`
    /// spawns `Task { await registry.deregister(deviceID:) }` fire-and-forget.
    /// On reconnect, connection B's `register(P, closeB)` self-heals by
    /// closing A first (A's own `close()` ALSO queues a deregister-P Task),
    /// then installs closeB. A's now-orphaned deregister Task can run at
    /// any point afterward and, with an identity-blind `deregister(deviceID:)`,
    /// would blind-remove P — wiping B's fresh registration out from under
    /// it before any admin `revoke(P)` ever runs. Scoping `deregister` to
    /// the token it was handed at registration time is what makes A's late
    /// call a no-op instead.
    @Test("""
    @spec REMOTE-3.2: When a superseded SSH connection's teardown completes \
    after a newer connection for the same peer has already registered, the \
    host shall not remove the newer registration.
    """)
    func staleDeregisterAfterReconnectDoesNotWipeNewRegistration() async {
        let registry = SSHConnectionRegistry()
        let device = RemoteDeviceID.generate()
        let spyA = CloseSpy()
        let spyB = CloseSpy()

        // Connection A registers first.
        let tokenA = await registry.register(deviceID: device, close: { await spyA.close() })

        // Connection B reconnects for the SAME peer — self-heals by
        // closing A (via `previous.close()` inside `register`) before
        // installing its own closer under a fresh token.
        let tokenB = await registry.register(deviceID: device, close: { await spyB.close() })
        #expect(await spyA.closeCount == 1)

        // A's own `close()` had already spawned `deregister(id, tokenA)`
        // as a fire-and-forget Task BEFORE the replace above ran (or
        // concurrently with it) — simulate that late arrival landing
        // now, after B is already installed.
        await registry.deregister(deviceID: device, token: tokenA)

        // B's registration must survive: the stale token from A doesn't
        // match what's currently stored (B's token), so the deregister
        // is a no-op.
        #expect(await registry.count == 1)
        #expect(await spyB.closeCount == 0)

        // And a subsequent revoke must close B (the CURRENT connection),
        // not silently no-op because A's registration already vanished.
        await registry.revoke(deviceID: device)
        #expect(await spyB.closeCount == 1)
        #expect(await spyA.closeCount == 1)
        #expect(await registry.count == 0)

        _ = tokenB // token B itself is never passed to deregister in this
        // scenario — B's own close() hasn't run — but keeping it bound
        // documents that it's the value now stored inside the registry.
    }

    /// Reproduces the register-reentrancy TOCTOU (W4 review finding 1),
    /// empirically confirmed 4/4 against the pre-fix ordering: `register`
    /// used to read the OLD entry, `await` its close, and only THEN write
    /// the new entry. A `revoke` landing during that `await` would remove
    /// the OLD entry (the only one present at that point) and close it —
    /// then the in-flight `register` call would resume and unconditionally
    /// write the new entry anyway, resurrecting a device an admin just
    /// revoked, with a close callback that would never fire again.
    ///
    /// `Gate` pins the interleaving deterministically: connection A's close
    /// closure parks on `gate.wait()`, so `register`'s `await previous
    /// .close()` (replacing A with B) is suspended exactly at the point
    /// under test. `waitUntilArrived()` blocks the test until that
    /// suspension has actually happened — no `Task.yield()` guessing —
    /// before `revoke` is issued and the gate is opened to let A's close
    /// (and therefore B's registration) finish.
    @Test("""
    @spec REMOTE-3.4: When a revoke for a device lands while `register` is \
    still awaiting the prior connection's teardown for that same device, \
    the application shall not resurrect the device with the new registration.
    """)
    func revokeDuringRegisterReplaceAwaitDoesNotResurrectDevice() async {
        let registry = SSHConnectionRegistry()
        let device = RemoteDeviceID.generate()
        let spyA = CloseSpy()
        let spyB = CloseSpy()
        let gate = Gate()

        // Connection A registers first, with a close closure gated so we
        // can suspend register(B)'s replace-await at will.
        _ = await registry.register(deviceID: device, close: {
            await gate.wait()
            await spyA.close()
        })

        // Connection B starts replacing A. This call's `await previous
        // .close()` is A's gated closure above, so it parks on the gate
        // until we open it below.
        let registerB = Task {
            await registry.register(deviceID: device, close: { await spyB.close() })
        }

        // Block until register(B) has actually reached the suspension
        // point inside A's close closure — deterministic, no sleep/yield.
        await gate.waitUntilArrived()

        // An admin revoke lands for the SAME device while register(B) is
        // suspended mid-replace. Spawned rather than awaited inline: under
        // the PRE-FIX ordering, `entries[deviceID]` still holds A at this
        // point (register(B) hasn't written B yet), so `revoke` removes A
        // and re-invokes A's (still-gated) close closure — which would
        // itself park on `gate` a second time. Awaiting `revoke` inline
        // here would deadlock (nothing left to call `gate.open()`). `open()`
        // is a persistent latch, so calling it right after — regardless of
        // whether `revokeTask`'s own call into the gate has landed yet —
        // is safe either way and lets every current or future parked
        // caller through.
        let revokeTask = Task { await registry.revoke(deviceID: device) }

        // Pin the interleaving precisely: `revoke`'s synchronous removal
        // (`entries.removeValue`, before its own `await entry.close()`)
        // must have already run before we open the gate — otherwise, on a
        // fast scheduler, register(B)'s resume-and-write could race ahead
        // of revoke's read and this test would flakily pass for the wrong
        // reason. Polling `count` (rather than sleeping) blocks exactly
        // until that removal has happened: it drops to 0 the instant
        // `revoke` reaches its own suspension point, whether it read A
        // (pre-fix) or B (post-fix).
        while await registry.count != 0 {
            await Task.yield()
        }

        // Let A's gated close complete so register(B) (and, under the
        // pre-fix ordering, revoke's re-entrant close of A) can finish.
        await gate.open()
        _ = await registerB.value
        await revokeTask.value

        // The device must stay revoked — B's registration, installed
        // synchronously before the await (the fix), was the one `revoke`
        // saw and closed; `register(B)` must not write anything further
        // once it resumes.
        #expect(await registry.count == 0, "revoke during register's replace-await must not be resurrected")
        #expect(await spyA.closeCount == 1, "A must still be closed exactly once by the replace")
        #expect(await spyB.closeCount == 1, "B must be closed by the revoke that landed mid-replace, not orphaned")

        // A subsequent register for the same device must be a completely
        // fresh registration (proves the device is truly gone, not just
        // reporting count == 0 while some dangling entry still exists).
        let spyC = CloseSpy()
        await registry.register(deviceID: device, close: { await spyC.close() })
        #expect(await registry.count == 1)
        #expect(await spyC.closeCount == 0)
    }

    /// Complements the gated interleaving test above with plain concurrent
    /// pressure: N concurrent `register` calls for the SAME device must
    /// leave exactly one survivor, and every superseded registration's
    /// close callback must fire exactly once (never zero — orphaned — and
    /// never more than once — double-close).
    @Test func concurrentRegistersForSameDeviceEachSupersededExactlyOnceWithOneSurvivor() async {
        let registry = SSHConnectionRegistry()
        let device = RemoteDeviceID.generate()
        let spies = (0..<8).map { _ in CloseSpy() }

        await withTaskGroup(of: Void.self) { group in
            for spy in spies {
                group.addTask {
                    await registry.register(deviceID: device, close: { await spy.close() })
                }
            }
        }

        var closeCounts: [Int] = []
        for spy in spies {
            closeCounts.append(await spy.closeCount)
        }

        #expect(await registry.count == 1, "exactly one registration should remain current")
        #expect(closeCounts.filter { $0 == 0 }.count == 1, "exactly one registration should survive unclosed")
        #expect(closeCounts.allSatisfy { $0 <= 1 }, "no registration's close callback should run more than once")
    }

    @Test func concurrentRevokesCloseAtMostOnce() async {
        let registry = SSHConnectionRegistry()
        let device = RemoteDeviceID.generate()
        let spy = CloseSpy()

        await registry.register(deviceID: device, close: { await spy.close() })

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask { await registry.revoke(deviceID: device) }
            }
        }

        #expect(await spy.closeCount == 1)
        #expect(await registry.count == 0)
    }
}
