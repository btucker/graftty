#if canImport(CryptoKit)
import CryptoKit
#else
@preconcurrency import Crypto
#endif
import Foundation
import GrafttyProtocol
import NIOCore
import NIOPosix
import NIOSSH
#if canImport(Network)
import Network
import GrafttyTunnel
#endif

/// A pinned, key-authenticated Graftty SSH connection over TCP.
public actor DirectSSHHostConnection {
    public typealias State = RemoteHostConnectionState
    public private(set) var state: State = .idle
    private let clientKey: Curve25519.Signing.PrivateKey
    private let expectedHostFingerprint: RemoteIdentityFingerprint
    private var channel: Channel?
    private var handlerBox: DirectSSHHandlerBox?
    private var group: MultiThreadedEventLoopGroup?
    private var onStateChange: (@Sendable (State) -> Void)?

    public init(clientKey: Curve25519.Signing.PrivateKey, expectedHostFingerprint: RemoteIdentityFingerprint) {
        self.clientKey = clientKey
        self.expectedHostFingerprint = expectedHostFingerprint
    }
    public func setOnStateChange(_ handler: (@Sendable (State) -> Void)?) { onStateChange = handler }

    public func connect(host: String, port: Int = 8801) async throws {
        guard state == .idle else { throw ConnectionError.notIdle }
        guard !host.isEmpty, (1...65535).contains(port) else { throw ConnectionError.invalidEndpoint }
        try Task.checkCancellation()
        setState(.connecting)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group
        let key = clientKey
        let fingerprint = expectedHostFingerprint
        let waiter = SSHReplyWaiter<Void>()
        let slot = DirectSSHHandlerSlot()
        var connectingChannel: Channel?
        do {
            let channel = try await ClientBootstrap(group: group)
                .connectTimeout(.seconds(10))
                .channelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
                .channelInitializer { channel in
                    let handler = SSHClientSetup.makeHandler(clientKey: key, expectedHostFingerprint: fingerprint,
                        allocator: channel.allocator,
                        onAuthenticationRejected: { waiter.finish(.failure(ConnectionError.authenticationRejected)) })
                    slot.set(DirectSSHHandlerBox(handler))
                    channel.closeFuture.whenComplete { _ in waiter.finish(.failure(ChannelError.ioOnClosedChannel)) }
                    return channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(handler)
                        try channel.pipeline.syncOperations.addHandler(DirectSSHAuthenticationHandler(waiter: waiter))
                    }
                }.connect(host: host, port: port).get()
            connectingChannel = channel
            guard !state.isTerminal else { throw CancellationError() }
            self.channel = channel
            handlerBox = slot.get()
            channel.closeFuture.whenComplete { [weak self] _ in Task { await self?.transportClosed() } }
            try await waiter.wait(timeout: .seconds(10), timeoutError: ConnectionError.timedOut,
                                  onAbort: { channel.close(promise: nil) }, start: {})
            try Task.checkCancellation()
            guard !state.isTerminal, channel.isActive else { throw ChannelError.ioOnClosedChannel }
            setState(.connected)
        } catch {
            setState(.failed(reason: String(describing: error)))
            try? await connectingChannel?.close().get()
            await disposeTransport()
            throw error
        }
    }

    public func makePanesStateClient(
        onSnapshot: @escaping @Sendable ([WorktreePanes]) async -> Void,
        onClosed: @escaping @Sendable (String) async -> Void,
        originAware: Bool = false, requestReply: Bool = false
    ) throws -> PanesStateChannelClient {
        let (channel, handler) = try connectedTransport()
        return PanesStateChannelClient(parentChannel: channel, parentHandler: handler.handler,
            subsystemName: originAware ? SSHChannelTypeNames.panesStateV2 : SSHChannelTypeNames.panesState,
            requestReply: requestReply, onSnapshot: onSnapshot, onClosed: onClosed)
    }
    public func makePaneControlClient() throws -> PaneControlChannelClient {
        let (channel, handler) = try connectedTransport()
        return PaneControlChannelClient(parentChannel: channel, parentHandler: handler.handler)
    }
    public func makeWorktreeManagementClient() throws -> WorktreeManagementChannelClient {
        let (channel, handler) = try connectedTransport()
        return WorktreeManagementChannelClient(parentChannel: channel, parentHandler: handler.handler)
    }
    public func makeTeamClient(handler: @escaping @Sendable (Data) async -> Data,
                               onClose: @escaping @Sendable () async -> Void) throws -> TeamChannelClient {
        let (channel, ssh) = try connectedTransport()
        return TeamChannelClient(parentChannel: channel, parentHandler: ssh.handler, handler: handler, onClose: onClose)
    }
    public func openTerminalSession(sessionName: String, preferPaged: Bool = false) async throws -> TerminalSessionClient {
        let (channel, handler) = try connectedTransport()
        if preferPaged {
            let paged = TerminalSessionClient(parentChannel: channel, parentHandler: handler.handler, sessionName: sessionName)
            do { try await paged.connect(paged: true); return paged }
            catch TerminalSessionClient.ClientError.pagingUnsupported { paged.close() }
            catch { paged.close(); throw error }
        }
        let client = TerminalSessionClient(parentChannel: channel, parentHandler: handler.handler, sessionName: sessionName)
        do { try await client.connect(); return client }
        catch { client.close(); throw error }
    }

    /// Opens a host-side TCP destination after the host checks the peer's tunnel capability.
    public func openTCPChannel(host: String, port: Int,
        initializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) async throws -> Channel {
        guard !host.isEmpty, (1...65535).contains(port) else { throw ConnectionError.invalidEndpoint }
        let (parent, handler) = try connectedTransport()
        return try await openChildChannel(parentChannel: parent, parentHandler: handler.handler,
            channelType: .directTCPIP(.init(targetHost: host, targetPort: port,
                originatorAddress: try SocketAddress(ipAddress: "127.0.0.1", port: 0))), closeParentOnTimeout: false
        ) { child, _ in initializer(child) }
    }

    #if canImport(Network)
    public func openBrowserTunnel(_ socket: NWConnection, host: String, port: Int) async throws {
        let bridge = SSHTCPBridge(connection: socket, startsConnection: false)
        let child = try await openTCPChannel(host: host, port: port) { child in
            child.setOption(ChannelOptions.autoRead, value: false).flatMap { child.pipeline.addHandler(bridge) }
        }
        do {
            try await BrowserProxy.send(Data([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]), to: socket)
            try await child.eventLoop.submit { bridge.activate() }.get()
        } catch { child.close(promise: nil); throw error }
    }
    #endif

    public func close() async { setState(.closed); await disposeTransport() }
    private func transportClosed() async {
        // Negotiation owns failure reporting until it has returned successfully.
        guard state == .connected else { return }
        setState(.closed)
        await disposeTransport()
    }
    private func disposeTransport() async {
        let channel = channel; self.channel = nil; handlerBox = nil
        let group = group; self.group = nil
        try? await channel?.close().get()
        try? await group?.shutdownGracefully()
    }
    private func connectedTransport() throws -> (Channel, DirectSSHHandlerBox) {
        guard state == .connected, let channel, channel.isActive, let handlerBox else { throw ConnectionError.notConnected }
        return (channel, handlerBox)
    }
    private func setState(_ next: State) {
        guard !state.isTerminal, state != next else { return }
        state = next; onStateChange?(next)
    }
    public enum ConnectionError: Error { case notIdle, invalidEndpoint, notConnected, timedOut, authenticationRejected }
}

private final class DirectSSHAuthenticationHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
    let waiter: SSHReplyWaiter<Void>
    init(waiter: SSHReplyWaiter<Void>) { self.waiter = waiter }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent { waiter.finish(.success(())) }
        context.fireUserInboundEventTriggered(event)
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        waiter.finish(.failure(error)); context.close(promise: nil)
    }
}
private final class DirectSSHHandlerBox: @unchecked Sendable {
    let handler: NIOSSHHandler
    init(_ handler: NIOSSHHandler) { self.handler = handler }
}
private final class DirectSSHHandlerSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var box: DirectSSHHandlerBox?
    func set(_ box: DirectSSHHandlerBox) { lock.withLock { self.box = box } }
    func get() -> DirectSSHHandlerBox? { lock.withLock { box } }
}
