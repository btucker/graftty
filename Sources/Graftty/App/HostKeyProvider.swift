import CryptoKit
import Foundation

/// Loads the host signing key for `AppServices` and retains the first
/// key that loads. Retries the loader while every earlier load has failed,
/// so a key recovered by a later call (the Bonjour fingerprint during
/// init, or startup's host pool) is the one every later caller uses.
@MainActor
final class HostKeyProvider {
    private let load: () throws -> Curve25519.Signing.PrivateKey
    private var retained: Curve25519.Signing.PrivateKey?

    init(load: @escaping () throws -> Curve25519.Signing.PrivateKey) {
        self.load = load
    }

    func key() throws -> Curve25519.Signing.PrivateKey {
        if let retained { return retained }
        let key = try load()
        retained = key
        return key
    }
}
