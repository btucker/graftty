import Foundation
import GrafttyProtocol

/// Server-side handler for the `terminal` channel. Reads the
/// `TerminalChannelOpenMeta` JSON from the first inbound payload
/// frame (a one-time handshake) and treats every subsequent payload
/// frame as raw PTY bytes.
///
/// NOTE: the wire spec carries `sessionName` in `ChannelOpen.metadata`,
/// but the M1.4 framing layer doesn't currently surface open metadata
/// to handlers (`ChannelHandler.onOpen` receives only `id` and `outbox`).
/// M2a accepts that gap and uses the first payload frame as the carrier.
/// A future PR can extend `onOpen` to surface metadata directly.
public actor TerminalChannelHandler: ChannelHandler {
    public nonisolated let channelType = "terminal"

    public enum HandlerError: Error, Sendable {
        case sessionNotFound(String)
    }

    private enum State {
        case awaitingAttach
        case attached(stream: TerminalByteStream, outboundTask: Task<Void, Never>)
        case closed
    }

    private let factory: TerminalByteStreamFactory
    private var outbox: ChannelOutbox?
    private var channelID: ChannelID?
    private var state: State = .awaitingAttach

    public init(factory: @escaping TerminalByteStreamFactory) {
        self.factory = factory
    }

    public func onOpen(_ id: ChannelID, outbox: ChannelOutbox) async {
        self.outbox = outbox
        self.channelID = id
    }

    public func onPayload(_ data: Data) async {
        switch state {
        case .awaitingAttach:
            await handleAttach(data)
        case .attached(let stream, _):
            // Post-attach: every payload is raw PTY bytes. A second
            // attach-looking JSON blob is intentionally forwarded as raw
            // bytes (the PTY consumer treats it as garbled input — we
            // don't try to detect or filter, since a benign attach-shaped
            // byte pattern in legitimate output would also trigger).
            try? await stream.send(data)
        case .closed:
            break
        }
    }

    public func onClose() async {
        await teardown()
    }

    public func onError(_ code: String, message: String) async {
        await teardown()
    }

    private func handleAttach(_ data: Data) async {
        guard let outbox, let channelID else { return }
        let meta: TerminalChannelOpenMeta
        do {
            meta = try JSONDecoder().decode(TerminalChannelOpenMeta.self, from: data)
        } catch {
            try? await outbox.send(.error(ChannelError(
                id: channelID,
                code: "malformed-attach",
                message: "first frame must be TerminalChannelOpenMeta JSON"
            )))
            state = .closed
            return
        }
        let stream: TerminalByteStream
        do {
            stream = try await factory(meta.sessionName)
        } catch {
            try? await outbox.send(.error(ChannelError(
                id: channelID,
                code: "attach-failed",
                message: String(describing: error)
            )))
            state = .closed
            return
        }
        let outboundTask = Task { [weak self] in
            for await bytes in stream.inboundBytes {
                await self?.forwardOutbound(bytes)
            }
        }
        state = .attached(stream: stream, outboundTask: outboundTask)
    }

    private func forwardOutbound(_ bytes: Data) async {
        guard case .attached = state, let outbox, let channelID else { return }
        try? await outbox.send(.payload(ChannelPayload(id: channelID), bytes))
    }

    private func teardown() async {
        // Close first to finish the continuation (per `TerminalByteStream.close()`
        // contract); `task.cancel()` after is a safety net for a non-compliant
        // conformer. The state mutation below races safely — `forwardOutbound`
        // re-checks `guard case .attached = state` before each send.
        if case .attached(let stream, let task) = state {
            await stream.close()
            task.cancel()
        }
        state = .closed
        outbox = nil
        channelID = nil
    }
}
