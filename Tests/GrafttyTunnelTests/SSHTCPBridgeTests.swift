#if os(Linux)
@testable import GrafttyTunnel
import NIOCore
import NIOEmbedded
import NIOSSH
import Testing

struct SSHTCPBridgeTests {
    @Test("@spec REMOTE-20.14: When a Linux TCP tunnel receives EOF with forwarded writes pending, the application shall finish those writes before closing the destination.", arguments: [false, true])
    func eofDrainsPendingWrites(tcpToSSH: Bool) throws {
        let loop = EmbeddedEventLoop()
        let delayed = DelayedWrites()
        let destination = EmbeddedChannel(handler: delayed, loop: loop)
        let source = EmbeddedChannel(loop: loop)
        if tcpToSSH {
            try source.pipeline.syncOperations.addHandler(TCPToSSHRelay(ssh: destination))
        } else {
            try source.pipeline.syncOperations.addHandler(SSHToTCPRelay(tcp: destination))
        }
        let address = try SocketAddress(ipAddress: "127.0.0.1", port: 8080)
        try destination.connect(to: address).wait()
        try source.connect(to: address).wait()
        defer {
            delayed.completeAll()
            _ = try? source.finish()
            _ = try? destination.finish()
        }

        for text in ["response body", "last bytes"] {
            let buffer = source.allocator.buffer(string: text)
            if tcpToSSH {
                _ = try source.writeInbound(buffer)
            } else {
                _ = try source.writeInbound(SSHChannelData(type: .channel, data: .byteBuffer(buffer)))
            }
        }
        #expect(delayed.promises.count == 2)
        try source.close().wait()
        let openAfterEOF = destination.isActive
        #expect(openAfterEOF)
        delayed.completeNext()
        let openAfterFirstWrite = destination.isActive
        #expect(openAfterFirstWrite)
        delayed.completeNext()
        let closedAfterLastWrite = !destination.isActive
        #expect(closedAfterLastWrite)
    }
}

private final class DelayedWrites: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = ByteBuffer
    var promises: [EventLoopPromise<Void>] = []

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        if let promise { promises.append(promise) }
    }

    func completeNext() { promises.removeFirst().succeed(()) }
    func completeAll() { while !promises.isEmpty { completeNext() } }
}
#endif
