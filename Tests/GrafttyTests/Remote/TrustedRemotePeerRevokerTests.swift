import CryptoKit
import Foundation
import GrafttyHostAgent
import GrafttyKit
import GrafttyProtocol
import XCTest

final class TrustedRemotePeerRevokerTests: XCTestCase {
    func testRevokeRemovesTrustedPeerAndClosesMatchingActiveSessions() async throws {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = TrustedPeerStore(directory: dir)
        let registry = ActiveRemotePeerRegistry()
        let recorder = RevokerCloseRecorder()
        let peer = try makePeer(id: RemoteDeviceID(value: "studio"))
        let rotatedFingerprint = makeFingerprint()
        try store.add(peer)

        _ = registry.register(peerID: peer.id, fingerprint: peer.fingerprint) {
            await recorder.record("trusted")
        }
        _ = registry.register(peerID: peer.id, fingerprint: rotatedFingerprint) {
            await recorder.record("rotated")
        }

        let revoker = TrustedRemotePeerRevoker(store: store, activeRemotePeers: registry)
        try await revoker.revoke(peerID: peer.id)

        let recordedCloses = await recorder.values
        XCTAssertNil(try store.get(id: peer.id))
        XCTAssertEqual(recordedCloses, ["trusted"])
        XCTAssertEqual(registry.entries(peerID: peer.id).map(\.fingerprint), [rotatedFingerprint])
    }

    private func makePeer(id: RemoteDeviceID) throws -> TrustedPeer {
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = try RemoteIdentityPublicKey(rawRepresentation: privateKey.publicKey.rawRepresentation)
        return TrustedPeer(
            id: id,
            kind: .mac,
            publicKey: publicKey,
            displayName: "Studio",
            capabilities: .defaultsAfterPairing,
            pairedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastSeenAt: nil
        )
    }

    private func makeFingerprint() -> RemoteIdentityFingerprint {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = try! RemoteIdentityPublicKey(rawRepresentation: key.publicKey.rawRepresentation)
        return RemoteIdentityFingerprint(of: publicKey)
    }
}

private actor RevokerCloseRecorder {
    private var recorded: [String] = []

    func record(_ value: String) {
        recorded.append(value)
    }

    var values: [String] {
        recorded
    }
}
