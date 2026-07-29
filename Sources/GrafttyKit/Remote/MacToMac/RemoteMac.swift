import Foundation
import GrafttyProtocol

public struct RemoteMac: Codable, Sendable, Hashable, Identifiable {
    public let id: RemoteDeviceID
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
        routes: [RemoteConnectionRoute] = [],
        lastSuccessfulRoute: RemoteConnectionRoute? = nil,
        addedAt: Date = Date(),
        lastUsedAt: Date? = nil,
        lastDiscoveredAt: Date? = nil
    ) {
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
