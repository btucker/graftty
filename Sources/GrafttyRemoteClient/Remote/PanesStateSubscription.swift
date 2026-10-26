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
    public static func open(
        on host: some PanesStateDriverMaking,
        onSnapshot: @escaping PanesStateChannelClient.OnSnapshot = { _ in },
        onClosed: @escaping PanesStateChannelClient.OnClosed = { _ in }
    ) async throws -> WorktreePanesStore {
        try await open(on: host, health: .init(), onSnapshot: onSnapshot, onClosed: onClosed)
    }

    static func open(
        on host: some PanesStateDriverMaking,
        health: PanesStateHealthPolicy,
        onSnapshot: @escaping PanesStateChannelClient.OnSnapshot = { _ in },
        onClosed: @escaping PanesStateChannelClient.OnClosed = { _ in }
    ) async throws -> WorktreePanesStore {
        let driver = RenewingPanesStateDriver(health: health) { continuation in
            try await openOnce(
                on: host,
                onClosed: { _ in continuation.finish() },
                onFrame: { continuation.yield($0) }
            )
        }
        return try await subscribe(driver: driver, onSnapshot, onClosed)
    }

    /// Returns a subscribed store on the origin-aware V2 channel, or on V1
    /// when the host rejects V2. `onClosed` only hears closes that follow a
    /// completed open; a close during the open fails the subscription instead,
    /// and the owner hears nothing further from that channel.
    static func openOnce(
        on host: some PanesStateDriverMaking,
        onSnapshot: @escaping PanesStateChannelClient.OnSnapshot = { _ in },
        onClosed: @escaping PanesStateChannelClient.OnClosed = { _ in },
        onFrame: @escaping @Sendable (PanesStateMessage) async -> Void = { _ in }
    ) async throws -> WorktreePanesStore {
        try Task.checkCancellation()
        do {
            return try await subscribe(host, originAware: true, onSnapshot, onClosed, onFrame)
        } catch let error where isSubsystemRejection(error) {
            // A superseded or torn-down attempt must not open a second channel.
            try Task.checkCancellation()
            return try await subscribe(host, originAware: false, onSnapshot, onClosed, onFrame)
        }
    }

    private static func subscribe(
        _ host: some PanesStateDriverMaking,
        originAware: Bool,
        _ onSnapshot: @escaping PanesStateChannelClient.OnSnapshot,
        _ onClosed: @escaping PanesStateChannelClient.OnClosed,
        _ onFrame: @escaping @Sendable (PanesStateMessage) async -> Void
    ) async throws -> WorktreePanesStore {
        let driver = try await host.makePanesStateDriver(originAware: originAware)
        return try await subscribe(driver: driver, onSnapshot, onClosed, onFrame)
    }

    private static func subscribe(
        driver: any PanesStateSubscriptionDriver,
        _ onSnapshot: @escaping PanesStateChannelClient.OnSnapshot,
        _ onClosed: @escaping PanesStateChannelClient.OnClosed,
        _ onFrame: @escaping @Sendable (PanesStateMessage) async -> Void = { _ in }
    ) async throws -> WorktreePanesStore {
        let store = WorktreePanesStore(driver: driver)
        // Exactly one side decides each close: before the open completes it
        // fails the subscription; afterwards it reaches the owner.
        let gate = NIOLockedValueBox(OpenGate.opening)
        driver.setCallbacks(
            onSnapshot: { [weak store] snapshot in
                guard let store, await store.applySnapshotIfOpen(snapshot) else { return }
                // Frames buffered before a close during the open still drain;
                // the failed subscription must not hand them to the owner.
                let failed = gate.withLockedValue { state -> Bool in
                    if case .closedDuringOpen = state { return true }
                    return false
                }
                if !failed {
                    if let frame = await store.currentSnapshot { await onFrame(frame) }
                    await onSnapshot(snapshot)
                }
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
            try Task.checkCancellation()
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

/// Renewal does not infer health from incremental traffic: idle hosts deduplicate it.
struct PanesStateHealthPolicy: Sendable {
    var renewal: ReplyDeadline = .after(.seconds(60))
    var initialSnapshot: ReplyDeadline = .after(.seconds(15))
}
