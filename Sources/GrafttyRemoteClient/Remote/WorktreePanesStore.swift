import Foundation
import GrafttyProtocol

/// Client-side façade for the `panes-state@graftty.dev` SSH subsystem.
/// Opens the channel via the supplied `PanesStateChannelDriver`,
/// receives decoded `[WorktreePanes]` snapshots from the driver's
/// inbound-snapshot callback, and exposes `current: [WorktreePanes]`
/// as actor-isolated observable state the sidebar can read.
///
/// The public method surface (`subscribe`, `unsubscribe`, `current`,
/// `connectionState`) is unchanged from R4 — `RootView` consumers don't
/// need to change.
public actor WorktreePanesStore {

    public enum SubscriptionError: Error, Equatable {
        case closedDuringOpen(reason: String)
    }

    public enum ConnectionState: Sendable, Equatable {
        case idle
        case subscribed
        case closed(reason: String)
    }

    public private(set) var current: [WorktreePanes] = []
    public private(set) var sidebar: SidebarSnapshot?
    public var currentSnapshot: PanesStateMessage? {
        hasReceivedSnapshot ? .snapshot(current, sidebar: sidebar) : nil
    }

    /// A consumer that already fetched rows may reconcile only against the
    /// same frame. Nil differs from a matching legacy frame without metadata.
    public func navigationSnapshot(matching worktrees: [WorktreePanes]) -> PanesStateMessage? {
        current == worktrees ? currentSnapshot : nil
    }
    public private(set) var connectionState: ConnectionState = .idle {
        didSet { resumeFirstSnapshotWaitersIfSettled() }
    }
    /// Distinguishes a legitimate first empty snapshot from "the SSH
    /// subsystem is open but has not delivered its initial state yet."
    public private(set) var hasReceivedSnapshot = false {
        didSet { resumeFirstSnapshotWaitersIfSettled() }
    }

    public enum FirstSnapshotOutcome: Sendable, Equatable {
        case received, closed, timedOut
    }

    private var firstSnapshotWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    private let driver: PanesStateChannelDriver

    public init(driver: PanesStateChannelDriver) {
        self.driver = driver
    }

    public func subscribe() async throws {
        try await driver.open()
        switch connectionState {
        case .idle:
            connectionState = .subscribed
        case .subscribed:
            break
        case .closed(let reason):
            driver.close()
            throw SubscriptionError.closedDuringOpen(reason: reason)
        }
    }

    public func unsubscribe() async {
        driver.close()
        self.connectionState = .closed(reason: "unsubscribed")
    }

    /// Called by the channel driver's `onSnapshot` callback when a new
    /// snapshot arrives. Wired up by whoever constructs the driver +
    /// store (see Task 12 for production wiring; tests inject directly).
    public func applySnapshot(_ snapshot: [WorktreePanes]) {
        // The channel's serial drain awaits this callback before decoding the
        // next frame, so these metadata and rows belong to the same frame.
        self.sidebar = (driver as? SidebarSnapshotProviding)?.sidebarSnapshot
        self.current = snapshot
        self.hasReceivedSnapshot = true
    }

    /// Suspends until the first snapshot is applied or the channel closes,
    /// whichever comes first; a close is reported even if a snapshot also
    /// arrived. Reports `.timedOut` only when `timeout` elapses first.
    public func waitForFirstSnapshot(timeout: Duration) async throws -> FirstSnapshotOutcome {
        try await waitForFirstSnapshot(deadline: .after(timeout))
    }

    func waitForFirstSnapshot(deadline: ReplyDeadline) async throws -> FirstSnapshotOutcome {
        if firstSnapshotOutcome == nil {
            let id = UUID()
            let disarm = deadline.schedule { [weak self] in
                Task { await self?.resumeFirstSnapshotWaiter(id) }
            }
            defer { disarm() }
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if firstSnapshotOutcome != nil || Task.isCancelled {
                        continuation.resume()
                    } else {
                        firstSnapshotWaiters[id] = continuation
                    }
                }
            } onCancel: {
                Task { await self.resumeFirstSnapshotWaiter(id) }
            }
        }
        try Task.checkCancellation()
        return firstSnapshotOutcome ?? .timedOut
    }

    private var firstSnapshotOutcome: FirstSnapshotOutcome? {
        if case .closed = connectionState { return .closed }
        return hasReceivedSnapshot ? .received : nil
    }

    private func resumeFirstSnapshotWaiter(_ id: UUID) {
        firstSnapshotWaiters.removeValue(forKey: id)?.resume()
    }

    private func resumeFirstSnapshotWaitersIfSettled() {
        guard firstSnapshotOutcome != nil, !firstSnapshotWaiters.isEmpty else { return }
        let waiters = firstSnapshotWaiters.values
        firstSnapshotWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// Called by the channel driver's `onClosed` callback when the SSH
    /// channel closes.
    public func markClosed(reason: String) {
        self.connectionState = .closed(reason: reason)
    }
}

/// Protocol exposed for test substitution. `PanesStateChannelClient`
/// conforms; tests substitute a fake driver.
public protocol PanesStateChannelDriver: Sendable {
    func open() async throws
    func close()
}

public protocol PanesStateCallbacksConfigurable: Sendable {
    func setCallbacks(
        onSnapshot: @escaping PanesStateChannelClient.OnSnapshot,
        onClosed: @escaping PanesStateChannelClient.OnClosed
    )
}

extension PanesStateChannelClient:
    PanesStateChannelDriver,
    PanesStateCallbacksConfigurable {}

public protocol SidebarSnapshotProviding: Sendable {
    var sidebarSnapshot: SidebarSnapshot? { get }
}
extension PanesStateChannelClient: SidebarSnapshotProviding {}
