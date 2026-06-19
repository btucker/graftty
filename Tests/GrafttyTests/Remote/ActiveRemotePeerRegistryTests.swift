import CryptoKit
import GrafttyHostAgent
import GrafttyProtocol
import XCTest

final class ActiveRemotePeerRegistryTests: XCTestCase {
    func testClosePeerClosesOnlyMatchingEntriesAndUnregistersIdempotently() async throws {
        let registry = ActiveRemotePeerRegistry()
        let recorder = CloseRecorder()
        let peerA = RemoteDeviceID(value: "peer-a")
        let peerB = RemoteDeviceID(value: "peer-b")
        let fingerprintA = makeFingerprint()
        let fingerprintB = makeFingerprint()

        _ = registry.register(peerID: peerA, fingerprint: fingerprintA) {
            await recorder.record("a1")
        }
        _ = registry.register(peerID: peerA, fingerprint: fingerprintA) {
            await recorder.record("a2")
        }
        _ = registry.register(peerID: peerB, fingerprint: fingerprintB) {
            await recorder.record("b1")
        }

        await registry.close(peerID: peerA)
        await registry.close(peerID: peerA)

        let values = await recorder.values
        XCTAssertEqual(values.sorted(), ["a1", "a2"])
        XCTAssertTrue(registry.entries(peerID: peerA).isEmpty)
        XCTAssertEqual(registry.entries(peerID: peerB).count, 1)
    }

    func testClosePeerFingerprintClosesOnlyMatchingIdentity() async throws {
        let registry = ActiveRemotePeerRegistry()
        let recorder = CloseRecorder()
        let peerID = RemoteDeviceID(value: "same-device-id")
        let oldFingerprint = makeFingerprint()
        let newFingerprint = makeFingerprint()

        _ = registry.register(peerID: peerID, fingerprint: oldFingerprint) {
            await recorder.record("old")
        }
        _ = registry.register(peerID: peerID, fingerprint: newFingerprint) {
            await recorder.record("new")
        }

        await registry.close(peerID: peerID, fingerprint: newFingerprint)

        let values = await recorder.values
        XCTAssertEqual(values, ["new"])
        XCTAssertEqual(registry.entries(peerID: peerID).map(\.fingerprint), [oldFingerprint])
    }

    func testUnregisterIsIdempotent() async throws {
        let registry = ActiveRemotePeerRegistry()
        let peerID = RemoteDeviceID(value: "peer")
        let fingerprint = makeFingerprint()
        let entryID = registry.register(peerID: peerID, fingerprint: fingerprint) {}

        registry.unregister(entryID: entryID)
        registry.unregister(entryID: entryID)

        await registry.closeAll()
        XCTAssertTrue(registry.entries(peerID: peerID).isEmpty)
    }

    private func makeFingerprint() -> RemoteIdentityFingerprint {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = try! RemoteIdentityPublicKey(rawRepresentation: key.publicKey.rawRepresentation)
        return RemoteIdentityFingerprint(of: publicKey)
    }
}

private actor CloseRecorder {
    private var recorded: [String] = []

    func record(_ value: String) {
        recorded.append(value)
    }

    var values: [String] {
        recorded
    }
}
