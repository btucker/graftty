import SwiftUI
import AppKit
import CryptoKit
import GrafttyCommandUI
import GrafttyHostAgent
import GrafttyKit
import GrafttyProtocol
import GrafttyRemoteClient
import WebRTC

/// Holds long-lived non-SwiftUI services for the app. Retained for the lifetime of
/// `GrafttyApp` so weak delegates (e.g. `WorktreeMonitor.delegate`) stay alive.
///
/// @spec REMOTE-1.13
/// The application shall construct one `HostIdentityStore` and one
/// `TrustedPeerStore` per process and share them with the pairing
/// coordinator, the paired-access signaling server, the inbound host pool
/// and the Settings paired-devices list.
@MainActor
final class AppServices {
    let socketServer: SocketServer
    var attentionFileObserver: AttentionFileHandoffObserver?
    let worktreeMonitor: WorktreeMonitor
    let statsStore: WorktreeStatsStore
    let remoteBranchStore: RemoteBranchStore
    let prStatusStore: PRStatusStore
    let claudeSessionRegistry: ClaudeSessionRegistry
    /// TERM-11.5: per-zmx-session remote client attach counts. Fed by the
    /// web (/ws) and SSH-over-WebRTC attach paths; consulted by Mac pane
    /// backends to scope the IOS-12.1 silent gate to multi-device sessions.
    let remoteAttachmentRegistry: RemoteAttachmentRegistry
    /// Process-wide display ownership state shared by web/iOS bridge
    /// connections and, once wired, native Mac panes.
    let displayOwnershipStore: SessionDisplayOwnershipStore
    let teamInbox: TeamInbox
    let remoteTeamRouter = RemoteTeamRouter()
    let teamEventDispatcher: TeamEventDispatcher
    let cliWorktreeCreations: CLIWorktreeCreationStore
    let cliWorktreeRemovals: CLIWorktreeRemovalStore
    var worktreeMonitorBridge: WorktreeMonitorBridge?
    /// Drives `TeamPresenceMonitor.cleanupStale` on a slow cadence so
    /// SIGKILL'd agents (whose wrapper trap never fired) don't leave
    /// dangling presence files. The wrapper trap is the primary cleanup
    /// path; this is the SIGKILL / hard-crash fallback. Retained here so
    /// the ticker outlives `startup()`. TEAM-PRESENCE-1.4.
    var presenceCleanupTicker: PollingTicker?
    /// Sweeps worktrees that have remained stale for the full one-hour
    /// grace period. Retained here so the timer survives `startup()`.
    var staleWorktreeAutoDismissTicker: PollingTicker?
    /// Provides the current AppState for the team PR-merged dispatch hook.
    /// Set in GrafttyApp.startup() once @State is accessible (TEAM-5.4).
    var appStateProvider: (() -> AppState)?

    // MARK: - Codex App-Server Delivery
    /// Retained so inbox arrivals can reach Codex app-server delivery for
    /// the app's lifetime.
    var codexAppServerDeliveryService: CodexAppServerDeliveryService?
    var claudePeerDeliveryService: ClaudePeerDeliveryService?
    /// Holds the `TeamInboxObserver` cancellables so the observers stay
    /// active for the lifetime of the app (one observer per team-ID started
    /// at launch for each known repo).
    var inboxObserverCancellables: [TeamInboxObserver.Cancellable] = []
    /// Strong references to the observers themselves. `start()` captures
    /// `self` weakly; without this, the observer deallocates as soon as
    /// the for-loop iteration ends, the async closure inside `start`
    /// finds `weak self` nil, and `attach`/`emit` never run — FSEvents
    /// sources are never installed.
    var inboxObservers: [TeamInboxObserver] = []

    // MARK: - WebRTC (R4)

    /// Mac-side connection pool. Each paired device gets an independent
    /// WebRTC agent and SSH transport.
    /// Retained here so it outlives the SwiftUI init cycle.
    var hostAgentPool: WebRTCHostAgentPool?
    /// Deletes only the prompt files found at startup after their grace
    /// period. Capturing that snapshot avoids pruning prompts owned by
    /// worktree operations created during this app process.
    private var agentPromptRecoveryTask: Task<Void, Never>?

