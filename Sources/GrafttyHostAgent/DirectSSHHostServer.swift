#if canImport(CryptoKit)
import CryptoKit
#else
@preconcurrency import Crypto
#endif
import Foundation
import GrafttyKit
import GrafttyProtocol
import NIOCore
import NIOPosix

/// Accepts Graftty SSH sessions directly over TCP. This is separate from OpenSSH.
public actor DirectSSHHostServer {
    public static let defaultPort = 8801
    public nonisolated let activeRemotePeers: ActiveRemotePeerRegistry
    private let hostKey: Curve25519.Signing.PrivateKey
    private let trustedPeerStore: TrustedPeerStore
    private let sshConnectionRegistry: SSHConnectionRegistry
    private var configuration: SSHHostSessionConfiguration
    private var listener: Channel?
    private var group: MultiThreadedEventLoopGroup?
    private var connections: DirectSSHConnections?
    private var starting = false
    private var generation: UInt64 = 0

    public init(
        hostKey: Curve25519.Signing.PrivateKey,
        trustedPeerStore: TrustedPeerStore,
        activeRemotePeers: ActiveRemotePeerRegistry = ActiveRemotePeerRegistry(),
        streamFactory: @escaping @Sendable (String) async throws -> TerminalByteStream,
        pagedFactory: PagedTerminalStreamFactory? = nil,
        panesStateSubscribe: @escaping PanesStateChannelHandler.Subscribe,
        panesStateV2Subscribe: PanesStateChannelHandler.Subscribe? = nil,
        paneControlMutator: @escaping PaneControlChannelHandler.Mutator,
        worktreeManagementMutator: WorktreeManagementChannelHandler.Mutator? = nil,
        displayOwnershipStore: SessionDisplayOwnershipStore,
        sshConnectionRegistry: SSHConnectionRegistry = SSHConnectionRegistry()
    ) {
        self.hostKey = hostKey
        self.trustedPeerStore = trustedPeerStore
        self.activeRemotePeers = activeRemotePeers
        self.sshConnectionRegistry = sshConnectionRegistry
        configuration = SSHHostSessionConfiguration(
            streamFactory: streamFactory, pagedFactory: pagedFactory,
            panesStateSubscribe: panesStateSubscribe,
            panesStateV2Subscribe: panesStateV2Subscribe ?? panesStateSubscribe,
            paneControlMutator: paneControlMutator,
            worktreeManagementMutator: worktreeManagementMutator ?? { _ in
                .error(code: "unavailable", message: "worktree management is unavailable", forceAllowed: false, shortStatus: nil)
            },
            ownershipStore: displayOwnershipStore,
            ownershipBroadcaster: DisplayOwnershipBroadcaster(store: displayOwnershipStore),
            teamHandler: nil, teamOnConnect: { _, _ in }, teamOnDisconnect: { _, _ in }
        )
    }

    /// Configure messaging before starting the listener.
    public func setTeamMessaging(handler: @escaping TeamChannelHandler.Handler,
                                 onConnect: @escaping TeamChannelHandler.OnConnect,
                                 onDisconnect: @escaping TeamChannelHandler.OnDisconnect) {
        let c = configuration
        configuration = SSHHostSessionConfiguration(
            streamFactory: c.streamFactory, pagedFactory: c.pagedFactory,
            panesStateSubscribe: c.panesStateSubscribe, panesStateV2Subscribe: c.panesStateV2Subscribe,
            paneControlMutator: c.paneControlMutator, worktreeManagementMutator: c.worktreeManagementMutator,
            ownershipStore: c.ownershipStore, ownershipBroadcaster: c.ownershipBroadcaster,
            teamHandler: handler, teamOnConnect: onConnect, teamOnDisconnect: onDisconnect
        )
    }

    /// Port zero requests an ephemeral listener for loopback tests.
    @discardableResult
    public func start(host: String = "0.0.0.0", port: Int = defaultPort) async throws -> Int {
        guard listener == nil, !starting else { throw ServerError.alreadyStarted }
        guard (0...65535).contains(port) else { throw ServerError.invalidPort }
        try Task.checkCancellation()
        starting = true
        generation &+= 1
        let generation = generation
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let connections = DirectSSHConnections()
        self.group = group
        self.connections = connections
        let config = configuration
        let key = hostKey
        let store = trustedPeerStore
        let active = activeRemotePeers
        let registry = sshConnectionRegistry
        do {
            let channel = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
                .childChannelInitializer { channel in
                    guard connections.insert(channel) else {
                        return channel.eventLoop.makeFailedFuture(ChannelError.ioOnClosedChannel)
                    }
                    let session = DirectSSHSession(channel: channel, store: store, registry: registry)
                    let deadline = channel.eventLoop.scheduleTask(in: .seconds(30)) { channel.close(promise: nil) }
                    channel.closeFuture.whenComplete { _ in
                        deadline.cancel()
                        connections.remove(channel)
                        Task { await session.close() }
                    }
                    let handler = config.makeHandler(
                        channel: channel, hostKey: key, trustedPeerStore: store,
                        activeRemotePeers: active, peerBox: AuthenticatedPeerBox(),
                        closeTransport: { await session.close() },
                        onAuthenticatedPeer: { peer in
                            deadline.cancel()
                            Task { await session.register(peer: peer) }
                        }
                    )
                    return channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(handler)
                        try channel.pipeline.syncOperations.addHandler(DirectSSHErrorHandler())
                    }
                }.bind(host: host, port: port).get()
            try Task.checkCancellation()
            guard self.generation == generation else {
                try? await channel.close().get()
                throw CancellationError()
            }
            listener = channel
            starting = false
            guard let boundPort = channel.localAddress?.port else { throw ServerError.missingBoundPort }
            return boundPort
        } catch {
            if self.generation == generation { await close() }
            throw error
        }
    }

    public func close() async {
        generation &+= 1
        starting = false
        let listener = listener
        self.listener = nil
        let group = group
        self.group = nil
        let connections = connections
        self.connections = nil
        // Stop admission synchronously before waiting for listener shutdown.
        let channels = connections?.stop() ?? []
        try? await listener?.close().get()
        for channel in channels { try? await channel.close().get() }
        try? await group?.shutdownGracefully()
    }

    public enum ServerError: Error { case alreadyStarted, invalidPort, missingBoundPort }
}

