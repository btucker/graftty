import Foundation
import GrafttyProtocol

public struct RemoteMac: Codable, Sendable, Hashable, Identifiable {
    public let id: RemoteDeviceID
    public var transport: RemoteHostTransport
    public var directEndpoint: DirectSSHEndpoint?
    public var label: String
    public var fingerprint: RemoteIdentityFingerprint
    public var lastKnownBaseURL: URL?
    public var routes: [RemoteConnectionRoute]
    public var lastSuccessfulRoute: RemoteConnectionRoute?
    public var pairingProtocolVersion: Int?
    public var addedAt: Date
    public var lastUsedAt: Date?
    public var lastDiscoveredAt: Date?

    public init(
        id: RemoteDeviceID,
        label: String,
        fingerprint: RemoteIdentityFingerprint,
        lastKnownBaseURL: URL? = nil,
        transport: RemoteHostTransport = .webRTC,
        directEndpoint: DirectSSHEndpoint? = nil,
        routes: [RemoteConnectionRoute] = [],
        lastSuccessfulRoute: RemoteConnectionRoute? = nil,
        addedAt: Date = Date(),
        lastUsedAt: Date? = nil,
        lastDiscoveredAt: Date? = nil
    ) {
        self.transport = transport
        self.directEndpoint = directEndpoint
        self.id = id
        self.label = label
        self.fingerprint = fingerprint
        self.lastKnownBaseURL = lastKnownBaseURL
        self.routes =
            routes.isEmpty
            ? lastKnownBaseURL.map {
                [RemoteConnectionRoute(kind: .lan, baseURL: $0)]
            } ?? []
            : routes
        self.lastSuccessfulRoute = lastSuccessfulRoute
        self.pairingProtocolVersion = RemoteAccessProtocol.version
        self.addedAt = addedAt
        self.lastUsedAt = lastUsedAt
        self.lastDiscoveredAt = lastDiscoveredAt
    }

    private enum CodingKeys: String, CodingKey {
        case transport
        case directEndpoint
        case id
        case label
        case fingerprint
        case lastKnownBaseURL
        case routes
        case lastSuccessfulRoute
        case pairingProtocolVersion
        case addedAt
        case lastUsedAt
        case lastDiscoveredAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        transport = try container.decodeIfPresent(RemoteHostTransport.self, forKey: .transport) ?? .webRTC
        directEndpoint = try container.decodeIfPresent(DirectSSHEndpoint.self, forKey: .directEndpoint)
        id = try container.decode(RemoteDeviceID.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        fingerprint = try container.decode(
            RemoteIdentityFingerprint.self,
            forKey: .fingerprint
        )
        lastKnownBaseURL = try container.decodeIfPresent(
            URL.self,
            forKey: .lastKnownBaseURL
        )
        routes =
            try container.decodeIfPresent(
                [RemoteConnectionRoute].self,
                forKey: .routes
            ) ?? []
        lastSuccessfulRoute = try container.decodeIfPresent(
            RemoteConnectionRoute.self,
            forKey: .lastSuccessfulRoute
        )
        pairingProtocolVersion = try container.decodeIfPresent(
            Int.self,
            forKey: .pairingProtocolVersion
        )
        addedAt = try container.decode(Date.self, forKey: .addedAt)
        lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        lastDiscoveredAt = try container.decodeIfPresent(
            Date.self,
            forKey: .lastDiscoveredAt
        )
    }
}

public enum RemoteMacConnectionState: String, Codable, Sendable, Equatable {
    case offline
    case discovered
    case connecting
    case connected
    case failed
    case needsPairing
}

/// @spec REMOTE-20.1
/// When a saved remote host has no transport field, the application shall use WebRTC.
public enum RemoteHostTransport: String, Codable, Sendable, Hashable {
    case webRTC
    case directSSH
}

/// @spec REMOTE-20.2
/// When a remote host uses direct SSH, the application shall persist its explicit Graftty endpoint with default port 8801.
public struct DirectSSHEndpoint: Codable, Sendable, Hashable {
    public let host: String
    public let port: Int

    public enum ValidationError: Error { case invalidHost, invalidPort }

    public init(host: String, port: Int = 8801) throws {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, host.utf8.count <= 253,
              !host.contains(where: { $0.isWhitespace || $0.isNewline }),
              !host.contains("/"), !host.contains("@"), !host.contains("\\") else {
            throw ValidationError.invalidHost
        }
        guard (1...65535).contains(port) else { throw ValidationError.invalidPort }
        self.host = host
        self.port = port
    }

    private enum CodingKeys: String, CodingKey { case host, port }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(host: container.decode(String.self, forKey: .host),
                      port: container.decode(Int.self, forKey: .port))
    }
}
