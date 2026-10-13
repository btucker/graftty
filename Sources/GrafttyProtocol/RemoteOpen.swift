import Foundation

/// @spec PORTS-5.38: When a remote open offer crosses a host connection, the application shall preserve its originating pane session and intended paired mobile device, and decode older offers without those identities as unspecified.
/// @spec IMAGE-2.1: When an image offer crosses a host connection, the application shall preserve optional image intent and recipient metadata while decoding absent or unknown intent without treating it as an image request.
public struct RemoteOpenOffer: Codable, Sendable, Equatable, Identifiable {
    public static let maxBytes = 20 * 1024 * 1024
    public static let chunkBytes = 48 * 1024
    public let id: UUID
    public let filename: String
    public let byteCount: Int
    public let url: URL?
    public let paneSessionName: String?
    public let browserOwnerDeviceID: RemoteDeviceID?
    /// Only the explicit "image" value identifies a graftty image request.
    /// Unknown intent values remain ordinary manually opened resources.
    public let previewKind: String?
    public let previewOwnerDeviceID: RemoteDeviceID?

    public init(id: UUID, filename: String, byteCount: Int, url: URL? = nil,
                paneSessionName: String? = nil, browserOwnerDeviceID: RemoteDeviceID? = nil,
                previewKind: String? = nil, previewOwnerDeviceID: RemoteDeviceID? = nil) {
        self.id = id
        self.filename = filename
        self.byteCount = byteCount
        self.url = url
        self.paneSessionName = paneSessionName
        self.browserOwnerDeviceID = browserOwnerDeviceID
        self.previewKind = previewKind
        self.previewOwnerDeviceID = previewOwnerDeviceID
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
