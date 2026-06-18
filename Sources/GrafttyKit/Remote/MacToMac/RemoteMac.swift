import Foundation
import GrafttyProtocol

public struct RemoteMac: Codable, Sendable, Hashable, Identifiable {
    public let id: RemoteDeviceID
    public var label: String
    public var fingerprint: RemoteIdentityFingerprint
    public var lastKnownBaseURL: URL?
    public var addedAt: Date
    public var lastUsedAt: Date?
    public var lastDiscoveredAt: Date?

    public init(
        id: RemoteDeviceID,
        label: String,
        fingerprint: RemoteIdentityFingerprint,
        lastKnownBaseURL: URL? = nil,
        addedAt: Date = Date(),
        lastUsedAt: Date? = nil,
        lastDiscoveredAt: Date? = nil
    ) {
        self.id = id
        self.label = label
        self.fingerprint = fingerprint
        self.lastKnownBaseURL = lastKnownBaseURL
        self.addedAt = addedAt
        self.lastUsedAt = lastUsedAt
        self.lastDiscoveredAt = lastDiscoveredAt
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
