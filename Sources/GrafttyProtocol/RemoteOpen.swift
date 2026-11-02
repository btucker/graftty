import Foundation

/// @spec PORTS-5.38: When a remote open offer crosses a host connection, the application shall preserve its originating pane session and intended paired mobile device, and decode older offers without those identities as unspecified.
/// @spec IMAGE-2.1: When a native preview offer crosses a host connection, the application shall preserve optional native preview intent, collection identity and recipient metadata while decoding absent or unknown intent without treating it as a native preview request.
public struct RemoteOpenOffer: Codable, Sendable, Equatable, Identifiable {
    public static let maxBytes = 20 * 1024 * 1024
    public static let chunkBytes = 48 * 1024
    public let id: UUID
    public let filename: String
    public let byteCount: Int
    public let url: URL?
    public let paneSessionName: String?
    public let browserOwnerDeviceID: RemoteDeviceID?
    /// The explicit "image" and "file" values identify native preview requests.
    /// Unknown intent values remain ordinary manually opened resources.
    public var isNativePreview: Bool { previewKind == "image" || previewKind == "file" }
    public let previewGroupID: UUID?
    public let previewKind: String?
    public let previewOwnerDeviceID: RemoteDeviceID?

    public init(id: UUID, filename: String, byteCount: Int, url: URL? = nil,
                paneSessionName: String? = nil, browserOwnerDeviceID: RemoteDeviceID? = nil,
                previewKind: String? = nil, previewOwnerDeviceID: RemoteDeviceID? = nil, previewGroupID: UUID? = nil) {
        self.id = id
        self.filename = filename
        self.byteCount = byteCount
        self.url = url
        self.paneSessionName = paneSessionName
        self.browserOwnerDeviceID = browserOwnerDeviceID
        self.previewGroupID = previewGroupID
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

/// A collection remains selectable independently of its originating pane or recipient.
public struct WorktreePreviewCollection: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let offers: [RemoteOpenOffer]
    public var title: String { offers.map(\.filename).joined(separator: ", ") }
}

public extension RemoteOpenOffer {
    static func previewCollections(in offers: [RemoteOpenOffer]) -> [WorktreePreviewCollection] {
        var order: [UUID] = []
        var groups: [UUID: [RemoteOpenOffer]] = [:]
        for offer in offers where offer.isNativePreview && offer.url == nil {
            let id = offer.previewGroupID ?? offer.id
            if groups[id] == nil { order.append(id) }
            groups[id, default: []].append(offer)
        }
        return order.reversed().map { WorktreePreviewCollection(id: $0, offers: groups[$0] ?? []) }
    }
}
