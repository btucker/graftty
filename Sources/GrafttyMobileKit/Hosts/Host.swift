#if canImport(UIKit)
import Foundation

/// A saved Graftty server the user has onboarded via QR or manual entry.
public struct Host: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var label: String
    public var baseURL: URL
    public var addedAt: Date
    public var lastUsedAt: Date?

    public init(
        id: UUID = UUID(),
        label: String,
        baseURL: URL,
        addedAt: Date = Date(),
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.label = label
        self.baseURL = baseURL
        self.addedAt = addedAt
        self.lastUsedAt = lastUsedAt
    }
}
#endif
