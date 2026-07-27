import Foundation
import GrafttyProtocol
import NIOConcurrencyHelpers
import NIOCore

/// Typed request/response endpoint for
/// `worktree-management@graftty.dev`.
public final class WorktreeManagementChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    public typealias InboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer
    public typealias Mutator = @Sendable (
        WorktreeManagementRequest
    ) async -> WorktreeManagementResponse

    private let mutator: Mutator
    private let lock = NIOLock()
    private var tasks: [Task<Void, Never>] = []
    private var inactive = false

    public init(mutator: @escaping Mutator) {
        self.mutator = mutator
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let bytes = Data(unwrapInboundIn(data).readableBytesView)
        let channel = context.channel
        let loop = context.eventLoop
        let allocator = channel.allocator
        let mutator = self.mutator

        let task = Task {
            guard !Task.isCancelled else { return }
            let response: WorktreeManagementResponse
            do {
                let request = try JSONDecoder().decode(
                    WorktreeManagementRequest.self,
                    from: bytes
                )
                guard !Task.isCancelled else { return }
                response = await mutator(request)
            } catch {
                response = .error(
                    code: "malformed-request",
                    message: String(describing: error),
                    forceAllowed: false,
                    shortStatus: nil
                )
            }
            guard !Task.isCancelled,
                  let body = try? JSONEncoder().encode(response) else { return }
            let buffer = allocator.buffer(bytes: body)
            loop.execute {
                channel.writeAndFlush(buffer, promise: nil)
            }
        }
        lock.withLock {
            if inactive {
                task.cancel()
            } else {
                tasks.append(task)
            }
        }
    }

    public func channelInactive(context: ChannelHandlerContext) {
        let pending = lock.withLock { () -> [Task<Void, Never>] in
            inactive = true
            let pending = tasks
            tasks.removeAll()
            return pending
        }
        pending.forEach { $0.cancel() }
        context.fireChannelInactive()
    }
}
