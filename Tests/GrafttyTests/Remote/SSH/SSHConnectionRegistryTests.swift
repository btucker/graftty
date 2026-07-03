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
    @spec REMOTE-3.2: When a stale connection's fire-and-forget deregister \
    arrives after a reconnect for the same peer has already replaced it with \
    a fresh registration, the application shall ignore the stale deregister \
    rather than removing the newer connection's live closer.
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
