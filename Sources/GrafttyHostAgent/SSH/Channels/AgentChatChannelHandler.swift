import Foundation
import GrafttyProtocol
import NIOCore

/// Serves Chat for one agent tab to one paired viewer. The first frame names
/// the tab. The handler answers with the conversation so far, then every later
/// change in order, and relays the viewer's submissions and answers.
public final class AgentChatChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    public typealias InboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer
    /// Chat for the named tab as seen by this authenticated device.
    public typealias Opener = @Sendable (RemoteDeviceID, _ worktreePath: String, _ agentID: String) async -> AgentChatConnection

    private let deviceID: RemoteDeviceID
    private let opener: Opener
    // These properties are confined to the channel event loop.
    private var connection: AgentChatConnection?
    private var opened = false
    private var inactive = false
    private var tasks: [UUID: Task<Void, Never>] = [:]

    public init(deviceID: RemoteDeviceID, opener: @escaping Opener) {
        self.deviceID = deviceID
        self.opener = opener
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let bytes = Data(unwrapInboundIn(data).readableBytesView)
        guard bytes.count <= AgentChatClientMessage.maximumEncodedBytes,
              let message = try? JSONDecoder().decode(AgentChatClientMessage.self, from: bytes) else {
            context.close(promise: nil)
            return
        }
        let channel = context.channel
        switch message {
        case .open(let worktreePath, let agentID):
            // One channel serves one tab for its whole life.
            guard !opened else { context.close(promise: nil); return }
            opened = true
            run(on: channel) { [self, opener, deviceID] in
                let connection = await opener(deviceID, worktreePath, agentID)
                switch await connection.open() {
                case .unavailable(let reason):
                    await send(.unavailable(reason: reason), on: channel)
                case .attached(let snapshot, let updates):
                    await adopt(connection, on: channel)
                    guard await send(.snapshot(snapshot), on: channel) else { return }
                    for await update in updates {
                        guard !Task.isCancelled, await send(.update(update), on: channel) else { return }
                    }
                }
            }
        case .submit(let submission):
            let connection = connection
            run(on: channel) { [self] in
                let result = await connection?.submit(submission) ?? .rejected(.unavailable)
                await send(.submitted(submissionID: submission.submissionID, result: result), on: channel)
            }
        case .answer(let binding, let requestID, let decision):
            let connection = connection
            run(on: channel) { [self] in
                let accepted = await connection?.answer(binding, requestID, decision) ?? false
                await send(.answered(requestID: requestID, accepted: accepted), on: channel)
            }
        }
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }

    public func channelInactive(context: ChannelHandlerContext) {
        inactive = true
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        connection = nil
        context.fireChannelInactive()
    }

    /// Starts work that ends with the channel. Runs on the event loop.
    private func run(on channel: Channel, _ work: @escaping @Sendable () async -> Void) {
        let id = UUID()
        tasks[id] = Task { [self] in
            await work()
            channel.eventLoop.execute { [self] in tasks[id] = nil }
        }
    }

    private func adopt(_ connection: AgentChatConnection, on channel: Channel) async {
        try? await channel.eventLoop.submit { [self] in
            if !inactive { self.connection = connection }
        }.get()
    }

    /// Writes one frame and waits for it, so a slow viewer slows its own feed.
    @discardableResult
    private func send(_ message: AgentChatServerMessage, on channel: Channel) async -> Bool {
        guard let body = try? JSONEncoder().encode(message) else { return false }
        do {
            try await channel.eventLoop.flatSubmit { [self] () -> EventLoopFuture<Void> in
                guard !inactive else { return channel.eventLoop.makeFailedFuture(ChannelError.ioOnClosedChannel) }
                return channel.writeAndFlush(channel.allocator.buffer(bytes: body))
            }.get()
            return true
        } catch {
            channel.close(promise: nil)
            return false
        }
    }
}
