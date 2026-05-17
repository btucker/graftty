#if canImport(UIKit)
import Foundation
import GrafttyProtocol

/// Mobile-side façade for the `panes_state` channel. Opens the channel on
/// the supplied `ChannelRouter`, decodes inbound snapshots, and exposes
/// `current: [WorktreePanes]` as actor-isolated observable state the
/// sidebar can read.
public actor WorktreePanesStore {

    public enum ConnectionState: Sendable, Equatable {
        case idle
        case subscribed
        case closed(reason: String)
    }

    public private(set) var current: [WorktreePanes] = []
    public private(set) var connectionState: ConnectionState = .idle

    private let router: ChannelRouter
    private var channelID: ChannelID?

    public init(router: ChannelRouter) {
        self.router = router
    }

    /// Open the `panes_state` channel. Returns when the initial open
    /// frame has been sent — snapshot frames arrive asynchronously.
    public func subscribe() async throws {
        let handler = SubscriberHandler(
            onSnapshot: { [weak self] snapshot in
                await self?.applySnapshot(snapshot)
            },
            onClosed: { [weak self] reason in
                await self?.markClosed(reason: reason)
            }
        )
        let id = try await router.open(type: "panes_state", handler: handler)
        self.channelID = id
        self.connectionState = .subscribed
    }

    public func unsubscribe() async {
        guard let id = channelID else { return }
        channelID = nil
        connectionState = .closed(reason: "unsubscribed")
        try? await router.close(id)
    }

    private func applySnapshot(_ snapshot: [WorktreePanes]) {
        self.current = snapshot
    }

    private func markClosed(reason: String) {
        self.connectionState = .closed(reason: reason)
        self.channelID = nil
    }
}

/// Handler installed by `WorktreePanesStore.subscribe()`. Reads inbound
/// `payload` frames, decodes each as a `PanesStateMessage`, and forwards
/// `snapshot` payloads to the store.
private actor SubscriberHandler: ChannelHandler {
    nonisolated let channelType = "panes_state"

    private let onSnapshot: @Sendable ([WorktreePanes]) async -> Void
    private let onClosed: @Sendable (String) async -> Void

    init(
        onSnapshot: @escaping @Sendable ([WorktreePanes]) async -> Void,
        onClosed: @escaping @Sendable (String) async -> Void
    ) {
        self.onSnapshot = onSnapshot
        self.onClosed = onClosed
    }

    func onOpen(_ id: ChannelID, outbox: ChannelOutbox) async {
        // No-op: the server pushes; the client doesn't send.
    }

    func onPayload(_ data: Data) async {
        let message: PanesStateMessage
        do {
            message = try JSONDecoder().decode(PanesStateMessage.self, from: data)
        } catch {
            return
        }
        switch message {
        case .snapshot(let worktrees):
            await onSnapshot(worktrees)
        }
    }

    func onClose() async {
        await onClosed("channel-closed")
    }

    func onError(_ code: String, message: String) async {
        await onClosed("\(code): \(message)")
    }
}
#endif
