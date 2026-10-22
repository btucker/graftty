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
    var authenticatedPlacementMutator: AuthenticatedPlacementMutator? = nil
    var gitControl: AuthenticatedGitControl? = nil
    var chromeTabMutator: ChromeTabChannelHandler.Mutator? = nil
    var chromeTabOnDisconnect: ChromeTabChannelHandler.OnDisconnect = { _ in }
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
                            await peerBox.manage(request, using: worktreeManagementMutator, placement: authenticatedPlacementMutator)
                        },
                        chromeTabMutator: chromeTabMutator.map { mutator -> ChromeTabChannelHandler.Mutator in
                            { @Sendable request, deviceID, viewerID in
                                guard peerBox.deviceID == deviceID, peerBox.worktreeManagementAllowed else {
                                    await chromeTabOnDisconnect(viewerID)
                                    return .init(error: "Chrome control permission was revoked.")
                                }
                                return await mutator(request, deviceID, viewerID)
                            }
                        },
                        chromeTabOnDisconnect: chromeTabOnDisconnect,
                        ownershipStore: ownershipStore,
                        ownershipBroadcaster: ownershipBroadcaster,
                        deviceIDProvider: { peerBox.deviceID },
                        worktreeManagementAllowed: { peerBox.worktreeManagementAllowed },
                        displayKindProvider: { peerBox.displayKind },
                        gitControlHandler: gitControl.map { callbacks -> TeamChannelHandler.Handler in
                            { deviceID, bytes in
                                guard !Task.isCancelled, let identity = peerBox.gitControlIdentity, identity.deviceID == deviceID else { return Data() }
                                return await callbacks.handler(identity, bytes)
                            }
                        },
                        gitControlOnConnect: { deviceID, session in
                            guard let callbacks = gitControl, let identity = peerBox.gitControlIdentity, identity.deviceID == deviceID else {
                                await session.close(); return
                            }
                            await callbacks.onConnect(identity, session)
                        },
                        gitControlOnDisconnect: { deviceID, sessionID in
                            guard let callbacks = gitControl, let peer = peerBox.peer, peer.id == deviceID else { return }
                            await callbacks.onDisconnect(.init(deviceID: peer.id, fingerprint: peer.fingerprint), sessionID)
                        },
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

    var gitControlIdentity: RemoteMacConnectionSummary.ID? {
        guard let peer, peer.capabilities.worktreeManagement == .allowed, peer.kind == .mac || peer.kind == .linux else { return nil }
        return .init(deviceID: peer.id, fingerprint: peer.fingerprint)
    }

    var teamAllowed: Bool {
        lock.withLock { _peer?.kind == .mac || _peer?.kind.rawValue == "linux" }
    }

    var worktreeManagementAllowed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _peer?.capabilities.worktreeManagement == .allowed
    }

    /// Port and sign-in taps grant narrow approval after resolving a live worktree listener.
    func manage(_ request: WorktreeManagementRequest,
                using mutator: WorktreeManagementChannelHandler.Mutator,
                placement: AuthenticatedPlacementMutator? = nil,
                approvals: BrowserTunnelApprovalStore = .shared) async -> WorktreeManagementResponse {
        if case .placement(let placementRequest) = request {
            guard let peer, peer.capabilities.worktreeManagement == .allowed else {
                return .error(code: "placement-forbidden", message: "Placement requires authenticated worktree-management permission.", forceAllowed: false, shortStatus: nil)
            }
            guard let placement else {
                return .error(code: "placement-unavailable", message: "This host does not support placement admission.", forceAllowed: false, shortStatus: nil)
            }
            return await placement(placementRequest, .init(deviceID: peer.id, fingerprint: peer.fingerprint))
        }
        guard case .openResource(_, let resource) = request else { return await mutator(request) }
        if case .authenticate(let url) = resource {
            guard let peer, peer.capabilities.portTunnel != .disabled else {
                return .error(code: "authentication-tunnel-disabled", message: "This device needs browser tunnel permission to complete sign-in through the Mac.", forceAllowed: false, shortStatus: nil)
            }
            guard let authentication = WorktreeAuthenticationURL(url: url),
                  !WorktreeAuthenticationURL.isLoopbackHost(url.host ?? "") else {
                return .error(code: "invalid-authentication", message: "This link has no supported local sign-in callback.", forceAllowed: false, shortStatus: nil)
            }
            let response = await mutator(request)
            guard let currentPeer = self.peer, currentPeer.id == peer.id,
                  currentPeer.capabilities.portTunnel != .disabled else {
                return .error(code: "authentication-tunnel-disabled", message: "Browser tunnel permission changed while preparing sign-in.", forceAllowed: false, shortStatus: nil)
            }
            if case .openResource(.authentication(let approvedURL, let callbackHost)) = response,
               approvedURL == url, authentication.resolveCallbackHost(in: [
                   WorktreePort(port: authentication.callbackPort, scope: .loopback, processName: "", host: callbackHost)
               ]) == callbackHost {
                approvals.approve(deviceID: peer.id, host: callbackHost, port: authentication.callbackPort, until: Date().addingTimeInterval(900))
            }
            return response
        }
        guard case .port(let port) = resource else { return await mutator(request) }
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

    func browserTunnelAllowed(host: String, port: Int, protectedChromePorts: ChromeDebugPortRegistry = .shared) -> Bool {
        guard !protectedChromePorts.contains(port: port) else { return false }
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