    /// Host-side LAN pairing consent coordinator. `/v2/pairing/*` and the
    /// presented sheet share this instance; its process-wide admission is
    /// also shared with the Settings pairing listener.
    let hostPairingCoordinator: RemoteMacHostPairingCoordinator
    /// The one `TrustedPeerStore` for this process. The pairing coordinator,
    /// the paired-access signaling server, every `WebRTCHostAgent`, and
    /// `PairedDevicesSection` (list/remove) share it, so writes from pairing
    /// and from Settings serialize on the same lock.
    let trustedPeerStore: TrustedPeerStore
    /// The one `HostIdentityStore` for this process, shared by the pairing
    /// coordinator and the paired-access signaling server.
    private let hostIdentityStore: HostIdentityStore
    /// Loads the host signing key at launch, before the pairing coordinator
    /// exists, and retains the first key that loads (REMOTE-1.12).
    private let hostKeyProvider: HostKeyProvider
    /// Same `SSHConnectionRegistry` instance `WebRTCHostAgent` registers
    /// its live SSH connection into (REMOTE-3.1 revocation, W4).
    /// `PairedDevicesSection`'s "Remove" action calls
    /// `registry.revoke(deviceID:)` right after removing the peer from
    /// `trustedPeerStore`, closing the live connection immediately rather
    /// than waiting for the peer's next userauth attempt to fail.
    let sshConnectionRegistry = SSHConnectionRegistry()
    let remoteMacsModel: RemoteMacsModel
    let remoteMacPairingDriverFactory: @MainActor () -> AddRemoteMacPairingDriving
    let remoteMacAccessEnabled: Bool
    let idleSleepController = IdleSleepController()
    private var lanRemoteAccessServer: LANRemoteAccessServer?
    private var bonjourAdvertiser: GrafttyBonjourAdvertiser?
    private var remoteAccessRouteRefreshTask: Task<Void, Never>?

