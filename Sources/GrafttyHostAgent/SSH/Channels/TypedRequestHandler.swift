import Foundation
import GrafttyProtocol
import NIOCore

/// A response type that can report a request frame which failed to decode.
public protocol MalformedRequestResponse: Encodable, Sendable {
    static func malformedRequest(_ error: any Error) -> Self
}

/// Server-side request/response endpoint for a framed Graftty subsystem.
/// Installs after `LengthPrefixedFraming`'s decoder and prepender, so each
/// inbound and outbound `ByteBuffer` is one JSON envelope.
///
/// Decodes each inbound frame as `Request`, awaits the injected `Mutator`,
/// and writes the encoded `Response` back. A frame that fails to decode is
/// answered with `Response.malformedRequest`. Clients serialise their own
/// RPCs (parent design §8.1); this layer answers frames as they complete.
///
/// In-flight mutator tasks are tracked on the channel's event loop and
/// cancelled when the channel goes inactive — otherwise a mutator suspended
/// on the main actor after the channel closes would still apply state
/// mutations from a dead connection. Every bookkeeping access runs on the
/// event loop, so `@unchecked Sendable` is safe.
public final class TypedRequestHandler<Request: Decodable & Sendable, Response: MalformedRequestResponse>:
    ChannelInboundHandler, @unchecked Sendable
{
    public typealias InboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer
    public typealias Mutator = @Sendable (Request) async -> Response

    private let mutator: Mutator
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var inactive = false

    public init(mutator: @escaping Mutator) {
        self.mutator = mutator
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !inactive else { return }
        let bytes = Data(unwrapInboundIn(data).readableBytesView)
        let channel = context.channel
        let loop = context.eventLoop
        let mutator = self.mutator
        let id = UUID()
        // Registered before the task can finish: the task's own removal
        // hops to this event loop, so it always runs after this insert.
        tasks[id] = Task { [weak self] in
            let body = await Self.respond(to: bytes, using: mutator)
            loop.execute {
                self?.tasks[id] = nil
                // A closed channel drops the write, which is correct for
                // an RPC response nobody is waiting for.
                if let body { channel.writeAndFlush(channel.allocator.buffer(bytes: body), promise: nil) }
            }
        }
    }

    public func channelInactive(context: ChannelHandlerContext) {
        inactive = true
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        context.fireChannelInactive()
    }

    /// The encoded response, or `nil` when the channel closed first.
    /// Cancellation is checked at each boundary so a close mid-RPC stops
    /// the mutator before it touches application state.
    private static func respond(to bytes: Data, using mutator: Mutator) async -> Data? {
        guard !Task.isCancelled else { return nil }
        let response: Response
        do {
            let request = try JSONDecoder.shared.decode(Request.self, from: bytes)
            guard !Task.isCancelled else { return nil }
            response = await mutator(request)
        } catch {
            response = .malformedRequest(error)
        }
        guard !Task.isCancelled else { return nil }
        return try? JSONEncoder.shared.encode(response)
    }
}

/// `pane-control@graftty.dev`.
public typealias PaneControlChannelHandler = TypedRequestHandler<PaneControlRequest, PaneControlResponse>

/// `worktree-management@graftty.dev`.
public typealias WorktreeManagementChannelHandler =
    TypedRequestHandler<WorktreeManagementRequest, WorktreeManagementResponse>

extension PaneControlResponse: MalformedRequestResponse {
    public static func malformedRequest(_ error: any Error) -> PaneControlResponse {
        .error(code: "malformed-request", message: String(describing: error))
    }
}

extension WorktreeManagementResponse: MalformedRequestResponse {
    public static func malformedRequest(_ error: any Error) -> WorktreeManagementResponse {
        .error(
            code: "malformed-request",
            message: String(describing: error),
            forceAllowed: false,
            shortStatus: nil
        )
    }
}
