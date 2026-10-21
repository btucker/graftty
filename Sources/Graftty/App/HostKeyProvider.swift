import CryptoKit
import Foundation

/// Loads the host signing key for `AppServices`. The first call is the
/// launch load; its key, if any, is `launchKey`. Later calls return
/// `launchKey`, or reload from the store when the launch load failed.
@MainActor
final class HostKeyProvider {
    private let load: () throws -> Curve25519.Signing.PrivateKey
    private var didLaunchLoad = false
    private(set) var launchKey: Curve25519.Signing.PrivateKey?

    init(load: @escaping () throws -> Curve25519.Signing.PrivateKey) {
        self.load = load
    }

    func key() throws -> Curve25519.Signing.PrivateKey {
        guard didLaunchLoad else {
            didLaunchLoad = true
            let key = try load()
            launchKey = key
            return key
        }
        return try launchKey ?? load()
    }
}
