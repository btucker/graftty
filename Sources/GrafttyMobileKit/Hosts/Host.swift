#if canImport(UIKit)
import Foundation

public struct SSHHostConfig: Codable, Sendable, Hashable {
    public var sshHost: String
    public var sshPort: Int
    public var sshUsername: String
    public var remoteGrafttyHost: String
    public var remoteGrafttyPort: Int

    public init(
        sshHost: String,
        sshPort: Int = 22,
        sshUsername: String,
        remoteGrafttyHost: String = "127.0.0.1",
        remoteGrafttyPort: Int = 8799
    ) {
        self.sshHost = sshHost
        self.sshPort = sshPort
        self.sshUsername = sshUsername
        self.remoteGrafttyHost = remoteGrafttyHost
        self.remoteGrafttyPort = remoteGrafttyPort
    }
}

public enum HostTransport: Codable, Sendable, Hashable {
    case directHTTP(baseURL: URL)
    case sshTunnel(SSHHostConfig)
}

/// A saved Graftty server the user has onboarded via QR or manual entry.
public struct Host: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var label: String
    public var transport: HostTransport
    public var addedAt: Date
    public var lastUsedAt: Date?

    public var baseURL: URL {
        switch transport {
        case .directHTTP(let baseURL):
            return baseURL
        case .sshTunnel(let config):
            return URL(string: "http://\(config.remoteGrafttyHost):\(config.remoteGrafttyPort)/")!
        }
    }

    public var displayAddress: String {
        switch transport {
        case .directHTTP(let baseURL):
            return baseURL.absoluteString
        case .sshTunnel(let config):
            return "\(config.sshUsername)@\(config.sshHost):\(config.sshPort)"
        }
    }

    public init(
        id: UUID = UUID(),
        label: String,
        baseURL: URL,
        addedAt: Date = Date(),
        lastUsedAt: Date? = nil
    ) {
        self.init(
            id: id,
            label: label,
            transport: .directHTTP(baseURL: baseURL),
            addedAt: addedAt,
            lastUsedAt: lastUsedAt
        )
    }

    public init(
        id: UUID = UUID(),
        label: String,
        transport: HostTransport,
        addedAt: Date = Date(),
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.label = label
        self.transport = transport
        self.addedAt = addedAt
        self.lastUsedAt = lastUsedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case label
        case baseURL
        case transport
        case addedAt
        case lastUsedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        addedAt = try c.decode(Date.self, forKey: .addedAt)
        lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        if let transport = try c.decodeIfPresent(HostTransport.self, forKey: .transport) {
            self.transport = transport
        } else {
            self.transport = .directHTTP(baseURL: try c.decode(URL.self, forKey: .baseURL))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(label, forKey: .label)
        if case .directHTTP(let baseURL) = transport {
            try c.encode(baseURL, forKey: .baseURL)
        }
        try c.encode(transport, forKey: .transport)
        try c.encode(addedAt, forKey: .addedAt)
        try c.encodeIfPresent(lastUsedAt, forKey: .lastUsedAt)
    }
}
#endif
