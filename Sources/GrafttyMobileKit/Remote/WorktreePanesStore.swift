#if canImport(UIKit)
import Foundation
import GrafttyProtocol

/// Mobile-side façade for the `panes-state@graftty.dev` SSH subsystem.
/// Opens the channel via the supplied `PanesStateChannelDriver`,
/// receives decoded `[WorktreePanes]` snapshots from the driver's
/// inbound-snapshot callback, and exposes `current: [WorktreePanes]`
/// as actor-isolated observable state the sidebar can read.
///
/// The public method surface (`subscribe`, `unsubscribe`, `current`,
/// `connectionState`) is unchanged from the pre-R5 ChannelRouter-based
/// version — `RootView` consumers don't need to change.
public actor WorktreePanesStore {

    public enum ConnectionState: Sendable, Equatable {
        case idle
        case subscribed
        case closed(reason: String)
    }

    public private(set) var current: [WorktreePanes] = []
    public private(set) var connectionState: ConnectionState = .idle

    private let driver: PanesStateChannelDriver

    public init(driver: PanesStateChannelDriver) {
        self.driver = driver
    }

    public func subscribe() async throws {
        try await driver.open()
        self.connectionState = .subscribed
    }

    public func unsubscribe() async {
        driver.close()
        self.connectionState = .closed(reason: "unsubscribed")
    }

    /// Called by the channel driver's `onSnapshot` callback when a new
    /// snapshot arrives. Wired up by whoever constructs the driver +
    /// store (see Task 12 for production wiring; tests inject directly).
    func applySnapshot(_ snapshot: [WorktreePanes]) {
        self.current = snapshot
    }

    /// Called by the channel driver's `onClosed` callback when the SSH
    /// channel closes.
    func markClosed(reason: String) {
        self.connectionState = .closed(reason: reason)
    }
}

/// Protocol exposed for test substitution. `PanesStateChannelClient`
/// conforms; tests substitute a fake driver.
public protocol PanesStateChannelDriver: Sendable {
    func open() async throws
    func close()
}

extension PanesStateChannelClient: PanesStateChannelDriver {}
#endif
