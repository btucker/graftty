import Foundation

/// The public identity sent over an already authenticated OpenSSH connection.
/// This wire format deliberately has no private key or credential fields.
public struct LinuxHostTrustRequest: Codable, Sendable, Equatable {
    public let deviceID: String
    public let displayName: String
    public let publicKey: String

    public init(deviceID: String, displayName: String, publicKey: String) {
        self.deviceID = deviceID
        self.displayName = displayName
        self.publicKey = publicKey
    }

    public func validate() throws {
        guard !deviceID.isEmpty, !displayName.isEmpty,
              Data(base64Encoded: publicKey)?.count == 32 else {
            throw LinuxHostIdentityError.invalidIdentity("The Mac's Graftty public identity is missing or invalid.")
        }
    }
}

/// The Linux runtime's public identity, returned over authenticated OpenSSH.
public struct LinuxHostIdentity: Codable, Sendable, Equatable {
    public let deviceID: String
    public let displayName: String
    public let publicKey: String
    /// Graftty's direct SSH listener, distinct from the OpenSSH bootstrap port.
    public let port: Int

    public init(deviceID: String, displayName: String, publicKey: String, port: Int) {
        self.deviceID = deviceID
        self.displayName = displayName
        self.publicKey = publicKey
        self.port = port
    }

    public func validate() throws {
        guard !deviceID.isEmpty, !displayName.isEmpty,
              Data(base64Encoded: publicKey)?.count == 32, (1...65535).contains(port) else {
            throw LinuxHostIdentityError.invalidIdentity("The Linux host returned an invalid Graftty identity or port.")
        }
    }
}

public enum LinuxHostIdentityError: Error, LocalizedError, Sendable, Equatable {
    case invalidIdentity(String)
    public var errorDescription: String? {
        switch self { case .invalidIdentity(let message): return message }
    }
}
