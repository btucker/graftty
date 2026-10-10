#if canImport(Network)
import Foundation
import Network
import NIOCore
import NIOSSH
import GrafttyTunnel

/// Owns a loopback TCP listener forwarding to one fixed destination on a paired host.
public final class LocalPortForward: Sendable {
    public let localPort: UInt16
    private let listener: LocalForwardListener

    private init(localPort: UInt16, listener: LocalForwardListener) {
        self.localPort = localPort
        self.listener = listener
    }
    public func stop() { listener.stop() }
    deinit { listener.stop() }

    static func start(transport: SSHSocketTransport, host: String, port: Int) async throws -> LocalPortForward {
        try Task.checkCancellation()
        // Verify host policy and target reachability before the caller opens a browser.
        let probe = try await transport.openChannel(host: host, port: port) { child in
            child.setOption(ChannelOptions.autoRead, value: false)
        }
        try? await probe.close().get()
        try Task.checkCancellation()
        let listener = try LocalForwardListener { socket in
            try await transport.bridge(socket, host: host, port: port, socksReply: false)
        }
        transport.parent.closeFuture.whenComplete { [weak listener] _ in listener?.stop() }
        do {
            let port = try await listener.start()
            try Task.checkCancellation()
            guard transport.parent.isActive else { throw ChannelError.ioOnClosedChannel }
            return LocalPortForward(localPort: port, listener: listener)
        } catch { listener.stop(); throw error }
    }
}

/// NIOSSHHandler is accessed by openChildChannel only on its parent's event loop.
struct SSHSocketTransport: @unchecked Sendable {
    let parent: Channel
    let handler: NIOSSHHandler

    func openChannel(host: String, port: Int,
                     initializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>) async throws -> Channel {
        guard !host.isEmpty, host.utf8.count <= 253, (1...65535).contains(port) else {
            throw ChannelError.inappropriateOperationForState
        }
        return try await openChildChannel(parentChannel: parent, parentHandler: handler,
            channelType: .directTCPIP(.init(targetHost: host, targetPort: port,
                originatorAddress: try SocketAddress(ipAddress: "127.0.0.1", port: 0))),
            closeParentOnTimeout: false) { child, _ in initializer(child) }
    }

    func bridge(_ socket: NWConnection, host: String, port: Int, socksReply: Bool) async throws -> Channel {
        let bridge = SSHTCPBridge(connection: socket, startsConnection: false)
        let child = try await openChannel(host: host, port: port) { channel in
            channel.setOption(ChannelOptions.autoRead, value: false).flatMap { channel.pipeline.addHandler(bridge) }
        }
        do {
            try Task.checkCancellation()
            if socksReply {
                try await BrowserProxy.send(Data([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]), to: socket)
            }
            try await child.eventLoop.submit { bridge.activate() }.get()
            try Task.checkCancellation()
            return child
        } catch { child.close(promise: nil); socket.cancel(); throw error }
    }
}

/// All mutable state is confined to queue; tasks return results through that queue.
private final class LocalForwardListener: @unchecked Sendable {
    private let queue = DispatchQueue(label: "graftty.local-port-forward")
    private let listener: NWListener
    private let connect: @Sendable (NWConnection) async throws -> Channel
    private var ready: CheckedContinuation<UInt16, Error>?
    private var sockets: [UUID: NWConnection] = [:]
    private var channels: [UUID: Channel] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var stopped = false

    init(connect: @escaping @Sendable (NWConnection) async throws -> Channel) throws {
        self.connect = connect
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    guard !stopped else { continuation.resume(throwing: CancellationError()); return }
                    ready = continuation
                    listener.stateUpdateHandler = { [weak self] state in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            if let port = self.listener.port {
                                self.ready?.resume(returning: port.rawValue)
                                self.ready = nil
                            }
                        case .failed(let error):
                            self.ready?.resume(throwing: error)
                            self.ready = nil
                            self.stopOnQueue()
                        case .cancelled: self.stopOnQueue()
                        default: break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] socket in
                        guard let self else { socket.cancel(); return }
                        self.accept(socket)
                    }
                    listener.start(queue: queue)
                    queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                        guard let self, self.ready != nil else { return }
                        self.ready?.resume(throwing: ChannelError.connectTimeout(.seconds(10)))
                        self.ready = nil
                        self.stopOnQueue()
                    }
                }
            }
        } onCancel: { self.stop() }
    }

    func stop() { queue.async { self.stopOnQueue() } }
    private func stopOnQueue() {
        guard !stopped else { return }
        stopped = true
        ready?.resume(throwing: CancellationError())
        ready = nil
        listener.newConnectionHandler = nil
        listener.stateUpdateHandler = nil
        listener.cancel()
        for id in Array(sockets.keys) { remove(id) }
    }

    private func remove(_ id: UUID) {
        tasks.removeValue(forKey: id)?.cancel()
        channels.removeValue(forKey: id)?.close(promise: nil)
        if let socket = sockets.removeValue(forKey: id) {
            socket.stateUpdateHandler = nil
            socket.cancel()
        }
    }

    private func accept(_ socket: NWConnection) {
        guard !stopped, sockets.count < 32 else { socket.cancel(); return }
        let id = UUID()
        sockets[id] = socket
        socket.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed: self?.remove(id)
            default: break
            }
        }
        socket.start(queue: queue)
        tasks[id] = Task { [weak self, connect] in
            do {
                let channel = try await connect(socket)
                guard let self else { channel.close(promise: nil); socket.cancel(); return }
                self.queue.async { [self] in
                    guard !self.stopped, self.sockets[id] != nil else { channel.close(promise: nil); return }
                    self.tasks[id] = nil
                    self.channels[id] = channel
                    channel.closeFuture.whenComplete { [weak self] _ in
                        guard let self else { return }
                        self.queue.async {
                            // The bridge owns graceful TCP EOF after its queued
                            // writes drain. Keep tracking the socket until then.
                            self.channels[id] = nil
                        }
                    }
                }
            } catch {
                socket.cancel()
                guard let self else { return }
                self.queue.async { self.remove(id) }
            }
        }
    }
}
#endif
