#if canImport(CryptoKit)
import CryptoKit
#else
@preconcurrency import Crypto
#endif
import Foundation
import GrafttyKit
import GrafttyProtocol
import GrafttyTunnel
import NIOCore
import NIOSSH

/// Callbacks shared by SSH sessions on WebRTC and TCP.
struct SSHHostSessionConfiguration: Sendable {
    let streamFactory: @Sendable (String) async throws -> TerminalByteStream
    let pagedFactory: PagedTerminalStreamFactory?
    let panesStateSubscribe: PanesStateChannelHandler.Subscribe
    let panesStateV2Subscribe: PanesStateChannelHandler.Subscribe
    let paneControlMutator: PaneControlChannelHandler.Mutator
    let worktreeManagementMutator: WorktreeManagementChannelHandler.Mutator
    let ownershipStore: SessionDisplayOwnershipStore
    let ownershipBroadcaster: DisplayOwnershipBroadcaster
    let teamHandler: TeamChannelHandler.Handler?
    let teamOnConnect: TeamChannelHandler.OnConnect
    let teamOnDisconnect: TeamChannelHandler.OnDisconnect

    func makeHandler(
        channel: Channel,
        hostKey: Curve25519.Signing.PrivateKey,
        trustedPeerStore: TrustedPeerStore,
        expectedDeviceID: RemoteDeviceID? = nil,
        activeRemotePeers: ActiveRemotePeerRegistry,
        peerBox: AuthenticatedPeerBox,
        bulkChannels: BulkTerminalChannels? = nil,
        isBulkTransport: Bool = false,
        closeTransport: @escaping @Sendable () async -> Void,
        onAuthenticatedPeer: @escaping @Sendable (TrustedPeer) -> Void
    ) -> NIOSSHHandler {
        SSHServerSetup.makeHandler(
            hostKey: hostKey,
            trustedPeerStore: trustedPeerStore,
            expectedDeviceID: expectedDeviceID,
            activePeerRegistry: activeRemotePeers,
            closeActiveTransport: closeTransport,
            onActivePeerRegistered: { entryID in
                channel.closeFuture.whenComplete { _ in
                    activeRemotePeers.unregister(entryID: entryID)
                }
            },
            allocator: channel.allocator,
            onAuthenticatedPeer: { peer in
                peerBox.peer = peer
                onAuthenticatedPeer(peer)
            },
            inboundChildChannelInitializer: { child, type in
                if case .directTCPIP(let destination) = type {
                    guard peerBox.browserTunnelAllowed(host: destination.targetHost, port: destination.targetPort) else {
                        return child.eventLoop.makeFailedFuture(SSHHostSessionError.unsupportedChannelType)
                    }
                    return SSHTCPBridge.connect(host: destination.targetHost, port: destination.targetPort, channel: child)
                }
                guard case .session = type else {
                    return child.eventLoop.makeFailedFuture(SSHHostSessionError.unsupportedChannelType)
                }
                return child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.addHandler(SubsystemDispatcher(
                        streamFactory: streamFactory,
                        pagedFactory: pagedFactory,
                        panesStateSubscribe: panesStateSubscribe,
                        panesStateV2Subscribe: panesStateV2Subscribe,
                        paneControlMutator: paneControlMutator,
                        worktreeManagementMutator: { request in
                            await peerBox.manage(request, using: worktreeManagementMutator)
                        },
                        ownershipStore: ownershipStore,
                        ownershipBroadcaster: ownershipBroadcaster,
                        deviceIDProvider: { peerBox.deviceID },
                        worktreeManagementAllowed: { peerBox.worktreeManagementAllowed },
                        displayKindProvider: { peerBox.displayKind },
                        teamHandler: teamHandler,
                        teamOnConnect: teamOnConnect,
                        teamOnDisconnect: teamOnDisconnect,
                        teamAllowed: { peerBox.teamAllowed },
                        bulkChannels: bulkChannels,
                        isBulkTransport: isBulkTransport
                    ))
                }
            }
        )
    }
}

enum SSHHostSessionError: Error { case unsupportedChannelType }

final class AuthenticatedPeerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _peer: TrustedPeer?

    var peer: TrustedPeer? {
        get { lock.lock(); defer { lock.unlock() }; return _peer }
        set { lock.lock(); defer { lock.unlock() }; _peer = newValue }
    }

    var deviceID: RemoteDeviceID? {
        lock.lock()
        defer { lock.unlock() }
        return _peer?.id
    }

    var displayKind: DisplayClientKind {
        lock.lock()
        defer { lock.unlock() }
        switch _peer?.kind {
        case .iphone, .ipad, nil:
            return .ios
        default:
            return .mac
        }
    }

    var teamAllowed: Bool {
        lock.withLock { _peer?.kind == .mac || _peer?.kind.rawValue == "linux" }
    }

    var worktreeManagementAllowed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _peer?.capabilities.worktreeManagement == .allowed
    }

    /// A port tap grants a narrow approval only after the host resolves a live listener.
    func manage(_ request: WorktreeManagementRequest,
                using mutator: WorktreeManagementChannelHandler.Mutator,
                approvals: BrowserTunnelApprovalStore = .shared) async -> WorktreeManagementResponse {
        guard case .openResource(_, .port(let port)) = request else { return await mutator(request) }
        guard let peer, peer.capabilities.portTunnel != .disabled else {
            return .error(code: "port-tunnel-disabled", message: "Port tunnels are disabled for this paired device.", forceAllowed: false, shortStatus: nil)
        }
        let response = await mutator(request)
        if case .openResource(.url(let url)) = response,
           url.scheme == "http", let host = url.host, url.port == Int(port), port > 0 {
            guard peer.capabilities.portTunnel != .allowedLoopback
                || BrowserTunnelAuthorization.allows(capability: .allowedLoopback, host: host, hasUserApproval: false) else {
                return .error(code: "port-tunnel-loopback-only", message: "This device can only open loopback ports. This listener uses a network interface.", forceAllowed: false, shortStatus: nil)
            }
            approvals.approve(deviceID: peer.id, host: host, port: port, until: Date().addingTimeInterval(900))
        }
        return response
    }

    func browserTunnelAllowed(host: String, port: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let peer = _peer else { return false }
        return BrowserTunnelAuthorization.allows(
            capability: peer.capabilities.portTunnel,
            host: host,
            hasUserApproval: BrowserTunnelApprovalStore.shared.isApproved(deviceID: peer.id, host: host, port: port)
        )
    }
}

enum BrowserTunnelAuthorization {
    static func allows(capability: PairedDeviceCapabilities.PortTunnel, host: String, hasUserApproval: Bool) -> Bool {
        switch capability {
        case .disabled: return false
        case .askEachTime: return hasUserApproval
        case .allowedLoopback:
            let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            guard normalized != "localhost", !normalized.hasSuffix(".localhost") else { return true }
            guard let address = try? SocketAddress(ipAddress: normalized, port: 0) else { return false }
            switch address {
            case .v4: return address.ipAddress?.hasPrefix("127.") == true
            case .v6: return address.ipAddress == "::1"
            case .unixDomainSocket: return false
            }
        }
    }
}
