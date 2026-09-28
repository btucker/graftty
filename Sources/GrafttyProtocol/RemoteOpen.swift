import Foundation

public struct RemoteOpenOffer: Codable, Sendable, Equatable, Identifiable {
    public static let maxBytes = 20 * 1024 * 1024
    public static let chunkBytes = 48 * 1024
    public let id: UUID
    public let filename: String
    public let byteCount: Int
    public let url: URL?

    public init(id: UUID, filename: String, byteCount: Int, url: URL? = nil) {
        self.id = id
        self.filename = filename
        self.byteCount = byteCount
        self.url = url
    }
}

public enum RemoteOpenRequest: Codable, Sendable, Equatable {
    case list
    case read(id: UUID, offset: Int)
}

public enum RemoteOpenResponse: Codable, Sendable, Equatable {
    case offers([RemoteOpenOffer])
    case chunk(Data)
}
