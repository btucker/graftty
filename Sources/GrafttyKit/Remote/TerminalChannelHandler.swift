import Foundation
import GrafttyProtocol

/// Server-side handler for the `terminal` channel. On open, decodes
/// the `TerminalChannelOpenMeta` from `ChannelOpen.metadata` (NOTE: the
/// router doesn't currently surface open metadata to handlers — the
/// `onOpen` signature receives only `id` and `outbox`. M2a accepts this
/// gap: the handler reads `sessionName` from the first inbound payload
/// frame as a JSON `TerminalChannelOpenMeta`, then treats subsequent
/// frames as raw PTY bytes. A future PR can extend `onOpen` to surface
/// metadata directly; in the meantime, this first-frame handshake keeps
/// the M1.4 framing layer untouched).
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
        // Cleanup order matters: we rely on `stream.close()` finishing the
        // continuation that drives `inboundBytes`, which exits the
        // `for await` in the spawned outbound task — before we nil the
        // outbox below. `task.cancel()` alone is not sufficient: cancellation
        // is only delivered at the next `await` inside the loop, and bytes
        // already in flight from `stream` could otherwise reach
        // `forwardOutbound` after `outbox` was set to nil.
        if case .attached(let stream, let task) = state {
            task.cancel()
            await stream.close()
        }
        state = .closed
        outbox = nil
        channelID = nil
    }
}
