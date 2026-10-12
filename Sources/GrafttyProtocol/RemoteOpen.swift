import Foundation

/// @spec PORTS-5.38: When a remote open offer crosses a host connection, the application shall preserve its originating pane session and intended paired mobile device, and decode older offers without those identities as unspecified.
public struct RemoteOpenOffer: Codable, Sendable, Equatable, Identifiable {
    public static let maxBytes = 20 * 1024 * 1024
    public static let chunkBytes = 48 * 1024
    public let id: UUID
    public let filename: String
    public let byteCount: Int
    public let url: URL?
    public let paneSessionName: String?
    public let browserOwnerDeviceID: RemoteDeviceID?

    public init(id: UUID, filename: String, byteCount: Int, url: URL? = nil,
                paneSessionName: String? = nil, browserOwnerDeviceID: RemoteDeviceID? = nil) {
        self.id = id
        self.filename = filename
        self.byteCount = byteCount
        self.url = url
        self.paneSessionName = paneSessionName
        self.browserOwnerDeviceID = browserOwnerDeviceID
    }
}

public enum RemoteOpenRequest: Codable, Sendable, Equatable {
    case list
    case read(id: UUID, offset: Int)
    case port(UInt16)
    case authenticate(URL)
}

public enum RemoteOpenResponse: Codable, Sendable, Equatable {
    case offers([RemoteOpenOffer])
    case chunk(Data)
    case url(URL)
    case authentication(url: URL, callbackHost: String)
}
