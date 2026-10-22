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
    public private(set) var resourceObservation: HostResourceObservation?
    public var currentSnapshot: PanesStateMessage? {
        hasReceivedSnapshot ? .snapshot(current, sidebar: sidebar) : nil
    }

    /// A consumer that already fetched rows may reconcile only against the
    /// same frame. Nil differs from a matching legacy frame without metadata.
    public func navigationSnapshot(matching worktrees: [WorktreePanes]) -> PanesStateMessage? {
        current == worktrees ? currentSnapshot : nil
    }
    public private(set) var connectionState: ConnectionState = .idle
    /// Distinguishes a legitimate first empty snapshot from "the SSH
    /// subsystem is open but has not delivered its initial state yet."
    public private(set) var hasReceivedSnapshot = false

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
        clearResources()
    }

    /// Called by the channel driver's `onSnapshot` callback when a new
    /// snapshot arrives. Wired up by whoever constructs the driver +
    /// store (see Task 12 for production wiring; tests inject directly).
    public func applySnapshot(_ snapshot: [WorktreePanes], receivedAt: Date = Date()) {
        // The channel's serial drain awaits this callback before decoding the
        // next frame, so these metadata and rows belong to the same frame.
        self.sidebar = (driver as? SidebarSnapshotProviding)?.sidebarSnapshot
        if case .closed = connectionState {
            clearResources()
        } else if let sample = sidebar?.hostResources, sample.isValid {
            // Unchanged/replayed samples must not renew the local receipt timestamp.
            if sample.sampledAt <= receivedAt.timeIntervalSince1970 + 5,
               resourceObservation.map({ sample.sampledAt > $0.sample.sampledAt }) ?? true {
                resourceObservation = HostResourceObservation(sample: sample, receivedAt: receivedAt.timeIntervalSince1970)
            }
        } else { clearResources() }
        self.current = snapshot
        self.hasReceivedSnapshot = true
    }

    /// Called by the channel driver's `onClosed` callback when the SSH
    /// channel closes.
    public func markClosed(reason: String) {
        self.connectionState = .closed(reason: reason)
        clearResources()
    }

    private func clearResources() {
        resourceObservation = nil
        sidebar?.hostResources = nil
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
