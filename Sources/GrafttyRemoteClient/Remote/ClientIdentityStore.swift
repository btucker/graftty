import Foundation
import GrafttyProtocol

// MARK: - ClientIdentityStore

/// Persists the client's long-lived Ed25519 identity keypair in
/// `client-identity.json`; see `RemoteIdentityKeyStore` for the format.
public typealias ClientIdentityStore = RemoteIdentityKeyStore<ClientIdentityFile>

public enum ClientIdentityFile: RemoteIdentityFileLocation {
    public static let fileName = "client-identity.json"

    // TODO: Keychain integration before v1 production release —
    // the private key should be stored in the Keychain/Secure Enclave
    // rather than Application Support. This file-backed path is used
    // until that integration lands.
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Graftty")
            .appendingPathComponent("Remote")
    }
}
