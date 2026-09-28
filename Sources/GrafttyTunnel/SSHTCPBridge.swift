import Foundation
import Network
import NIOCore
import NIOSSH

/// Bridges a TCP socket and one SSH direct-tcpip channel. Each direction waits
/// for its previous write before requesting more bytes.
public final class SSHTCPBridge: ChannelInboundHandler, @unchecked Sendable {
    public typealias InboundIn = SSHChannelData
    private let connection: NWConnection
    private let startsConnection: Bool
    private let ready: EventLoopPromise<Void>?
    private var readyFinished = false
    private var pendingWrites = 0
    private var pendingBytes = 0
    private var reading = false
    private var closed = false
    private var channel: Channel?
    private static let capacity = TunnelCapacity()
    private static let queue = DispatchQueue(label: "graftty.browser.tcp", attributes: .concurrent)

    public init(connection: NWConnection, startsConnection: Bool, ready: EventLoopPromise<Void>? = nil) {
        self.connection = connection
        self.startsConnection = startsConnection
        self.ready = ready
    }

    public static func connect(host: String, port: Int, channel: Channel) -> EventLoopFuture<Void> {
        guard !host.isEmpty, host.utf8.count <= 253, (1...65535).contains(port),
              let port = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return channel.eventLoop.makeFailedFuture(ChannelError.inappropriateOperationForState)
        }
        guard capacity.acquire() else {
            return channel.eventLoop.makeFailedFuture(ChannelError.inappropriateOperationForState)
        }
        channel.closeFuture.whenComplete { _ in capacity.release() }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 10
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port,
                                      using: NWParameters(tls: nil, tcp: tcp))
        let ready = channel.eventLoop.makePromise(of: Void.self)
        return channel.setOption(ChannelOptions.autoRead, value: false).flatMap {
            channel.pipeline.addHandler(SSHTCPBridge(connection: connection, startsConnection: true, ready: ready))
        }.flatMap { ready.futureResult }
    }

    public func handlerAdded(context: ChannelHandlerContext) {
        let channel = context.channel
        self.channel = channel
        if startsConnection {
            channel.eventLoop.scheduleTask(in: .seconds(10)) { [weak self] in
                guard let self, !self.readyFinished else { return }
                self.close()
            }
            connection.stateUpdateHandler = { [weak self] state in
                channel.eventLoop.execute {
                    guard let self, !self.closed else { return }
                    switch state {
                    case .ready:
                        self.finishReady(.success(()))
                        if channel.isActive { self.activate() }
                    case .failed(let error):
                        self.finishReady(.failure(error))
                        self.close()
                    case .cancelled:
                        self.close()
                    default: break
                    }
                }
            }
            connection.start(queue: Self.queue)
        }
    }

    public func channelActive(context: ChannelHandlerContext) {
        if startsConnection && readyFinished { activate() }
        context.fireChannelActive()
    }

    /// Called on the channel event loop after the local SOCKS handshake reply.
    public func activate() {
        guard !reading, !closed, let channel else { return }
        reading = true
        channel.read()
        receive()
    }

    private func receive() {
        guard !closed, let channel else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 48 * 1024) { [weak self] data, _, complete, error in
            channel.eventLoop.execute {
                guard let self, !self.closed else { return }
                if let data, !data.isEmpty {
                    let buffer = channel.allocator.buffer(bytes: data)
                    channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer))).whenComplete { result in
                        if complete || error != nil { self.close() }
                        else if case .failure = result { self.close() }
                        else { self.receive() }
                    }
                } else if complete || error != nil { self.close() }
                else { self.receive() }
            }
        }
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let value = unwrapInboundIn(data)
        guard case .channel = value.type, case .byteBuffer(let buffer) = value.data else { close(); return }
        let bytes = Data(buffer.readableBytesView)
        pendingBytes += bytes.count
        guard pendingBytes <= 1024 * 1024 else { close(); return }
        pendingWrites += 1
        let channel = context.channel
        connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
            channel.eventLoop.execute {
                guard let self, !self.closed else { return }
                self.pendingBytes -= bytes.count
                self.pendingWrites -= 1
                if error != nil { self.close() }
                else if self.pendingWrites == 0 { channel.read() }
            }
        })
    }

    public func channelInactive(context: ChannelHandlerContext) {
        close()
        context.fireChannelInactive()
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) { close() }

    private func finishReady(_ result: Result<Void, Error>) {
        guard !readyFinished else { return }
        readyFinished = true
        ready?.completeWith(result)
    }

    private func close() {
        guard !closed else { return }
        closed = true
        finishReady(.failure(ChannelError.ioOnClosedChannel))
        if startsConnection { connection.stateUpdateHandler = nil }
        connection.cancel()
        channel?.close(promise: nil)
    }
}

private final class TunnelCapacity: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    func acquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard active < 64 else { return false }
        active += 1
        return true
    }
    func release() {
        lock.lock()
        active -= 1
        lock.unlock()
    }
}
