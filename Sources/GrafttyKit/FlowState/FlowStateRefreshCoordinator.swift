import Foundation

public enum FlowRefreshTrigger: Sendable, Equatable {
    case viewOpened
    case selectionStable(worktreeRef: String, selectedAt: Date)
    case attention(worktreeRef: String, currentFocusStableSince: Date)
    case backgroundTick
    case explicitUserRefresh
}

public struct FlowStateRefreshCoordinator: Sendable {
    public var refreshInterval: TimeInterval
    public var focusStabilityDelay: TimeInterval
    public var attentionStableFocusDelay: TimeInterval
    public var statusRequestCooldown: TimeInterval
    public var now: @Sendable () -> Date

    private var selectedWorktreeRef: String?
    private var selectionChangedAt: Date?
    private var lastBackgroundRefreshAt: Date?
    private var statusRequestTimes: [String: Date]

    public init(
        refreshInterval: TimeInterval = 600,
        focusStabilityDelay: TimeInterval = 30,
        attentionStableFocusDelay: TimeInterval = 300,
        statusRequestCooldown: TimeInterval = 1_200,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.refreshInterval = refreshInterval
        self.focusStabilityDelay = focusStabilityDelay
        self.attentionStableFocusDelay = attentionStableFocusDelay
        self.statusRequestCooldown = statusRequestCooldown
        self.now = now
        self.selectedWorktreeRef = nil
        self.selectionChangedAt = nil
        self.lastBackgroundRefreshAt = nil
        self.statusRequestTimes = [:]
    }

    public func shouldRefresh(for trigger: FlowRefreshTrigger, at date: Date? = nil) -> Bool {
        let currentDate = date ?? now()
        switch trigger {
        case .viewOpened, .explicitUserRefresh:
            return true
        case .selectionStable(let worktreeRef, let selectedAt):
            guard selectedWorktreeRef == worktreeRef else { return false }
            let effectiveSelectedAt = selectionChangedAt ?? selectedAt
            return currentDate.timeIntervalSince(effectiveSelectedAt) >= focusStabilityDelay
                || currentDate.timeIntervalSince(selectedAt) >= focusStabilityDelay
        case .attention(_, let currentFocusStableSince):
            return currentDate.timeIntervalSince(currentFocusStableSince) >= attentionStableFocusDelay
        case .backgroundTick:
            guard let lastBackgroundRefreshAt else { return true }
            return currentDate.timeIntervalSince(lastBackgroundRefreshAt) >= refreshInterval
        }
    }

    public mutating func recordSelectionChanged(to worktreeRef: String, at date: Date? = nil) {
        selectedWorktreeRef = worktreeRef
        selectionChangedAt = date ?? now()
    }

    public mutating func recordBackgroundRefresh(at date: Date? = nil) {
        lastBackgroundRefreshAt = date ?? now()
    }

    public mutating func recordStatusRequest(worktreeRef: String, at date: Date? = nil) {
        statusRequestTimes[worktreeRef] = date ?? now()
    }

    public func canRequestStatus(worktreeRef: String, explicit: Bool, at date: Date? = nil) -> Bool {
        if explicit { return true }
        guard let last = statusRequestTimes[worktreeRef] else { return true }
        return (date ?? now()).timeIntervalSince(last) >= statusRequestCooldown
    }
}
