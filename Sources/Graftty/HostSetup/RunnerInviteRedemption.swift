import Foundation
import GrafttyKit
import GrafttyProtocol
import GrafttyRemoteClient
import GrafttyTailcat

/// Saves a runner added by invite, after the invite was redeemed. The runner
/// is reached over Tailcat only and has no OpenSSH destination, so it is never
/// offered Update Runner or project import.
@MainActor
struct RunnerInviteRedemption {
    let pinnedHostStore: PinnedHostStore
    /// Keychain by default; the endpoint is a secret and never enters the saved host list.
    var saveTailcatEndpoint: (TailcatEndpoint, RemoteIdentityFingerprint) throws -> Void = { endpoint, fingerprint in
        try TailcatCredentials.saveEndpoint(endpoint, for: fingerprint)
    }

    /// Pins the runner key and saves the runner. A runner already saved with
    /// the same key is replaced; a device or key that conflicts is refused.
    func save(identity: LinuxHostIdentity, endpoint: TailcatEndpoint, model: RemoteMacsModel) throws -> RemoteMac {
        try identity.validate()
        guard let bytes = Data(base64Encoded: identity.publicKey) else {
            throw LinuxHostSetupError.invalidPlan("The runner invite has an invalid public key.")
        }
        let key = try RemoteIdentityPublicKey(rawRepresentation: bytes)
        let id = RemoteDeviceID(value: identity.deviceID)
        let fingerprint = RemoteIdentityFingerprint(of: key)
        let pins = try pinnedHostStore.list()
        let saved = model.savedRemoteMacs.filter { $0.id == id }
        guard pins.allSatisfy({ $0.id == id ? $0.publicKey == key : $0.publicKey != key }),
              saved.allSatisfy({ $0.fingerprint == fingerprint }) else {
            throw LinuxHostSetupError.invalidPlan("This runner has a different saved Graftty identity. Remove its old pairing explicitly before adding it again.")
        }
        let existing = pins.first { $0.id == id }
        let host = PinnedHost(id: id, kind: .linux, publicKey: key, displayName: identity.displayName,
                              pinnedAt: existing?.pinnedAt ?? Date(), lastConnectedAt: existing?.lastConnectedAt,
                              pairingURL: existing?.pairingURL ?? URL(string: "tailcat:")!)
        try pinnedHostStore.upsertAfterPairing(host)
        try saveTailcatEndpoint(endpoint, fingerprint)
        // A runner first installed over SSH keeps what Update Runner needs.
        try model.recordPairingResult(.paired(host), transport: .tailcat, directEndpoint: saved.first?.directEndpoint,
                                      maintenanceDestination: saved.first?.maintenanceDestination)
        guard let remote = model.savedRemoteMacs.first(where: { $0.id == id && $0.fingerprint == fingerprint }) else {
            throw LinuxHostSetupError.invalidPlan("Could not save the runner. Add it again.")
        }
        return remote
    }
}
