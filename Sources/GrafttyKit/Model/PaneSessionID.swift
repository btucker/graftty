import Foundation

public struct PaneSessionID: Hashable, Codable, Identifiable, Sendable {
    public let id: UUID

    public init() {
        self.id = UUID()
    }

    public init(id: UUID) {
        self.id = id
    }

    public static func migratedFromLegacySlot(_ slot: PaneSlotID) -> PaneSessionID {
        PaneSessionID(id: slot.id)
    }
}
