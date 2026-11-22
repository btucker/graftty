import Foundation

/// One connection gate for the foreground phone and its concurrent watch work.
@MainActor
public final class WatchConnectionAccess {
    public private(set) var isAllowed = false
    private var foregroundConsumers: Set<UUID> = []
    private var watchEnabled: Bool
    private var leases: Set<UUID> = []
    private let setAllowed: (Bool) -> Void

    public init(watchEnabled: Bool, setAllowed: @escaping (Bool) -> Void) {
        self.watchEnabled = watchEnabled
        self.setAllowed = setAllowed
    }
    public func setForegroundAllowed(_ allowed: Bool, consumer: UUID) {
        if allowed { foregroundConsumers.insert(consumer) }
        else { foregroundConsumers.remove(consumer) }
        update()
    }
    public func setWatchEnabled(_ enabled: Bool) {
        watchEnabled = enabled
        if !enabled { leases.removeAll() }
        update()
    }
    public func beginWatchRequest() -> UUID? {
        guard watchEnabled, !Task.isCancelled else { return nil }
        let token = UUID()
        leases.insert(token)
        update()
        return token
    }
    public func endWatchRequest(_ token: UUID) {
        leases.remove(token)
        update()
    }
    public func isActive(_ token: UUID) -> Bool { leases.contains(token) }

    private func update() {
        let allowed = !foregroundConsumers.isEmpty || (watchEnabled && !leases.isEmpty)
        guard allowed != isAllowed else { return }
        isAllowed = allowed
        setAllowed(allowed)
    }
}
