import Foundation

/// @spec TEAM-IDLE-2.2
/// Process-wide per-pane "last user keystroke landed at" map. Written
/// by `PaneInputActivityObserver` at the libghostty input boundary,
/// read by `IdleDeliveryService` for the 60s user-engaged gate.
public final class PaneInputActivityRegistry: @unchecked Sendable {
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var stamps: [UUID: Date] = [:]

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public func recordKeystroke(paneID: UUID) {
        lock.lock(); defer { lock.unlock() }
        stamps[paneID] = now()
    }

    public func lastInputAt(paneID: UUID) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return stamps[paneID]
    }

    public func removeStamp(paneID: UUID) {
        lock.lock(); defer { lock.unlock() }
        stamps.removeValue(forKey: paneID)
    }
}