/// Registration is scoped to one TCP channel, so a late close cannot deregister a reconnect.
private actor DirectSSHSession {
    let channel: Channel
    let store: TrustedPeerStore
    let registry: SSHConnectionRegistry
    var registration: (RemoteDeviceID, SSHConnectionRegistry.RegistrationToken)?
    var closed = false
    init(channel: Channel, store: TrustedPeerStore, registry: SSHConnectionRegistry) {
        self.channel = channel; self.store = store; self.registry = registry
    }
    func register(peer: TrustedPeer) async {
        guard !closed, channel.isActive else { return }
        let token = await registry.register(deviceID: peer.id) { [weak self] in await self?.close() }
        guard !closed, channel.isActive else {
            await registry.deregister(deviceID: peer.id, token: token)
            return
        }
        registration = (peer.id, token)
        // Revocation or capability edits may have raced the async registration.
        guard let current = try? store.get(id: peer.id), current.publicKey == peer.publicKey,
              current.capabilities.terminalControl == .allowed else {
            await close()
            return
        }
    }
    func close() async {
        guard !closed else { return }
        closed = true
        let registration = registration
        self.registration = nil
        try? await channel.close().get()
        if let (id, token) = registration { await registry.deregister(deviceID: id, token: token) }
    }
}

private final class DirectSSHConnections: @unchecked Sendable {
    private let lock = NSLock()
    private var accepting = true
    private var channels: [ObjectIdentifier: Channel] = [:]
    func insert(_ channel: Channel) -> Bool {
        lock.withLock {
            guard accepting, channels.count < 256 else { return false }
            channels[ObjectIdentifier(channel)] = channel
            return true
        }
    }
    func remove(_ channel: Channel) { _ = lock.withLock { channels.removeValue(forKey: ObjectIdentifier(channel)) } }
    func stop() -> [Channel] {
        lock.withLock {
            accepting = false
            let result = Array(channels.values)
            channels.removeAll()
            return result
        }
    }
}

private final class DirectSSHErrorHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
