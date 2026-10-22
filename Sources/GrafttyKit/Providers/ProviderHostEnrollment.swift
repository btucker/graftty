import Foundation
import GrafttyProtocol

/// Public information exchanged over an already authenticated provider channel.
public struct ProviderHostEnrollmentRequest: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let parent: LinuxHostTrustRequest
    public init(operationID: UUID, parent: LinuxHostTrustRequest) { self.operationID = operationID; self.parent = parent }
}

public struct ProviderHostEnrollmentResponse: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let parent: LinuxHostTrustRequest
    public let identity: LinuxHostIdentity
    public init(operationID: UUID, parent: LinuxHostTrustRequest, identity: LinuxHostIdentity) {
        self.operationID = operationID; self.parent = parent; self.identity = identity
    }
}

/// Only called from a trusted local administration command, never a network callback.
public enum ProviderHostEnrollment {
    public static func accept(_ request: ProviderHostEnrollmentRequest, configuration: HostConfiguration) throws -> ProviderHostEnrollmentResponse {
        try validate(request.parent)
        try configuration.prepareDirectories()
        let directory = configuration.identityDirectory.appendingPathComponent("ProviderEnrollment", isDirectory: true)
        let lease = try ExclusiveFileLock(url: directory.appendingPathComponent("enrollment.lock"), wait: false)
        defer { withExtendedLifetime(lease) {} }
        let file = JSONFileStore<ProviderHostEnrollmentResponse>(
            fileURL: directory.appendingPathComponent(request.operationID.uuidString + ".json"), posixPermissions: 0o600)
        // Setup creates the identity as the development user. Do not regenerate
        // a missing or corrupt private key during an enrollment retry.
        guard try HostIdentityStore(directory: configuration.identityDirectory).load() != nil else {
            throw ProviderError("Run graftty-host setup as the development user before provider enrollment.")
        }
        let identity = try HostSetup.identity(configuration: configuration)
        try identity.validate()
        let response = ProviderHostEnrollmentResponse(operationID: request.operationID, parent: request.parent, identity: identity)
        let peers = TrustedPeerStore(directory: configuration.identityDirectory)
        if let previous = try file.load() {
            guard previous == response else { throw ProviderError("Enrollment identity changed; verify and explicitly enroll again.") }
            guard let peer = try peers.get(id: .init(value: request.parent.deviceID)),
                  peer.publicKey.rawRepresentation.base64EncodedString() == request.parent.publicKey, peer.capabilities.terminalControl == .allowed else {
                throw ProviderError("Parent trust was removed or disabled; enrollment retry cannot restore it.")
            }
            return previous
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        guard files.count < 10000 else { throw ProviderError("Provider enrollment history is full.") }
        for url in files {
            guard let previous = try JSONFileStore<ProviderHostEnrollmentResponse>(fileURL: url).load() else {
                throw ProviderError("Invalid provider enrollment history.")
            }
            if previous.parent.deviceID == request.parent.deviceID {
                guard previous.parent.publicKey == request.parent.publicKey,
                      previous.parent.serverPublicKey == request.parent.serverPublicKey else {
                    throw ProviderError("The parent's enrolled client or server identity changed. Verify and explicitly remove the old binding before enrolling its replacement.")
                }
            }
        }
        // Persist before authorizing. A crash in between leaves an incomplete
        // operation that fails closed instead of restoring a later revocation.
        try file.save(response)
        let key = try RemoteIdentityPublicKey(rawRepresentation: Data(base64Encoded: request.parent.publicKey)!)
        try peers.enrollWithoutReplacingIdentity(.init(id: .init(value: request.parent.deviceID), kind: .mac, publicKey: key,
            displayName: request.parent.displayName, capabilities: .init(terminalControl: .allowed, portTunnel: .disabled,
            screenView: .disabled, screenControl: .disabled, worktreeManagement: .allowed), pairedAt: Date(), lastSeenAt: nil))
        guard try peers.get(id: .init(value: request.parent.deviceID))?.capabilities.terminalControl == .allowed else {
            throw ProviderError("Parent control is disabled; enrollment cannot restore it.")
        }
        return response
    }

    static func validate(_ parent: LinuxHostTrustRequest) throws {
        try parent.validate()
        guard validDeviceID(parent.deviceID), validLabel(parent.displayName),
              Data(base64Encoded: parent.publicKey)?.base64EncodedString() == parent.publicKey,
              let serverKey = parent.serverPublicKey, Data(base64Encoded: serverKey)?.count == 32,
              Data(base64Encoded: serverKey)?.base64EncodedString() == serverKey else {
            throw ProviderError("Invalid public parent identity.")
        }
    }

    static func validDeviceID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 58, 95].contains($0)
        }
    }

    static func validLabel(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}
