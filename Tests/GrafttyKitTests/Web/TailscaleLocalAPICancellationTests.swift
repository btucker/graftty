import Foundation
import Testing
import NIOCore
import NIOPosix
@testable import GrafttyKit

/// A real local daemon that accepts a request but withholds its response.
/// Event-loop barriers make cancellation observable without wall-clock sleeps.
private final class PendingLocalAPI: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let request: EventLoopPromise<Channel>
    private var received = false

    init(request: EventLoopPromise<Channel>) { self.request = request }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if !received {
            received = true
            request.succeed(context.channel)
        }
    }
}

@Suite("@spec WEB-1.16: When a LocalAPI request is cancelled, the application shall close its transport and finish with cancellation without waiting for the daemon's status, whois, or certificate receive timeout, while keeping socket I/O off the main actor and cooperative executor.")
struct TailscaleLocalAPICancellationTests {
    @Test(arguments: ["status", "whois", "cert"], ["tcp", "unix"])
    @MainActor
    func cancellationClosesPendingTransport(endpoint: String, flavor: String) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let request = group.next().makePromise(of: Channel.self)
        let opened = group.next().makePromise(of: Channel.self)
        let socketPath = "/tmp/graftty-api-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }
        let bootstrap = ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(PendingLocalAPI(request: request))
            }
        let listener: Channel
        let transport: TailscaleLocalAPI.Transport
        if flavor == "unix" {
            listener = try await bootstrap.bind(unixDomainSocketPath: socketPath).get()
            transport = .unixSocket(path: socketPath)
        } else {
            listener = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
            transport = .tcpLocalhost(port: try #require(listener.localAddress?.port), authToken: "test")
        }
        let api = TailscaleLocalAPI(transport: transport, channelOpened: { opened.succeed($0) })
        let task = Task {
            switch endpoint {
            case "status": _ = try await api.status()
            case "whois": _ = try await api.whois(peerIP: "100.64.0.1")
            default: _ = try await api.certPair(for: "host.ts.net")
            }
        }
        let peer = try await request.futureResult.get()
        let client = try await opened.futureResult.get()
        task.cancel()
        // The cancellation handler must queue the client close before returning.
        // A barrier observes that close without waiting for any daemon response.
        try await client.eventLoop.submit {}.get()
        #expect(!client.isActive, "cancellation left the receive pending")
        // Release a response even on failure so a broken cancellation handler
        // cannot strand the test behind the certificate receive timeout.
        var response = peer.allocator.buffer(capacity: 0)
        response.writeString("HTTP/1.0 503 Unavailable\r\n\r\n")
        try? await peer.writeAndFlush(response).get()
        try? await peer.close().get()
        do {
            try await task.value
            Issue.record("cancelled request succeeded")
        } catch {
            #expect(error is CancellationError, "got \(error)")
        }
        try? await listener.close().get()
        try await group.shutdownGracefully()
    }

    @Test @MainActor
    func cancellationBeforeStartDoesNotOpenAChannel() async {
        let api = TailscaleLocalAPI(transport: .unixSocket(path: "/unused"), channelOpened: { _ in
            Issue.record("pre-cancelled request opened a transport")
        })
        let task = Task { try await api.status() }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
}
