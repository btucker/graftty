#if canImport(UIKit)
import Foundation
import GrafttyProtocol

/// Mobile-side façade for the `terminal` channel. `connect(sessionName:)`
/// opens the channel, sends the initial `TerminalChannelOpenMeta` JSON
/// as the first payload frame, then exposes `inboundBytes` (PTY output
/// from the host) and `send(_:)` (keystrokes toward the host).
///
/// This PR does not wire the client to `InMemoryTerminalSession` —
/// existing terminal panes continue using `WebSocketClient` until M1.3
/// + production wiring land.
public actor TerminalChannelClient {

    public enum ClientError: Error, Equatable, Sendable {
        case notConnected
        case alreadyConnected
        case encodeFailed(String)
    }

    private let router: ChannelRouter
    private var channelID: ChannelID?
    private var outbox: ChannelOutbox?
    private let continuation: AsyncStream<Data>.Continuation
    public nonisolated let inboundBytes: AsyncStream<Data>

    public init(router: ChannelRouter) {
        self.router = router
        var c: AsyncStream<Data>.Continuation!
        // Cap the inbound buffer. A flooding PTY with a slow consumer would
        // otherwise grow the heap without bound. 256 chunks is generous for
        // terminal output (each chunk is a single SCTP/DataChannel message,
        // typically ≤16KB). `bufferingNewest` drops oldest chunks under
        // pressure; an interactive shell prefers fresh output over stale.
        self.inboundBytes = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { c = $0 }
        self.continuation = c
    }

    public func connect(sessionName: String) async throws {
        if channelID != nil { throw ClientError.alreadyConnected }
        let handler = TerminalClientHandler(
            onOutbox: { [weak self] outbox in
                await self?.captureOutbox(outbox)
            },
            onBytes: { [weak self] bytes in
                self?.continuation.yield(bytes)
            },
            onClose: { [weak self] in
                self?.continuation.finish()
            }
        )
        let id = try await router.open(type: "terminal", handler: handler)
        self.channelID = id
        // outbox is guaranteed non-nil here: router.open awaits
        // handler.onOpen -> onOutbox -> captureOutbox before returning.
        // The handshake send below relies on this sequencing — a future
        // refactor that lets router.open return before handler.onOpen
        // completes would break this invariant silently.
        // Send the attach handshake.
        let body: Data
        do {
            body = try JSONEncoder().encode(TerminalChannelOpenMeta(sessionName: sessionName))
        } catch {
            throw ClientError.encodeFailed(String(describing: error))
        }
        guard let outbox else { throw ClientError.notConnected }
        try await outbox.send(.payload(ChannelPayload(id: id), body))
    }

    public func send(_ bytes: Data) async throws {
        guard let outbox, let channelID else { throw ClientError.notConnected }
        try await outbox.send(.payload(ChannelPayload(id: channelID), bytes))
    }

    public func close() async {
        guard let id = channelID else { return }
        channelID = nil
        outbox = nil
        try? await router.close(id)
        continuation.finish()
    }

    func captureOutbox(_ outbox: ChannelOutbox) {
        self.outbox = outbox
    }
}

private actor TerminalClientHandler: ChannelHandler {
    nonisolated let channelType = "terminal"

    private let onOutbox: @Sendable (ChannelOutbox) async -> Void
    private let onBytes: @Sendable (Data) -> Void
    private let onClose: @Sendable () -> Void

    init(
        onOutbox: @escaping @Sendable (ChannelOutbox) async -> Void,
        onBytes: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable () -> Void
    ) {
        self.onOutbox = onOutbox
        self.onBytes = onBytes
        self.onClose = onClose
    }

    func onOpen(_ id: ChannelID, outbox: ChannelOutbox) async {
        await onOutbox(outbox)
    }

    func onPayload(_ data: Data) async {
        onBytes(data)
    }

    func onClose() async {
        onClose()
    }

    func onError(_ code: String, message: String) async {
        onClose()
    }
}
#endif
