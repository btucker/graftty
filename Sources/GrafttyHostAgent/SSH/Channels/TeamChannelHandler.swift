import Foundation
import GrafttyProtocol
import NIOCore

/// Serves requests and permits the host to originate requests on the same channel.
public final class TeamChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    public typealias InboundIn = ByteBuffer
    public typealias Handler = @Sendable (RemoteDeviceID, Data) async -> Data
    public typealias OnConnect = @Sendable (RemoteDeviceID, TeamRPCSession) async -> Void
    public typealias OnDisconnect = @Sendable (RemoteDeviceID, UUID) async -> Void

    private let deviceID: RemoteDeviceID
    private let handler: Handler
    private let onConnect: OnConnect
    private let onDisconnect: OnDisconnect
    private var session: TeamRPCSession?
    private var registration: Task<Void, Never>?

    public init(deviceID: RemoteDeviceID, handler: @escaping Handler, onConnect: @escaping OnConnect, onDisconnect: @escaping OnDisconnect) {
        self.deviceID = deviceID
        self.handler = handler
        self.onConnect = onConnect
        self.onDisconnect = onDisconnect
    }

    public func handlerAdded(context: ChannelHandlerContext) {
        let channel = context.channel
        let registered = context.eventLoop.makePromise(of: Void.self)
        let session = TeamRPCSession(handler: { [handler, deviceID] bytes in
            // Gate requests only: onConnect may itself send an RPC, whose
            // response must still reach the session during registration.
            try? await registered.futureResult.get()
            guard !Task.isCancelled else { return Data() }
            return await handler(deviceID, bytes)
        }, writer: { [weak channel] bytes in
            guard let channel, channel.isActive else { throw TeamRPCSession.SessionError.channelClosed }
            try await channel.writeAndFlush(channel.allocator.buffer(bytes: bytes)).get()
        }, onClose: { [weak channel] in
            channel?.close(promise: nil)
        })
        self.session = session
        // The dispatcher installs framing and acknowledges the subsystem
        // before this event-loop turn can start the registration callback.
        let ready = context.eventLoop.makePromise(of: Void.self)
        context.eventLoop.execute { ready.succeed(()) }
        registration = Task { [onConnect, deviceID] in
            defer { registered.succeed(()) }
            try? await ready.futureResult.get()
            guard !Task.isCancelled else { return }
            await onConnect(deviceID, session)
        }
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard let session else { return }
        let bytes = Data(unwrapInboundIn(data).readableBytesView)
        Task { await session.receive(bytes) }
    }

    public func channelInactive(context: ChannelHandlerContext) {
        if let session {
            self.session = nil
            let registration = self.registration
            registration?.cancel()
            Task { [onDisconnect, deviceID] in
                await session.close()
                await registration?.value
                await onDisconnect(deviceID, session.id)
            }
        }
        context.fireChannelInactive()
    }

    public func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}
