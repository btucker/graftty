#if canImport(CryptoKit)
import CryptoKit
#else
@preconcurrency import Crypto
#endif
import Foundation
import GrafttyProtocol
import NIOCore
import NIOConcurrencyHelpers
import NIOPosix
import NIOSSH
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
#if canImport(Network)
import Network
import GrafttyTunnel
#endif

/// A pinned, key-authenticated Graftty SSH connection over TCP or provider proxy streams.
public actor DirectSSHHostConnection {
    public typealias State = RemoteHostConnectionState
    public private(set) var state: State = .idle
    private let clientKey: Curve25519.Signing.PrivateKey
    private let expectedHostFingerprint: RemoteIdentityFingerprint
    private var channel: Channel?
    private var handlerBox: DirectSSHHandlerBox?
    private var onStateChange: (@Sendable (State) -> Void)?

    public init(clientKey: Curve25519.Signing.PrivateKey, expectedHostFingerprint: RemoteIdentityFingerprint) {
        self.clientKey = clientKey
        self.expectedHostFingerprint = expectedHostFingerprint
    }
    public func setOnStateChange(_ handler: (@Sendable (State) -> Void)?) { onStateChange = handler }

    public func connect(host: String, port: Int = 8801) async throws {
        guard !host.isEmpty, (1...65535).contains(port) else { throw ConnectionError.invalidEndpoint }
        try await connect(transport: .tcp(host, port))
    }

    /// Duplicates the proxy handles. The caller owns its process and original
    /// handles; this connection closes only the duplicates, including on failure.
    public func connect(input: FileHandle, output: FileHandle) async throws {
        try await connect(transport: .pipes(input, output))
    }

    private enum Transport { case tcp(String, Int), pipes(FileHandle, FileHandle) }

    private func connect(transport: Transport) async throws {
        guard state == .idle else { throw ConnectionError.notIdle }
        try Task.checkCancellation()
        setState(.connecting)
        let key = clientKey
        let fingerprint = expectedHostFingerprint
        do {
            let initialize: @Sendable (Channel) -> EventLoopFuture<Void> = { channel in
                // TCP Happy Eyeballs may initialize several channels. Each
                // transport owns its authentication state until it wins.
                let waiter = SSHReplyWaiter<Void>()
                let handler = SSHClientSetup.makeHandler(clientKey: key, expectedHostFingerprint: fingerprint,
                    allocator: channel.allocator,
                    onAuthenticationRejected: { waiter.finish(.failure(ConnectionError.authenticationRejected)) })
                channel.closeFuture.whenComplete { _ in waiter.finish(.failure(ChannelError.ioOnClosedChannel)) }
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(handler)
                    try channel.pipeline.syncOperations.addHandler(DirectSSHAuthenticationHandler(waiter: waiter, handlerBox: DirectSSHHandlerBox(handler)))
                }
            }
            let channel: Channel
            switch transport {
            case .tcp(let host, let port):
                channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                    .connectTimeout(.seconds(10))
                    .channelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
                    .channelInitializer(initialize).connect(host: host, port: port).get()
            case .pipes(let input, let output):
                let reader = fcntl(input.fileDescriptor, F_DUPFD_CLOEXEC, 0)
                guard reader >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                let writer = fcntl(output.fileDescriptor, F_DUPFD_CLOEXEC, 0)
                guard writer >= 0 else { closeDescriptor(reader); throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                let initialized = NIOLockedValueBox(false)
                do {
                    channel = try await NIOPipeBootstrap(group: MultiThreadedEventLoopGroup.singleton).channelInitializer { channel in
                        initialized.withLockedValue { $0 = true }
                        return initialize(channel)
                    }
                        .takingOwnershipOfDescriptors(input: reader, output: writer).get()
                } catch {
                    // Descriptor validation/construction failures retain caller
                    // ownership. Once initialized, NIO closes the channel on a
                    // pipeline or registration failure. Do not close reused FDs.
                    if !initialized.withLockedValue({ $0 }) {
                        closeDescriptor(reader); closeDescriptor(writer)
                    }
                    throw error
                }
            }
            self.channel = channel
            guard !state.isTerminal else { throw CancellationError() }
            let authentication = try await channel.pipeline.handler(type: DirectSSHAuthenticationHandler.self).get()
            handlerBox = authentication.handlerBox
            channel.closeFuture.whenComplete { [weak self] _ in Task { await self?.transportClosed() } }
            try await authentication.waiter.wait(timeout: .seconds(10), timeoutError: ConnectionError.timedOut,
                                  onAbort: { channel.close(promise: nil) }, start: {})
            try Task.checkCancellation()
            guard !state.isTerminal, channel.isActive else { throw ChannelError.ioOnClosedChannel }
            setState(.connected)
        } catch {
            setState(.failed(reason: String(describing: error)))
            await disposeTransport()
            throw error
        }
    }

    public func makePanesStateClient(
        onSnapshot: @escaping @Sendable ([WorktreePanes]) async -> Void,
        onClosed: @escaping @Sendable (String) async -> Void,
        originAware: Bool = false, requestReply: Bool = false
    ) throws -> PanesStateChannelClient {
        try makePanesStateClient(onSnapshot: onSnapshot, onClosed: onClosed,
            originAware: originAware, requestReply: requestReply, onSidebarSnapshot: { _ in })
    }

    func makePanesStateClient(
        onSnapshot: @escaping @Sendable ([WorktreePanes]) async -> Void,
        onClosed: @escaping @Sendable (String) async -> Void,
        originAware: Bool = false, requestReply: Bool = false,
        onSidebarSnapshot: @escaping @Sendable (SidebarSnapshot?) async -> Void
    ) throws -> PanesStateChannelClient {
        let (channel, handler) = try connectedTransport()
        return PanesStateChannelClient(parentChannel: channel, parentHandler: handler.handler,
            subsystemName: originAware ? SSHChannelTypeNames.panesStateV2 : SSHChannelTypeNames.panesState,
            requestReply: requestReply, onSnapshot: onSnapshot, onClosed: onClosed, onSidebarSnapshot: onSidebarSnapshot)
    }
    public func makeChromeTabClient() throws -> ChromeTabChannelClient {
        let (channel, handler) = try connectedTransport()
        return ChromeTabChannelClient(parentChannel: channel, parentHandler: handler.handler)
    }

    public func makePaneControlClient() throws -> PaneControlChannelClient {
        let (channel, handler) = try connectedTransport()
        return PaneControlChannelClient(parentChannel: channel, parentHandler: handler.handler)
    }
    public func makeWorktreeManagementClient() throws -> WorktreeManagementChannelClient {
        let (channel, handler) = try connectedTransport()
        return WorktreeManagementChannelClient(parentChannel: channel, parentHandler: handler.handler)
    }
    public func makeMCPControlClient(handler: @escaping TeamRPCSession.Handler,
                                     onClose: @escaping @Sendable () async -> Void = {}) throws -> TeamChannelClient {
        let (channel, ssh) = try connectedTransport()
        return TeamChannelClient(parentChannel: channel, parentHandler: ssh.handler,
            subsystemName: SSHChannelTypeNames.mcpControl, handler: handler, onClose: onClose)
    }
    public func makeGitControlClient(handler: @escaping TeamRPCSession.Handler,
                                     onClose: @escaping @Sendable () async -> Void = {}) throws -> TeamChannelClient {
        let (channel, ssh) = try connectedTransport()
        return TeamChannelClient(parentChannel: channel, parentHandler: ssh.handler,
            subsystemName: SSHChannelTypeNames.gitControl, handler: handler, onClose: onClose)
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
    public func openBrowserTunnel(_ socket: NWConnection, host: String, port: Int,
                                  handshakeReply: Data = BrowserProxy.socksSuccessReply) async throws {
        let (parent, handler) = try connectedTransport()
        _ = try await SSHSocketTransport(parent: parent, handler: handler.handler)
            .bridge(socket, host: host, port: port, handshakeReply: handshakeReply)
    }

    public func forwardLocalPort(host: String, port: Int) async throws -> LocalPortForward {
        let (parent, handler) = try connectedTransport()
        return try await LocalPortForward.start(transport: SSHSocketTransport(parent: parent, handler: handler.handler),
                                                host: host, port: port)
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
        try? await channel?.close().get()
    }
    /// The event loop serving the SSH transport, once TCP is connected.
    var transportEventLoopForTesting: (any EventLoop)? { channel?.eventLoop }
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
    let handlerBox: DirectSSHHandlerBox
    init(waiter: SSHReplyWaiter<Void>, handlerBox: DirectSSHHandlerBox) {
        self.waiter = waiter
        self.handlerBox = handlerBox
    }
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

private func closeDescriptor(_ descriptor: Int32) {
    #if canImport(Darwin)
    _ = Darwin.close(descriptor)
    #else
    _ = Glibc.close(descriptor)
    #endif
}
