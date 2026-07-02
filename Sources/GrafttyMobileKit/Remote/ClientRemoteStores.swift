#if canImport(UIKit)
import Foundation

/// Bundles the three sibling file-backed stores that every client-side
/// remote-pairing entry point (`RemoteConnectionCoordinator`,
/// `PairDeviceFlowView.buildModel`) constructs over the SAME directory:
/// the client's long-lived identity key (`ClientIdentityStore`), its
/// stable device ID (`ClientDeviceIDStore`), and the hosts it has paired
/// with (`PinnedHostStore`). Replaces three parallel one-line
/// constructions that had drifted into two call sites — a mechanical
/// factory, not new behavior.
public struct ClientRemoteStores {
    public let identityStore: ClientIdentityStore
    public let deviceIDStore: ClientDeviceIDStore
    public let pinnedHostStore: PinnedHostStore

    public init(directory: URL) {
        self.identityStore = ClientIdentityStore(directory: directory)
        self.deviceIDStore = ClientDeviceIDStore(directory: directory)
        self.pinnedHostStore = PinnedHostStore(directory: directory)
    }
}
#endif
