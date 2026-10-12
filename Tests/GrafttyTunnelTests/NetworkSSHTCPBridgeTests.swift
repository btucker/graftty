#if canImport(Network)
import Foundation
import Network
@testable import GrafttyTunnel
import NIOCore
import NIOEmbedded
import NIOSSH
import Testing

struct NetworkSSHTCPBridgeTests {
    @Test("@spec PORTS-5.9: When SSH upload writes fail with EOF after response reads, the TCP bridge shall drain the queued response before closing.", .timeLimit(.minutes(1)))
    func uploadEOFDrainsResponse() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "bridge-eof-test")
        let channel = NIOAsyncTestingChannel()
        let captured = CapturedUpload(loop: channel.eventLoop)
        try await channel.pipeline.addHandler(captured).get()
        try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).get()
        let accepted = channel.eventLoop.makePromise(of: NWConnection.self)
        listener.newConnectionHandler = { accepted.succeed($0) }
        let listening = channel.eventLoop.makePromise(of: Void.self)
        listener.stateUpdateHandler = { state in
            if case .ready = state { listening.succeed(()) }
        }
        listener.start(queue: queue)
        try await listening.futureResult.get()
        let peer = NWConnection(host: "127.0.0.1", port: listener.port!, using: .tcp)
        peer.start(queue: queue)
        let socket = try await accepted.futureResult.get()
        let bridge = SSHTCPBridge(connection: socket, startsConnection: false)
        try await channel.pipeline.addHandler(bridge).get()
        socket.start(queue: queue)
        try await channel.eventLoop.submit { bridge.activate() }.get()
        defer { peer.cancel(); socket.cancel(); listener.cancel() }
        let deadline = Task { try? await Task.sleep(for: .seconds(10)); if !Task.isCancelled { peer.cancel() } }
        defer { deadline.cancel() }
        peer.send(content: Data([1]), completion: .contentProcessed { _ in })
        try await captured.received.futureResult.get()
        let payload = Data(repeating: 0x5a, count: 8 * 1024 * 1024)
        try await channel.eventLoop.submit {
            channel.pipeline.fireChannelRead(SSHChannelData(type: .channel, data: .byteBuffer(channel.allocator.buffer(bytes: payload))))
            captured.pending?.fail(ChannelError.eof)
            channel.close(promise: nil)
        }.get()
        var response = Data()
        while true {
            let (data, ended) = await withCheckedContinuation { (continuation: CheckedContinuation<(Data, Bool), Never>) in
                peer.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                    continuation.resume(returning: (data ?? Data(), complete || error != nil))
                }
            }
            response.append(data)
            if ended { break }
        }
        #expect(response == payload)
        _ = try? await channel.finish(acceptAlreadyClosed: true)
    }
    @Test("@spec PORTS-5.10: While a TCP bridge drains queued bytes after SSH closes, its tunnel capacity slot shall remain reserved until the TCP connection terminates.", .timeLimit(.minutes(1)))
    func capacityRemainsReservedDuringDrain() async throws {
        let capacity = TunnelCapacity(limit: 1)
        let listener = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "bridge-capacity-test")
        let channel = NIOAsyncTestingChannel()
        try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).get()
        let accepted = channel.eventLoop.makePromise(of: NWConnection.self)
        listener.newConnectionHandler = { accepted.succeed($0) }
        let listening = channel.eventLoop.makePromise(of: Void.self)
        listener.stateUpdateHandler = { state in if case .ready = state { listening.succeed(()) } }
        listener.start(queue: queue)
        try await listening.futureResult.get()
        let connected = SSHTCPBridge.connect(host: "127.0.0.1", port: Int(listener.port!.rawValue), channel: channel, capacity: capacity)
        let peer = try await accepted.futureResult.get()
        peer.start(queue: queue)
        defer { peer.cancel(); listener.cancel() }
        let deadline = Task { try? await Task.sleep(for: .seconds(10)); if !Task.isCancelled { peer.cancel() } }
        defer { deadline.cancel() }
        try await connected.get()
        let payload = Data(repeating: 0x42, count: 8 * 1024 * 1024)
        try await channel.eventLoop.submit {
            channel.pipeline.fireChannelRead(SSHChannelData(type: .channel, data: .byteBuffer(channel.allocator.buffer(bytes: payload))))
            channel.close(promise: nil)
        }.get()
        try await channel.closeFuture.get()
        let prematurelyAvailable = capacity.acquire()
        if prematurelyAvailable { capacity.release() }
        #expect(!prematurelyAvailable)
        var response = Data()
        while true {
            let (data, ended) = await withCheckedContinuation { (continuation: CheckedContinuation<(Data, Bool), Never>) in
                peer.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                    continuation.resume(returning: (data ?? Data(), complete || error != nil))
                }
            }
            response.append(data)
            if ended { break }
        }
        #expect(response == payload)
        var released = false
        for _ in 0..<100 {
            if capacity.acquire() { capacity.release(); released = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(released)
        _ = try? await channel.finish(acceptAlreadyClosed: true)
    }

}

private final class CapturedUpload: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = SSHChannelData
    let received: EventLoopPromise<Void>
    var pending: EventLoopPromise<Void>?
    init(loop: EventLoop) { received = loop.makePromise(of: Void.self) }
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        pending = promise
        received.succeed(())
    }
}
#endif
