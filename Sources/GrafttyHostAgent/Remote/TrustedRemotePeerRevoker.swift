import Foundation
import GrafttyKit
import GrafttyProtocol

/// Host-side revocation coordinator. `TrustedPeerStore` is intentionally
/// platform-neutral persistence; live transport teardown belongs next to the
/// host runtime that owns `ActiveRemotePeerRegistry`.
public struct TrustedRemotePeerRevoker: Sendable {
    private let store: TrustedPeerStore
    private let activeRemotePeers: ActiveRemotePeerRegistry

    public init(
        store: TrustedPeerStore,
        activeRemotePeers: ActiveRemotePeerRegistry
    ) {
        self.store = store
        self.activeRemotePeers = activeRemotePeers
    }

    public func revoke(peerID: RemoteDeviceID) async throws {
        guard let peer = try store.get(id: peerID) else {
            throw TrustedPeerStore.Error.notFound
        }
        try store.remove(id: peerID)
        await activeRemotePeers.close(peerID: peer.id, fingerprint: peer.fingerprint)
    }
}
