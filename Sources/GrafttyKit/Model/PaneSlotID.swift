import Foundation

public struct PaneSlotID: Hashable, Codable, Identifiable, Sendable {
    public let id: UUID

    public init() {
        self.id = UUID()
    }

    public init(id: UUID) {
        self.id = id
    }
}

public typealias TerminalID = PaneSlotID
