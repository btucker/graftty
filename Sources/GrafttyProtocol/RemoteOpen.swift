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
    public let createdAt: Date?
    /// Raised when the host revises a collection in place as its source files change.
    /// Absent on older hosts and on content that has never changed.
    public let contentRevision: Int?

    public init(id: UUID, filename: String, byteCount: Int, url: URL? = nil,
                paneSessionName: String? = nil, browserOwnerDeviceID: RemoteDeviceID? = nil,
                previewKind: String? = nil, previewOwnerDeviceID: RemoteDeviceID? = nil, previewGroupID: UUID? = nil, createdAt: Date? = nil, contentRevision: Int? = nil) {
        self.id = id
        self.filename = filename
        self.byteCount = byteCount
        self.url = url
        self.paneSessionName = paneSessionName
        self.browserOwnerDeviceID = browserOwnerDeviceID
        self.previewGroupID = previewGroupID
        self.previewKind = previewKind
        self.previewOwnerDeviceID = previewOwnerDeviceID
        self.createdAt = createdAt
        self.contentRevision = contentRevision
    }

    /// The same offer identity carrying newer bytes, so clients that already consumed
    /// this offer refresh it rather than treat it as a new request to open.
    public func revised(byteCount: Int, contentRevision: Int) -> RemoteOpenOffer {
        RemoteOpenOffer(id: id, filename: filename, byteCount: byteCount, url: url,
                        paneSessionName: paneSessionName, browserOwnerDeviceID: browserOwnerDeviceID,
                        previewKind: previewKind, previewOwnerDeviceID: previewOwnerDeviceID,
                        previewGroupID: previewGroupID, createdAt: createdAt, contentRevision: contentRevision)
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
    public var title: String {
        let first = offers.first?.filename ?? "Preview"
        return offers.count > 1 ? "\(first) + \(offers.count - 1) more" : first
    }
    public var createdAt: Date? { offers.first?.createdAt }
    public var contentRevision: Int { offers.first?.contentRevision ?? 0 }
    public var menuTitle: String { Self.menuTitle(title, createdAt: createdAt) }

    public static func menuTitle(_ title: String, createdAt: Date?) -> String {
        guard let createdAt else { return title }
        let date: Date.FormatStyle.DateStyle = Calendar.current.isDateInToday(createdAt) ? .omitted : .abbreviated
        return title + " · " + createdAt.formatted(date: date, time: .shortened)
    }
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
