import Foundation

public struct TerminalID: Hashable, Codable, Identifiable, Sendable {
    public let id: UUID

    public init() {
        self.id = UUID()
    }

    public init(id: UUID) {
        self.id = id
    }
}
