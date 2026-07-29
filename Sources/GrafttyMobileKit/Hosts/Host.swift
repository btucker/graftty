#if canImport(UIKit)
import Foundation
import GrafttyProtocol

/// A paired Mac plus its last-known routing hint.
public struct Host: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var label: String
    public var baseURL: URL
    public var routes: [RemoteConnectionRoute]
    public var addedAt: Date
    public var lastUsedAt: Date?

    /// The host's stable remote-pairing device identifier (REMOTE-1.5).
    /// `nil` for hosts added via manual URL entry, or persisted before this
    /// field existed — `decodeIfPresent` on the synthesized `Codable`
    /// conformance keeps old saved-host JSON decoding cleanly.
    public var remoteDeviceID: RemoteDeviceID?
    public var pairingProtocolVersion: Int?

    public init(
        id: UUID = UUID(),
        label: String,
        baseURL: URL,
        routes: [RemoteConnectionRoute] = [],
        addedAt: Date = Date(),
        lastUsedAt: Date? = nil,
        remoteDeviceID: RemoteDeviceID? = nil
    ) {
        self.id = id
        self.label = label
        self.baseURL = baseURL
        self.routes = routes
        self.addedAt = addedAt
        self.lastUsedAt = lastUsedAt
        self.remoteDeviceID = remoteDeviceID
        self.pairingProtocolVersion =
            remoteDeviceID == nil
            ? nil
            : RemoteAccessProtocol.version
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case label
        case baseURL
        case routes
        case addedAt
        case lastUsedAt
        case remoteDeviceID
        case pairingProtocolVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        baseURL = try container.decode(URL.self, forKey: .baseURL)
        routes =
            try container.decodeIfPresent(
                [RemoteConnectionRoute].self,
                forKey: .routes
            ) ?? []
        addedAt = try container.decode(Date.self, forKey: .addedAt)
        lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        remoteDeviceID = try container.decodeIfPresent(
            RemoteDeviceID.self,
            forKey: .remoteDeviceID
        )
        pairingProtocolVersion = try container.decodeIfPresent(
            Int.self,
            forKey: .pairingProtocolVersion
        )
    }
}
#endif
