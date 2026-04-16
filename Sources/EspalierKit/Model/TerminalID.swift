import Foundation

public struct TerminalID: Hashable, Codable, Identifiable {
    public let id: UUID

    public init() {
        self.id = UUID()
    }

    public init(id: UUID) {
        self.id = id
    }
}
