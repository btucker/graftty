import Foundation
import GrafttyKit
import GrafttyProtocol
import GrafttyRemoteClient

struct LinuxHostPreparedConnection {
    let host: PinnedHost
    let hostname: String
    let port: Int
}

@MainActor
struct LinuxHostSetupConnectionController {
    let pinnedHostStore: PinnedHostStore

    func save(_ result: LinuxHostSetupResult, model: RemoteMacsModel) throws -> RemoteMac {
        let endpoint = try DirectSSHEndpoint(host: result.openSSH.hostname, port: result.identity.port)
        let known = model.savedRemoteMacs.filter {
            $0.id.value == result.identity.deviceID
                || ($0.transport == .directSSH && $0.directEndpoint?.host.lowercased() == endpoint.host.lowercased() && $0.directEndpoint?.port == endpoint.port)
        }.map(RemoteMacIdentity.init)
        let prepared = try accept(result, kind: .linux, knownRemotes: known)
        try model.recordPairingResult(.paired(prepared.host), transport: .directSSH, directEndpoint: endpoint)
        guard let saved = model.savedRemoteMacs.first(where: {
            $0.id == prepared.host.id && $0.fingerprint == prepared.host.fingerprint
        }) else { throw LinuxHostSetupError.invalidPlan("Could not save the Linux host. Retry setup.") }
        return saved
    }

    /// `knownRemotes` contains saved identities with either this device ID or
    /// this direct endpoint. Check it even if the separate pin file is missing.
    func accept(_ result: LinuxHostSetupResult, kind: RemoteDeviceKind, knownRemotes: [RemoteMacIdentity]) throws -> LinuxHostPreparedConnection {
        try result.identity.validate()
        let endpoint = try DirectSSHEndpoint(host: result.openSSH.hostname, port: result.identity.port)
        let id = RemoteDeviceID(value: result.identity.deviceID)
        guard let bytes = Data(base64Encoded: result.identity.publicKey) else {
            throw LinuxHostSetupError.invalidPlan("The Linux host returned an invalid public key.")
        }
        let key = try RemoteIdentityPublicKey(rawRepresentation: bytes)
        let identity = RemoteMacIdentity(id: id, fingerprint: .init(of: key))
        let pins = try pinnedHostStore.list()
        let endpointPins = pins.filter {
            $0.id == id || ($0.pairingURL.scheme == "ssh"
                && $0.pairingURL.host?.lowercased() == endpoint.host.lowercased()
                && $0.pairingURL.port == result.identity.port)
        }
        guard knownRemotes.allSatisfy({ $0 == identity }),
              endpointPins.allSatisfy({ $0.id == id && $0.publicKey == key }),
              !pins.contains(where: { $0.id != id && $0.publicKey == key }) else {
            throw LinuxHostSetupError.invalidPlan("This Linux device or SSH endpoint has a different saved Graftty identity. Verify the host's identity and remove its old pairing explicitly before setting it up again.")
        }
        var url = URLComponents()
        url.scheme = "ssh"
        url.host = endpoint.host
        url.port = result.identity.port
        guard let pairingURL = url.url else {
            throw LinuxHostSetupError.invalidPlan("The resolved SSH hostname cannot be used as a direct Graftty endpoint.")
        }
        let existing = pins.first { $0.id == id }
        let host = PinnedHost(
            id: id, kind: kind, publicKey: key, displayName: result.identity.displayName,
            pinnedAt: existing?.pinnedAt ?? Date(), lastConnectedAt: existing?.lastConnectedAt,
            pairingURL: pairingURL
        )
        // This synchronous MainActor operation checks trust before upserting.
        // The normal verification-code ceremony's replacement behavior is never
        // used to approve a changed bootstrap identity implicitly.
        try pinnedHostStore.upsertAfterPairing(host)
        return LinuxHostPreparedConnection(host: host, hostname: endpoint.host, port: endpoint.port)
    }
}
