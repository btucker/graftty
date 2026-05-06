import Foundation

/// @spec TEAM-IDLE-2.2
/// Process-wide per-pane "last user keystroke landed at" map. Written
/// by `PaneInputActivityObserver` at the libghostty input boundary,
/// read by `IdleDeliveryService` for the 60s user-engaged gate.
public final class PaneInputActivityRegistry: @unchecked Sendable {
    private let now: @Sendable () -> Date
    private let stamps = LockedDictionary<UUID, Date>()

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public func recordKeystroke(paneID: UUID) {
        stamps.set(paneID, now())
    }

    public func lastInputAt(paneID: UUID) -> Date? {
        stamps.get(paneID)
    }

    public func removeStamp(paneID: UUID) {
        stamps.remove(paneID)
    }
}
