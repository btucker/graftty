import Foundation
import GrafttyProtocol

/// Server-side handler for the `panes_state` channel. On open, emits an
/// initial snapshot and then re-emits whenever the injected
/// `subscribe(_:)` callback fires the supplied closure with a fresh
/// `[WorktreePanes]`. The handler owns the dispatch lifecycle: when the
/// channel closes (via `onClose` or `onError`), the subscription is
/// cancelled and no further frames are emitted.
///
/// Production wires `subscribe` to the same `WorktreeMonitor` change
/// pipeline the desktop sidebar consumes. Tests pass a fake that fires
/// the callback on demand.
public actor PanesStateHandler: ChannelHandler {
    public nonisolated let channelType = "panes_state"

    public typealias Snapshot = [WorktreePanes]
    public typealias Subscribe = @Sendable (
        _ onChange: @escaping @Sendable (Snapshot) async -> Void
    ) async -> Cancellable

    public struct Cancellable: Sendable {
        private let cancel: @Sendable () -> Void
        public init(cancel: @escaping @Sendable () -> Void) {
            self.cancel = cancel
        }
        public func callAsFunction() { cancel() }
    }

    private let subscribe: Subscribe
    private var cancellable: Cancellable?
    private var outbox: ChannelOutbox?
    private var channelID: ChannelID?

    public init(subscribe: @escaping Subscribe) {
        self.subscribe = subscribe
    }

    public func onOpen(_ id: ChannelID, outbox: ChannelOutbox) async {
        self.outbox = outbox
        self.channelID = id
        let cancellable = await subscribe { [weak self] snapshot in
            await self?.send(snapshot: snapshot)
        }
        self.cancellable = cancellable
    }

    public func onPayload(_ data: Data) async {
        // panes_state is server-pushed; clients should not send payload
        // frames. Silently drop — a future PR may reply with an error
        // frame, but at this scope ignore-and-continue is correct.
    }

    public func onClose() async {
        teardown()
    }

    public func onError(_ code: String, message: String) async {
        teardown()
    }

    private func teardown() {
        cancellable?()
        cancellable = nil
        outbox = nil
        channelID = nil
    }

    private func send(snapshot: Snapshot) async {
        guard let outbox, let channelID else { return }
        let envelope = PanesStateMessage.snapshot(snapshot)
        let body: Data
        do {
            body = try JSONEncoder().encode(envelope)
        } catch {
            return
        }
        try? await outbox.send(.payload(ChannelPayload(id: channelID), body))
    }
}