    init(
        socketPath: String,
        pairingAdmission: HostPairingAdmission
    ) {
        let recoveryPromptFiles = WorktreeAgentLaunchCommand.recoveryPromptFiles()
        // No worktree-creation operations exist yet, so files older than the
        // recovery window can only be leftovers from a prior app crash.
        WorktreeAgentLaunchCommand.pruneStalePromptFiles()
        self.socketServer = SocketServer(socketPath: socketPath)

        self.worktreeMonitor = WorktreeMonitor()
        // The 5s stats, 10s remote-ref, and 30s PR ticks align every
        // 30 seconds. Share one cap so twelve repositories produce four
        // background process pipelines, not three independent bursts.
        let backgroundProcessLimiter = BackgroundProcessLimiter(capacity: 4)
        self.statsStore = WorktreeStatsStore(
            backgroundProcessLimiter: backgroundProcessLimiter
        )
        let remoteBranchStore = RemoteBranchStore(
            backgroundProcessLimiter: backgroundProcessLimiter
        )
        self.remoteBranchStore = remoteBranchStore
        self.prStatusStore = PRStatusStore(
            remoteBranchStore: remoteBranchStore,
            backgroundProcessLimiter: backgroundProcessLimiter
        )
        self.claudeSessionRegistry = ClaudeSessionRegistry()
        self.remoteAttachmentRegistry = RemoteAttachmentRegistry()
        self.displayOwnershipStore = SessionDisplayOwnershipStore()
        self.cliWorktreeCreations = CLIWorktreeCreationStore()
        self.cliWorktreeRemovals = CLIWorktreeRemovalStore()

        // Lift the team inbox up here so the request handler
        // (`teamInboxRequestHandler()`) and the dispatcher share one
        // disk root rather than each constructing its own.
        let teamInbox = TeamInbox(
            rootDirectory: AppState.defaultDirectory
                .appendingPathComponent("team-inbox", isDirectory: true)
        )
        self.teamInbox = teamInbox
        self.teamEventDispatcher = TeamEventDispatcher(
            inbox: teamInbox,
            preferencesProvider: {
                let raw = UserDefaults.standard.string(forKey: SettingsKeys.teamEventRoutingPreferences) ?? ""
                return TeamEventRoutingPreferences(rawValue: raw) ?? TeamEventRoutingPreferences()
            },
            templateProvider: {
                UserDefaults.standard.string(forKey: SettingsKeys.teamPrompt) ?? ""
            }
        )
        let hostIdentityStore = HostIdentityStore(directory: HostIdentityStore.defaultDirectory)
        self.hostIdentityStore = hostIdentityStore
        let trustedPeerStore = TrustedPeerStore(directory: TrustedPeerStore.defaultDirectory)
        self.trustedPeerStore = trustedPeerStore
        let hostKeyProvider = HostKeyProvider(load: hostIdentityStore.loadOrGenerateAndPersist)
        self.hostKeyProvider = hostKeyProvider
        do {
            _ = try hostKeyProvider.key()
        } catch {
            NSLog("[Graftty] failed to load remote host identity: %@", String(describing: error))
        }
        self.hostPairingCoordinator = Self.makeHostPairingCoordinator(
            admission: pairingAdmission,
            identityStore: hostIdentityStore,
            peerStore: trustedPeerStore
        )
        let remoteMacsModel = RemoteMacsModel(store: RemoteMacStore())
        self.remoteMacsModel = remoteMacsModel
        remoteMacsModel.setTeamRouter(remoteTeamRouter)
        self.remoteMacPairingDriverFactory = {
            LocalAddRemoteMacPairingDriver(
                identityStore: ClientIdentityStore(directory: ClientIdentityStore.defaultDirectory),
                pinnedHostStore: PinnedHostStore(directory: PinnedHostStore.defaultDirectory),
                clientDeviceID: Self.localRemoteDeviceID(),
                clientKind: .mac,
                clientDisplayName: Self.localHostDisplayName()
            )
        }
        self.remoteMacAccessEnabled = Self.remoteMacAccessEnabledDefault()
        do {
            let localFingerprint = try localHostFingerprint()
            let browser = GrafttyBonjourBrowser(
                localDeviceID: Self.localRemoteDeviceID(),
                localFingerprint: localFingerprint,
                supportedProtocolVersions: [String(RemoteAccessProtocol.version)],
                onCandidate: { [weak remoteMacsModel] candidate in
                    Task { @MainActor in
                        do {
                            try remoteMacsModel?.publishDiscoveryCandidate(candidate)
                        } catch {
                            NSLog("[Graftty] failed to record Bonjour remote Mac candidate: %@", String(describing: error))
                        }
                    }
                },
                onCandidateRemoved: { [weak remoteMacsModel] identity in
                    Task { @MainActor in
                        remoteMacsModel?.removeDiscoveryCandidate(identity: identity)
                    }
                }
            )
            remoteMacsModel.setDiscoveryBrowser(browser)
        } catch {
            NSLog("[Graftty] failed to prepare remote Mac discovery identity: %@", String(describing: error))
        }

        // Route PRStatusStore transitions through the inbox dispatcher.
        // `appStateProvider` is set later in startup() once @State is live;
        // before that point the guard below is a no-op.
        self.prStatusStore.onTransition = { [weak self] routable, subjectWorktreePath, attrs in
            guard let self else { return }
            guard UserDefaults.standard.bool(forKey: SettingsKeys.agentTeamsEnabled) else { return }
            let appState = self.appStateProvider?() ?? AppState()
            let event = ChannelServerMessage.event(
                type: routable.wireType,
                attrs: attrs,
                body: routable.defaultBody(attrs: attrs)
            )
            do {
                try self.teamEventDispatcher.dispatchRoutableEvent(
                    event,
                    subjectWorktreePath: subjectWorktreePath,
                    repos: appState.repos
                )
            } catch {
                NSLog("[Graftty] dispatchRoutableEvent failed: %@", String(describing: error))
            }
        }
        if !recoveryPromptFiles.isEmpty {
            self.agentPromptRecoveryTask = Task {
                do {
                    try await Task.sleep(for: .seconds(24 * 60 * 60))
                } catch {
                    return
                }
                WorktreeAgentLaunchCommand.discardRecoveryPromptFiles(recoveryPromptFiles)
            }
        }
    }

    private static func makeHostPairingCoordinator(
        admission: HostPairingAdmission,
        identityStore: HostIdentityStore,
        peerStore: TrustedPeerStore
    ) -> RemoteMacHostPairingCoordinator {
        let session = HostPairingSession(
            identityStore: identityStore,
            peerStore: peerStore,
            hostDeviceID: localRemoteDeviceID(),
            hostKind: .mac,
            hostDisplayName: localHostDisplayName(),
            pairingURLProvider: { URL(string: "http://0.0.0.0\(PairingRoutes.basePath)")! }
        )
        return RemoteMacHostPairingCoordinator(
            server: HostPairingServer(session: session),
            admission: admission
        )
    }

