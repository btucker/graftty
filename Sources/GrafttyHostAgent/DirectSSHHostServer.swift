#if canImport(CryptoKit)
import CryptoKit
#else
@preconcurrency import Crypto
#endif
import Foundation
import GrafttyKit
import GrafttyProtocol
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public typealias AuthenticatedSkillMutator = @Sendable (RemoteSkillTransferRequest, RemoteMacConnectionSummary.ID) async -> WorktreeManagementResponse

public typealias AuthenticatedPlacementMutator = @Sendable (HostPlacementRequest, RemoteMacConnectionSummary.ID) async -> WorktreeManagementResponse

/// Accepts Graftty SSH sessions over TCP or an externally established byte stream.
/// Both transports use the same pairing, authorization, and subsystem handlers.
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
    private var streamsStarted = false
    private var generation: UInt64 = 0

    public init(
        hostKey: Curve25519.Signing.PrivateKey,
        trustedPeerStore: TrustedPeerStore,
        activeRemotePeers: ActiveRemotePeerRegistry = ActiveRemotePeerRegistry(),
        streamFactory: @escaping @Sendable (String, DisplayGrid?) async throws -> TerminalByteStream,
        pagedFactory: PagedTerminalStreamFactory? = nil,
        panesStateSubscribe: @escaping PanesStateChannelHandler.Subscribe,
        panesStateV2Subscribe: PanesStateChannelHandler.Subscribe? = nil,
        paneControlMutator: @escaping PaneControlChannelHandler.Mutator,
        worktreeManagementMutator: WorktreeManagementChannelHandler.Mutator? = nil,
        authenticatedPlacementMutator: AuthenticatedPlacementMutator? = nil,
        authenticatedSkillMutator: AuthenticatedSkillMutator? = nil,
        chromeTabMutator: ChromeTabChannelHandler.Mutator? = nil,
        chromeTabOnDisconnect: @escaping ChromeTabChannelHandler.OnDisconnect = { _ in },
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
            authenticatedPlacementMutator: authenticatedPlacementMutator, authenticatedSkillMutator: authenticatedSkillMutator,
            chromeTabMutator: chromeTabMutator, chromeTabOnDisconnect: chromeTabOnDisconnect,
            ownershipStore: displayOwnershipStore,
            ownershipBroadcaster: DisplayOwnershipBroadcaster(store: displayOwnershipStore),
            teamHandler: nil, teamOnConnect: { _, _ in }, teamOnDisconnect: { _, _ in }
        )
    }

    /// Configure replication control before starting the listener.
    public func setMCPControl(_ callbacks: AuthenticatedMCPControl?) { configuration.mcpControl = callbacks }

    public func setGitControl(_ callbacks: AuthenticatedGitControl?) { configuration.gitControl = callbacks }

    /// Configure messaging before starting the listener.
    public func setTeamMessaging(handler: @escaping TeamChannelHandler.Handler,
                                 onConnect: @escaping TeamChannelHandler.OnConnect,
                                 onDisconnect: @escaping TeamChannelHandler.OnDisconnect) {
        let c = configuration
        configuration = SSHHostSessionConfiguration(
            streamFactory: c.streamFactory, pagedFactory: c.pagedFactory,
            panesStateSubscribe: c.panesStateSubscribe, panesStateV2Subscribe: c.panesStateV2Subscribe,
            paneControlMutator: c.paneControlMutator, worktreeManagementMutator: c.worktreeManagementMutator,
            authenticatedPlacementMutator: c.authenticatedPlacementMutator, authenticatedSkillMutator: c.authenticatedSkillMutator, mcpControl: c.mcpControl, gitControl: c.gitControl,
            chromeTabMutator: c.chromeTabMutator, chromeTabOnDisconnect: c.chromeTabOnDisconnect,
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
        let wasRunning = group != nil
        let (group, connections) = prepareTransport()
        let generation = generation
        var boundChannel: Channel?
        do {
            let channel = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
                .childChannelInitializer(connectionInitializer(connections: connections))
                .bind(numericOrResolvedHost: host, port: port).get()
            boundChannel = channel
            try Task.checkCancellation()
            guard self.generation == generation else { throw CancellationError() }
            guard let boundPort = channel.localAddress?.port else { throw ServerError.missingBoundPort }
            listener = channel
            starting = false
            return boundPort
        } catch {
            try? await boundChannel?.close().get()
            if self.generation == generation {
                starting = false
                // Stream admission may have claimed the shared group while the
                // bind was suspended, even if this bind originally created it.
                if !wasRunning, !streamsStarted { await close() }
            }
            throw error
        }
    }

    /// Admit a stream from a transport such as Tailcat without opening a TCP listener.
    /// The caller retains its handles; this server owns duplicates until SSH closes.
    public func accept(input: FileHandle, output: FileHandle) async throws {
        try Task.checkCancellation()
        let reader = fcntl(input.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard reader >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let writer = fcntl(output.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard writer >= 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            closeSSHDescriptor(reader)
            throw error
        }
        let (group, connections) = prepareTransport()
        streamsStarted = true
        let generation = generation
        let initialize = connectionInitializer(connections: connections)
        let initialized = NIOLockedValueBox(false)
        let channel: Channel
        do {
            channel = try await NIOPipeBootstrap(group: group).channelInitializer { channel in
                initialized.withLockedValue { $0 = true }
                return initialize(channel)
            }.takingOwnershipOfDescriptors(input: reader, output: writer).get()
        } catch {
            // Validation failures retain caller ownership. After initialization,
            // NIO closes the duplicates even if pipeline setup fails.
            if !initialized.withLockedValue({ $0 }) { closeSSHDescriptor(reader); closeSSHDescriptor(writer) }
            throw error
        }
        guard self.generation == generation, !Task.isCancelled else {
            try? await channel.close().get()
            throw CancellationError()
        }
    }

    private func prepareTransport() -> (MultiThreadedEventLoopGroup, DirectSSHConnections) {
        if let group, let connections { return (group, connections) }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let connections = DirectSSHConnections()
        self.group = group
        self.connections = connections
        generation &+= 1
        return (group, connections)
    }

    private func connectionInitializer(connections: DirectSSHConnections) -> @Sendable (Channel) -> EventLoopFuture<Void> {
        let config = configuration
        let key = hostKey
        let store = trustedPeerStore
        let active = activeRemotePeers
        let registry = sshConnectionRegistry
        return { channel in
            guard connections.insert(channel) else {
                return channel.eventLoop.makeFailedFuture(ChannelError.ioOnClosedChannel)
            }
            let session = DirectSSHSession(channel: channel, store: store, registry: registry, allowReplicationOnly: config.gitControl != nil)
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
        }
    }

    public func close() async {
        generation &+= 1
        starting = false
        streamsStarted = false
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

/// Registration is scoped to one channel, so a late close cannot deregister a reconnect.
private actor DirectSSHSession {
    let channel: Channel
    let store: TrustedPeerStore
    let registry: SSHConnectionRegistry
    let allowReplicationOnly: Bool
    var registration: (RemoteDeviceID, SSHConnectionRegistry.RegistrationToken)?
    var closed = false
    init(channel: Channel, store: TrustedPeerStore, registry: SSHConnectionRegistry, allowReplicationOnly: Bool) {
        self.channel = channel; self.store = store; self.registry = registry
        self.allowReplicationOnly = allowReplicationOnly
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
        guard SSHUserAuthDelegate.hasCurrentAuthorization(peer, in: store, allowReplicationOnly: allowReplicationOnly) else {
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

private func closeSSHDescriptor(_ descriptor: Int32) { _ = close(descriptor) }
