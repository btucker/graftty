import Foundation
import NIO

public enum HostAdminRequest: Codable, Sendable, Equatable {
    case status
    case registerRepository(path: String)
    case pairingStatus
    case confirmPairing(code: String)
    case cancelPairing
}

public struct HostStatus: Codable, Sendable, Equatable {
    public let running: Bool
    public let socketPath: String
    public let stateDirectory: String
    public let repositoryCount: Int
    public let paneCount: Int
    public let sshPort: Int
    public let httpPort: Int
    public init(running: Bool, configuration: HostConfiguration, repositoryCount: Int, paneCount: Int) {
        self.running = running; socketPath = configuration.socketPath
        stateDirectory = configuration.stateDirectory.path
        self.repositoryCount = repositoryCount; self.paneCount = paneCount
        sshPort = configuration.sshPort; httpPort = configuration.httpPort
    }
}

public enum HostAdminResponse: Codable, Sendable, Equatable {
    case status(HostStatus)
    case repository(RepoEntry)
    case error(String)
    case pairing(displayName: String, code: String)
    case ok
}

/// Private Unix-domain transport for executable administration. The ordinary
/// graftty CLI continues to use SocketServer's existing wire protocol.
public final class HostAdministrationServer {
    public typealias Handler = @Sendable (HostAdminRequest) async -> HostAdminResponse
    private let socketPath: String
    private let handler: Handler
    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?
    public init(configuration: HostConfiguration, handler: @escaping Handler) {
        socketPath = Self.socketPath(configuration: configuration)
        self.handler = handler
    }
    public static func socketPath(configuration: HostConfiguration) -> String {
        configuration.runtimeDirectory.appendingPathComponent("host-admin.sock").path
    }
    public func start() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let handler = handler
        do {
            channel = try ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(HostLineDecoder(maxLength: 65536)))
                        try channel.pipeline.syncOperations.addHandler(RequestHandler(handler: handler))
                    }
                }
                .bind(unixDomainSocketPath: socketPath, cleanupExistingSocketFile: true).wait()
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: socketPath)
            self.group = group
        } catch {
            try? channel?.close().wait()
            channel = nil
            try? group.syncShutdownGracefully()
            throw error
        }
    }
    public func stop() {
        try? channel?.close().wait(); channel = nil
        try? group?.syncShutdownGracefully(); group = nil
        try? FileManager.default.removeItem(atPath: socketPath)
    }
    public static func request(_ request: HostAdminRequest, configuration: HostConfiguration) async throws -> HostAdminResponse {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let response = group.next().makePromise(of: HostAdminResponse.self)
        var channel: Channel?
        do {
            channel = try await ClientBootstrap(group: group)
                .connectTimeout(.seconds(5))
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(HostLineDecoder(maxLength: 1048576)))
                        try channel.pipeline.syncOperations.addHandler(ResponseHandler(response: response))
                    }
                }.connect(unixDomainSocketPath: socketPath(configuration: configuration)).get()
            let timeout = group.next().scheduleTask(in: .seconds(35)) { response.fail(HostRuntimeError.invalid("host administration timed out")) }
            defer { timeout.cancel() }
            var data = try JSONEncoder().encode(request); data.append(10)
            try await channel?.writeAndFlush(channel!.allocator.buffer(bytes: data)).get()
            let result = try await response.futureResult.get()
            try await channel?.close().get()
            try await group.shutdownGracefully()
            return result
        } catch {
            try? await channel?.close().get()
            try? await group.shutdownGracefully()
            throw error
        }
    }

    private final class RequestHandler: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        private let handler: Handler
        private var received = false
        init(handler: @escaping Handler) { self.handler = handler }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            guard !received else { return }
            received = true
            let payload = Data(unwrapInboundIn(data).readableBytesView)
            guard let request = try? JSONDecoder().decode(HostAdminRequest.self, from: payload) else {
                context.close(promise: nil); return
            }
            let channel = context.channel
            Task { [handler] in
                let response = await handler(request)
                guard var bytes = try? JSONEncoder().encode(response) else { channel.close(promise: nil); return }
                bytes.append(10)
                try? await channel.writeAndFlush(channel.allocator.buffer(bytes: bytes)).get()
                try? await channel.close().get()
            }
        }
        func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
    }

    private final class ResponseHandler: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        private let response: EventLoopPromise<HostAdminResponse>
        private var completed = false
        init(response: EventLoopPromise<HostAdminResponse>) { self.response = response }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            guard !completed else { return }
            completed = true
            do { response.succeed(try JSONDecoder().decode(HostAdminResponse.self, from: Data(unwrapInboundIn(data).readableBytesView))) }
            catch { response.fail(error) }
        }
        func channelInactive(context: ChannelHandlerContext) {
            if !completed { completed = true; response.fail(HostRuntimeError.invalid("host closed administration socket")) }
        }
        func errorCaught(context: ChannelHandlerContext, error: Error) {
            if !completed { completed = true; response.fail(error) }
            context.close(promise: nil)
        }
    }
}

private struct HostLineDecoder: ByteToMessageDecoder {
    typealias InboundOut = ByteBuffer
    let maxLength: Int
    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        if let newline = buffer.readableBytesView.firstIndex(of: 10) {
            let count = newline - buffer.readerIndex
            guard count <= maxLength else { throw HostRuntimeError.invalid("administration frame too large") }
            if let frame = buffer.readSlice(length: count) { context.fireChannelRead(wrapInboundOut(frame)) }
            buffer.moveReaderIndex(forwardBy: 1)
            return .continue
        }
        guard buffer.readableBytes <= maxLength else { throw HostRuntimeError.invalid("administration frame too large") }
        return .needMoreData
    }
}