    /// Paired-device listener port. `GRAFTTY_PAIRED_ACCESS_PORT` lets a
    /// development instance (isolated via `CFFIXED_USER_HOME` and its own
    /// bundle identifier) listen beside a production Graftty that already
    /// holds the default port; mobile pairing records the advertised port,
    /// so clients follow whichever port the instance binds.
    static let pairedAccessPort: Int = {
        if let raw = ProcessInfo.processInfo.environment["GRAFTTY_PAIRED_ACCESS_PORT"],
           let port = Int(raw), (1...65_535).contains(port) {
            return port
        }
        return RemoteAccessProtocol.pairedAccessPort
    }()

    func startRemoteMacAccessServices(hostAgentPool: WebRTCHostAgentPool?) async throws {
        guard remoteMacAccessEnabled else {
            throw RemoteMacAccessServiceError.disabled
        }
        guard lanRemoteAccessServer == nil else { return }
        guard let hostAgentPool else {
            throw RemoteMacAccessServiceError.hostAgentUnavailable
        }

        let endpoint = RemoteAccessEndpoint(
            host: Self.localLANHostName(),
            port: Self.pairedAccessPort
        )
        endpoint.setRoutes(
            await Self.remoteAccessRoutes(
                lanBaseURL: endpoint.baseURL()
            )
        )
        let signalingServer = AuthenticatedSignalingServer(
            identityStore: hostIdentityStore,
            peerStore: trustedPeerStore,
            hostDeviceID: Self.localRemoteDeviceID(),
            routesProvider: { endpoint.routes() }
        )
        let routeHandler = RemoteMacAccessServices.makeLANRouteHandler(
            lanBaseURLProvider: { endpoint.baseURL() },
            hostPairingCoordinator: hostPairingCoordinator,
            acceptSignalingChallenge: { request in
                await signalingServer.issueChallenge(request)
            },
            acceptSignalingOffer: { offer in
                let verified: AuthenticatedSignalingServer.VerifiedOffer
                switch await signalingServer.authenticateOffer(offer) {
                case .success(.new(let value)):
                    verified = value
                case .success(.pending):
                    switch await signalingServer.awaitAnswer(for: offer) {
                    case .success(let answer):
                        return .authenticatedSuccess(answer)
                    case .failure(let error):
                        return .unavailable(error.error)
                    }
                case .success(.cached(let answer)):
                    return .authenticatedSuccess(answer)
                case .failure(let error):
                    return .invalid(error.error)
                }
                let rtcOffer = RTCSessionDescription(type: .offer, sdp: offer.sdp)
                do {
                    let answer = try await hostAgentPool.acceptOffer(
                        rtcOffer,
                        clientDeviceID: verified.offer.clientDeviceID,
                        replacingExistingConnection:
                            verified.authorizesReplacement
                    )
                    switch await signalingServer.makeAnswer(
                        sdp: answer.sdp,
                        for: verified
                    ) {
                    case .success(let signedAnswer):
                        return .authenticatedSuccess(signedAnswer)
                    case .failure(let error):
                        return .internalFailure(error.error)
                    }
                } catch WebRTCHostAgent.HostError.busy {
                    await signalingServer.releaseOffer(verified)
                    return .hostBusy("device connection is busy or host connection limit reached")
                } catch {
                    await signalingServer.releaseOffer(verified)
                    NSLog("[Graftty] LAN WebRTCHostAgent.acceptOffer failed: %@", String(describing: error))
                    return .internalFailure("acceptOffer failed: \(error)")
                }
            }
        )
        let server = LANRemoteAccessServer(
            config: .init(
                port: Self.pairedAccessPort,
                bindHost: "::"
            ),
            routeHandler: routeHandler
        )
        // Resolve every throwing identity dependency before binding. If this
        // fails after `server.start()`, the listener would not yet be retained
        // by `lanRemoteAccessServer` and therefore could not be stopped.
        let localHostFingerprint = try localHostFingerprint()
        try server.start()
        guard let port = server.listeningPort else {
            server.stop()
            throw RemoteMacAccessServiceError.listenerPortUnavailable
        }
        endpoint.setPort(port)

        let advertiser = GrafttyBonjourAdvertiser(
            port: port,
            label: Self.localHostDisplayName(),
            deviceID: Self.localRemoteDeviceID(),
            fingerprint: localHostFingerprint,
            protocolVersion: String(RemoteAccessProtocol.version),
            pairingStatus: .required
        )
        do {
            try advertiser.start()
        } catch {
            server.stop()
            throw error
        }

        lanRemoteAccessServer = server
        bonjourAdvertiser = advertiser
        remoteAccessRouteRefreshTask?.cancel()
        remoteAccessRouteRefreshTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    return
                }
                endpoint.setRoutes(
                    await Self.remoteAccessRoutes(
                        lanBaseURL: endpoint.baseURL()
                    )
                )
            }
        }
        NSLog("[Graftty] paired remote access listening on [::]:%d", port)
    }

    func stopRemoteMacAccessServices() {
        remoteMacsModel.stopDiscovery()
        remoteAccessRouteRefreshTask?.cancel()
        remoteAccessRouteRefreshTask = nil
        bonjourAdvertiser?.stop()
        bonjourAdvertiser = nil
        lanRemoteAccessServer?.stop()
        lanRemoteAccessServer = nil
    }

    enum RemoteMacAccessServiceError: Error {
        case disabled
        case hostAgentUnavailable
        case listenerPortUnavailable
    }

    private final class RemoteAccessEndpoint: @unchecked Sendable {
        private let lock = NSLock()
        private let host: String
        private var port: Int
        private var advertisedRoutes: [RemoteConnectionRoute] = []

        init(host: String, port: Int) {
            self.host = host
            self.port = port
        }

        func setPort(_ port: Int) {
            lock.withLock {
                self.port = port
            }
        }

        func setRoutes(_ routes: [RemoteConnectionRoute]) {
            lock.withLock {
                advertisedRoutes = routes
            }
        }

        func routes() -> [RemoteConnectionRoute] {
            lock.withLock { advertisedRoutes }
        }

        func baseURL() -> URL {
            lock.withLock {
                var components = URLComponents()
                components.scheme = "http"
                components.host = host
                components.port = port
                return components.url ?? URL(string: "http://\(host):\(port)")!
            }
        }
    }

    private static func remoteAccessRoutes(
        lanBaseURL: URL
    ) async -> [RemoteConnectionRoute] {
        await RemoteAccessRouteDiscovery.routes(lanBaseURL: lanBaseURL)
    }

    private static func remoteMacAccessEnabledDefault() -> Bool {
        let key = "remoteMacAccess.enabled"
        if let value = UserDefaults.standard.object(forKey: key) as? Bool {
            return value
        }
        return true
    }

    /// Host signing key for the inbound host pool. The paired-access
    /// listener authenticates v2 offers with the device keys before passing
    /// them to the pool, whose agents open SSH sessions over the resulting
    /// DataChannel → zmx attach. Retries the shared store if every earlier
    /// load failed. `nil` when this load fails too; startup then builds no
    /// host pool and paired access fails with `hostAgentUnavailable`.
    func hostKey() -> Curve25519.Signing.PrivateKey? {
        do {
            return try hostKeyProvider.key()
        } catch {
            NSLog("[Graftty] failed to load remote host identity: %@", String(describing: error))
            return nil
        }
    }

    /// Fingerprint of the retained host key, loading it if every earlier
    /// load failed.
    private func localHostFingerprint() throws -> RemoteIdentityFingerprint {
        let hostKey = try hostKeyProvider.key()
        let publicKey = try RemoteIdentityPublicKey(
            rawRepresentation: hostKey.publicKey.rawRepresentation
        )
        return RemoteIdentityFingerprint(of: publicKey)
    }

    private static func localLANHostName() -> String {
        let hostName = ProcessInfo.processInfo.hostName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !hostName.isEmpty else {
            return "localhost.local"
        }
        if hostName.contains(".") {
            return hostName
        }
        return "\(hostName).local"
    }

    static func localRemoteDeviceID() -> RemoteDeviceID {
        do {
            return try HostDeviceIDStore.shared.loadOrGenerateAndPersist()
        } catch {
            assertionFailure("Failed to persist the local remote device ID: \(error)")
            return RemoteDeviceID.generate()
        }
    }

    static func localHostDisplayName() -> String {
        let localizedName = Host.current().localizedName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let localizedName, !localizedName.isEmpty {
            return localizedName
        }

        let hostName = ProcessInfo.processInfo.hostName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return hostName.isEmpty ? "Mac" : hostName
    }
}
