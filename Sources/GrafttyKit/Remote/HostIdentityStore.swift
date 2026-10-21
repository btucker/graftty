import Foundation
import GrafttyProtocol

// MARK: - HostIdentityStore

/// @spec REMOTE-1.1
/// Persists the host's long-lived Ed25519 identity keypair in
/// `host-identity.json`; see `RemoteIdentityKeyStore` for the format.
public typealias HostIdentityStore = RemoteIdentityKeyStore<HostIdentityFile>

public enum HostIdentityFile: RemoteIdentityFileLocation {
    public static let fileName = "host-identity.json"

    // TODO: Keychain integration before v1 production release —
    // the private key should be stored in the Keychain/Secure Enclave
    // rather than Application Support. This file-backed path is used
    // until that integration lands.
    public static var defaultDirectory: URL {
        AppState.defaultDirectory
            .appendingPathComponent("Remote")
    }
}
