import Foundation
import GrafttyProtocol
import NIOConcurrencyHelpers

/// An unopened panes-state channel whose callbacks the subscription rewires
/// to the store it builds around the channel.
public typealias PanesStateSubscriptionDriver =
    PanesStateChannelDriver & PanesStateCallbacksConfigurable

/// Builds unopened panes-state channels that request a subsystem reply, so a
/// host that predates V2 can reject it. Both host connection actors conform;
/// tests substitute fakes.
public protocol PanesStateDriverMaking: Sendable {
    func makePanesStateDriver(
        originAware: Bool
    ) async throws -> any PanesStateSubscriptionDriver
}

/// The one panes-state subscription path shared by the Mac-to-Mac registry
/// and the mobile coordinator.
public enum PanesStateSubscription {
    /// Returns a subscribed store on the origin-aware V2 channel, or on V1
    /// when the host rejects V2. `onClosed` only hears closes that follow a
    /// completed open; a close during the open fails the subscription instead,
    /// and the owner hears nothing further from that channel.
    public static func open(
        on host: some PanesStateDriverMaking,
        onSnapshot: @escaping PanesStateChannelClient.OnSnapshot = { _ in },
        onClosed: @escaping PanesStateChannelClient.OnClosed = { _ in }
    ) async throws -> WorktreePanesStore {
        do {
            return try await subscribe(host, originAware: true, onSnapshot, onClosed)
        } catch let error where isSubsystemRejection(error) {
            // A superseded or torn-down attempt must not open a second channel.
            try Task.checkCancellation()
            return try await subscribe(host, originAware: false, onSnapshot, onClosed)
        }
    }

    private static func subscribe(
        _ host: some PanesStateDriverMaking,
        originAware: Bool,
        _ onSnapshot: @escaping PanesStateChannelClient.OnSnapshot,
        _ onClosed: @escaping PanesStateChannelClient.OnClosed
    ) async throws -> WorktreePanesStore {
        let driver = try await host.makePanesStateDriver(originAware: originAware)
        let store = WorktreePanesStore(driver: driver)
        // Exactly one side decides each close: before the open completes it
        // fails the subscription; afterwards it reaches the owner.
        let gate = NIOLockedValueBox(OpenGate.opening)
        driver.setCallbacks(
            onSnapshot: { [weak store] snapshot in
                await store?.applySnapshot(snapshot)
                // Frames buffered before a close during the open still drain;
                // the failed subscription must not hand them to the owner.
                let failed = gate.withLockedValue { state -> Bool in
                    if case .closedDuringOpen = state { return true }
                    return false
                }
                if !failed { await onSnapshot(snapshot) }
            },
            onClosed: { [weak store] reason in
                let reachesOwner = gate.withLockedValue { state in
                    if case .open = state { return true }
                    state = .closedDuringOpen(reason)
                    return false
                }
                await store?.markClosed(reason: reason)
                if reachesOwner { await onClosed(reason) }
            }
        )
        do {
            try await store.subscribe()
        } catch {
            await store.unsubscribe()
            throw error
        }
        let closedDuringOpen = gate.withLockedValue { state -> String? in
            if case .closedDuringOpen(let reason) = state { return reason }
            state = .open
            return nil
        }
        if let closedDuringOpen {
            await store.unsubscribe()
            throw WorktreePanesStore.SubscriptionError.closedDuringOpen(reason: closedDuringOpen)
        }
        return store
    }

    private enum OpenGate {
        case opening, open
        case closedDuringOpen(String)
    }

    private static func isSubsystemRejection(_ error: any Error) -> Bool {
        switch error as? PanesStateChannelClient.ClientError {
        case .subsystemRejected:
            return true
        case .openFailed(let underlying):
            return isSubsystemRejection(underlying)
        case .channelClosed, .timedOut, nil:
            return false
        }
    }
}

extension DirectSSHHostConnection: PanesStateDriverMaking {
    public func makePanesStateDriver(
        originAware: Bool
    ) throws -> any PanesStateSubscriptionDriver {
        try makePanesStateClient(
            onSnapshot: { _ in }, onClosed: { _ in },
            originAware: originAware, requestReply: true
        )
    }
}

#if canImport(WebRTC)
extension RemoteHostConnection: PanesStateDriverMaking {
    public func makePanesStateDriver(
        originAware: Bool
    ) async throws -> any PanesStateSubscriptionDriver {
        try await makePanesStateClient(
            onSnapshot: { _ in }, onClosed: { _ in },
            originAware: originAware, requestReply: true
        )
    }
}
#endif
