#if canImport(UIKit)
import Foundation
import GrafttyProtocol

/// A paired Mac plus its last-known routing hint.
public struct Host: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var label: String
    public var baseURL: URL
    public var addedAt: Date
    public var lastUsedAt: Date?

    /// The host's stable remote-pairing device identifier (REMOTE-1.5).
    /// `nil` for hosts added via manual URL entry, or persisted before this
    /// field existed — `decodeIfPresent` on the synthesized `Codable`
    /// conformance keeps old saved-host JSON decoding cleanly.
    public var remoteDeviceID: RemoteDeviceID?

    public init(
        id: UUID = UUID(),
        label: String,
        baseURL: URL,
        addedAt: Date = Date(),
        lastUsedAt: Date? = nil,
        remoteDeviceID: RemoteDeviceID? = nil
    ) {
        self.id = id
        self.label = label
        self.baseURL = baseURL
        self.addedAt = addedAt
        self.lastUsedAt = lastUsedAt
        self.remoteDeviceID = remoteDeviceID
    }
}
#endif
