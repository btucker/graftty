import Foundation
import GrafttyProtocol
import NIOCore

/// One bounded RPC at a time, with identity supplied by SSH authentication.
public final class ChromeTabChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    public typealias InboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer
    public typealias Mutator = @Sendable (ChromeTabRequest, RemoteDeviceID, UUID) async -> ChromeTabResponse
    public typealias OnDisconnect = @Sendable (UUID) async -> Void
    private let deviceID: RemoteDeviceID
    private let viewerID = UUID()
    private let mutator: Mutator
    private let onDisconnect: OnDisconnect
    // These properties are confined to the channel event loop.
    private var task: Task<Void, Never>?
    private var inactive = false

    public init(deviceID: RemoteDeviceID, mutator: @escaping Mutator, onDisconnect: @escaping OnDisconnect) {
        self.deviceID = deviceID; self.mutator = mutator; self.onDisconnect = onDisconnect
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let bytes = Data(unwrapInboundIn(data).readableBytesView)
        guard task == nil, context.channel.isWritable, bytes.count <= ChromeTabRequest.maximumRequestBytes,
              let request = try? JSONDecoder().decode(ChromeTabRequest.self, from: bytes) else {
            context.close(promise: nil); return
        }
        let channel = context.channel
        task = Task { [mutator, deviceID, viewerID] in
            let response = await mutator(request, deviceID, viewerID)
            guard !Task.isCancelled, let body = try? response.encoded(), body.count <= ChromeTabRequest.maximumResponseBytes else {
                channel.close(promise: nil); return
            }
            channel.eventLoop.execute { [self] in
                guard !inactive, channel.isWritable else { channel.close(promise: nil); return }
                channel.writeAndFlush(channel.allocator.buffer(bytes: body)).whenComplete { [self] result in
                    task = nil
                    if case .failure = result { channel.close(promise: nil) }
                }
            }
        }
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }

    public func channelInactive(context: ChannelHandlerContext) {
        inactive = true; task?.cancel(); task = nil
        Task { [onDisconnect, viewerID] in await onDisconnect(viewerID) }
        context.fireChannelInactive()
    }
}
