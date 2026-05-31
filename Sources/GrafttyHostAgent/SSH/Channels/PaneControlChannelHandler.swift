import Foundation
import GrafttyProtocol
import NIOCore

/// Server-side handler for the `pane-control@graftty.dev` SSH channel.
/// Installs after `LengthPrefixedFraming.makeFrameDecoder()` and
/// `LengthPrefixedFraming.makeFramePrepender()` so each inbound and
/// outbound message is one `ByteBuffer` = one JSON envelope.
///
/// Decodes each inbound `ByteBuffer` as a `PaneControlRequest`,
/// dispatches to the injected `Mutator`, encodes the returned
/// `PaneControlResponse`, and writes it back. Concurrent in-flight RPCs
/// over the same channel are not supported at this layer — clients
/// serialise their own RPCs (parent design §8.1).
///
/// Stateless handler (no mutable state beyond the injected `Mutator`),
/// so `@unchecked Sendable` is trivially safe.
public final class PaneControlChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    public typealias InboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer

    public typealias Mutator = @Sendable (PaneControlRequest) async -> PaneControlResponse

    private let mutator: Mutator

    public init(mutator: @escaping Mutator) {
        self.mutator = mutator
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let inbound = unwrapInboundIn(data)
        let bytes = Data(inbound.readableBytesView)
        let channel = context.channel
        let loop = context.eventLoop
        let allocator = context.channel.allocator
        let mutator = self.mutator

        Task {
            let response: PaneControlResponse
            do {
                let request = try JSONDecoder().decode(PaneControlRequest.self, from: bytes)
                response = await mutator(request)
            } catch {
                response = .error(code: "malformed-request", message: String(describing: error))
            }
            guard let body = try? JSONEncoder().encode(response) else { return }
            let buf = allocator.buffer(bytes: body)
            // Marshal back to the event loop thread before writing —
            // mirrors the TerminalSessionHandler / PanesStateChannelHandler
            // pattern so EmbeddedChannel tests stay thread-safe. The channel
            // may be closed by the time this fires — writeAndFlush(..., promise: nil)
            // drops silently in that case, which is correct for RPC responses.
            loop.execute {
                channel.writeAndFlush(buf, promise: nil)
            }
        }
    }
}
