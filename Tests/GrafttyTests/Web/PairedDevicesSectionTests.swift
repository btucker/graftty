import Foundation
import GrafttyKit
import GrafttyProtocol
import Testing

@testable import Graftty

// MARK: - RemoteDeviceKind.displayLabel

@Suite("RemoteDeviceKind displayLabel Tests")
struct RemoteDeviceKindDisplayLabelTests {

    @Test("maps every kind to its human-readable label", arguments: [
        (RemoteDeviceKind.mac, "Mac"),
        (RemoteDeviceKind.iphone, "iPhone"),
        (RemoteDeviceKind.ipad, "iPad"),
    ])
    func mapsKindToLabel(kind: RemoteDeviceKind, expected: String) {
        #expect(kind.displayLabel == expected)
    }
}

// MARK: - PairedDevicesSection.performRemove

/// Collects the device IDs passed to a spy `revoke` closure. An actor
/// (rather than a plain class) since `performRemove` awaits the closure
/// from an async context and Swift Testing runs `@Test func` bodies
/// concurrently with other tests.
private actor RevokeSpy {
    private(set) var revokedIDs: [RemoteDeviceID] = []
    func revoke(_ id: RemoteDeviceID) {
        revokedIDs.append(id)
    }
}

/// @spec REMOTE-3.3: When a host operator removes a paired device from
/// Settings, the application shall close that device's live session
/// immediately rather than waiting for its next attach attempt to fail,
/// and shall not close any session if the device could not be removed
/// from the trust store.
@Suite("PairedDevicesSection.performRemove Tests")
struct PairedDevicesSectionPerformRemoveTests {

    private static func tempDir() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("graftty-paired-devices-remove-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func makePeer(id: RemoteDeviceID) -> TrustedPeer {
        TrustedPeer(
            id: id,
            kind: .iphone,
            publicKey: try! RemoteIdentityPublicKey(rawRepresentation: Data(repeating: 0xCC, count: 32)),
            displayName: "Ben's iPhone",
            capabilities: .defaultsAfterPairing,
            pairedAt: Date(timeIntervalSince1970: 0),
            lastSeenAt: nil
        )
    }

    @Test("on a successful store removal, revokes the peer's live connection AFTER it leaves the store")
    func revokesAfterSuccessfulRemoval() async throws {
        let store = TrustedPeerStore(directory: Self.tempDir())
        let peerID = RemoteDeviceID(value: "peer-1")
        try store.add(Self.makePeer(id: peerID))
        let spy = RevokeSpy()

        let error = await PairedDevicesSection.performRemove(
            peerID: peerID,
            store: store,
            revoke: { await spy.revoke($0) }
        )

        #expect(error == nil)
        #expect(try store.list().isEmpty)
        let revokedIDs = await spy.revokedIDs
        #expect(revokedIDs == [peerID])
    }

    @Test("when the store fails to remove the peer, does NOT revoke — the peer is still considered paired")
    func doesNotRevokeWhenStoreRemoveFails() async throws {
        let store = TrustedPeerStore(directory: Self.tempDir())
        let peerID = RemoteDeviceID(value: "never-added")
        let spy = RevokeSpy()

        let error = await PairedDevicesSection.performRemove(
            peerID: peerID,
            store: store,
            revoke: { await spy.revoke($0) }
        )

        #expect(error != nil)
        let revokedIDs = await spy.revokedIDs
        #expect(revokedIDs.isEmpty)
    }
}
