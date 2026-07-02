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

        await registry.register(deviceID: device, close: { await spy.close() })
        await registry.deregister(deviceID: device)

        #expect(await registry.count == 0)
        #expect(await spy.closeCount == 0)
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
