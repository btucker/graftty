import SwiftUI
import AppKit
import CryptoKit
import UserNotifications
import GrafttyCommandUI
import GrafttyHostAgent
import GrafttyKit
import GrafttyProtocol
import GrafttyRemoteClient
import WebRTC

func defaultBranchStatus(
    for repo: RepoEntry,
    stats: WorktreeStats?
) -> WebServer.RepoInfo.DefaultBranchStatus? {
    guard let stats, stats.behind > 0,
          let defaultRef = stats.upstreamRefs?.defaultRef,
          defaultRef.hasPrefix("origin/") else {
        return nil
    }
    let branchName = String(defaultRef.dropFirst("origin/".count))
    guard !branchName.isEmpty,
          repo.worktrees.first(where: { $0.path == repo.path })?.branch == branchName else {
        return nil
    }
    return WebServer.RepoInfo.DefaultBranchStatus(
        branchName: branchName,
        remoteRef: defaultRef,
        behindCount: stats.behind
    )
}

protocol CodexAppServerDeliveryTrigger: Sendable {
    func onMessageArrival(team: String, worktree: String) async
}

extension CodexAppServerDeliveryService: CodexAppServerDeliveryTrigger {}

private final class LivePaneSessionNames: @unchecked Sendable {
    private let lock = NSLock()
    private var names: Set<String> = []

    func replace(with names: Set<String>) {
        lock.lock()
        self.names = names
        lock.unlock()
    }

    func contains(_ name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return names.contains(name)
    }
}

private struct AppTeamDeliveryLiveness: TeamDeliveryLivenessChecking {
    let livePaneSession: @Sendable (String) -> Bool
    let processStartTimeMicroseconds: @Sendable (Int32) -> Int64?

    func isLivePaneSession(_ sessionName: String) -> Bool {
        livePaneSession(sessionName)
    }

    func processStartTimeMicroseconds(ofPID pid: Int32) -> Int64? {
        processStartTimeMicroseconds(pid)
    }
}

/// Seam for `handleShowPane` so tests can inject a canned scrollback
/// without spawning a `zmx` subprocess.
protocol ZmxHistoryReader: Sendable {
    func history(sessionName: String) throws -> String
}

struct ZmxHistorySubprocessReader: ZmxHistoryReader {
    let launcher: ZmxLauncher

    func history(sessionName: String) throws -> String {
        let result = try ZmxRunner.captureAll(
            executable: launcher.executable,
            args: ["history", sessionName],
            env: launcher.subprocessEnv(from: ProcessInfo.processInfo.environment),
            timeout: 1.0
        )
        guard result.exitCode == 0 else {
            let trimmed = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = trimmed.isEmpty
                ? "zmx history failed"
                : "zmx history failed: \(trimmed)"
            throw NSError(
                domain: "ZmxHistorySubprocessReader",
                code: Int(result.exitCode),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
        return result.stdout
    }
}

/// Seam for `handleSendPane`: production binds to the acknowledged
/// `SurfaceHandle.writeText` path. Tests inject a recording stub without
/// driving a libghostty surface.
protocol PaneInputSink: AnyObject {
    func send(text: String, pressEnter: Bool) -> Bool
}

private final class SurfaceHandlePaneInputSink: PaneInputSink {
    let handle: SurfaceHandle
    init(handle: SurfaceHandle) { self.handle = handle }
    /// Send-pane IPC is programmatic input arriving from another
    /// process — leave the IOS-12.1 silent gate closed so the next
    /// human keystroke at the target pane is what engages.
    func send(text: String, pressEnter: Bool) -> Bool {
        handle.writeText(
            text + (pressEnter ? "\r" : ""),
            claimEngagement: false
        )
    }
}

/// Fallback for a pane whose persisted zmx daemon is live but whose
/// in-memory Ghostty surface is absent.
protocol ZmxPaneInputWriter: Sendable {
    func send(sessionName: String, text: String) throws
}

private struct ZmxPaneInputSubprocessWriter: ZmxPaneInputWriter {
    let launcher: ZmxLauncher

    func send(sessionName: String, text: String) throws {
        try launcher.send(sessionName: sessionName, text: text, timeout: 1.0)
    }
}

final class AgentNotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AgentNotificationRouter()

    @MainActor var onActivate: ((AgentStopNotificationPayload) -> Void)?
    @MainActor var onActivateRemote: ((RemoteNotificationEvent) -> Void)?

    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    func post(_ notification: AgentStopNotificationContent) {
        post(
            title: notification.title,
            body: notification.body,
            userInfo: notification.userInfo
        )
    }

    func post(_ event: RemoteNotificationEvent) {
        guard let data = try? JSONEncoder().encode(event) else { return }
        post(
            title: event.title,
            body: event.body,
            userInfo: [
                "kind": "remote_attention",
                "event": data.base64EncodedString(),
            ]
        )
    }

    private func post(
        title: String,
        body: String,
        userInfo: [String: String]
    ) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            let post = {
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                content.userInfo = userInfo
                let request = UNNotificationRequest(
                    identifier: UUID().uuidString,
                    content: content,
                    trigger: nil
                )
                center.add(request)
            }
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                post()
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { post() }
                }
            default:
                break
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let raw = response.notification.request.content.userInfo
        var userInfo: [String: Any] = [:]
        for (key, value) in raw {
            guard let key = key as? String else { continue }
            userInfo[key] = value
        }
        if userInfo["kind"] as? String == "remote_attention",
           let encoded = userInfo["event"] as? String,
           let data = Data(base64Encoded: encoded),
           let event = try? JSONDecoder().decode(
               RemoteNotificationEvent.self,
               from: data
           ) {
            await MainActor.run {
                self.onActivateRemote?(event)
            }
            return
        }
        guard let payload = try? AgentStopNotification.payload(from: userInfo) else { return }
        await MainActor.run {
            self.onActivate?(payload)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        notification.request.content.userInfo["kind"] as? String
            == "remote_attention"
            ? [.banner, .sound]
            : []
    }
}

/// Holds long-lived non-SwiftUI services for the app. Retained for the lifetime of
/// `GrafttyApp` so weak delegates (e.g. `WorktreeMonitor.delegate`) stay alive.
@MainActor
final class AppServices {
    let socketServer: SocketServer
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

    /// Mac-side WebRTC host agent. Accepts authenticated offers from paired
    /// clients and opens SSH sessions over the resulting DataChannel.
    /// Retained here so it outlives the SwiftUI init cycle.
    var hostAgent: WebRTCHostAgent?
    /// Deletes only the prompt files found at startup after their grace
    /// period. Capturing that snapshot avoids pruning prompts owned by
    /// worktree operations created during this app process.
    private var agentPromptRecoveryTask: Task<Void, Never>?

    /// Host-side LAN pairing consent coordinator. `/v2/pairing/*` and the
    /// presented sheet share this instance; its process-wide admission is
    /// also shared with the Settings pairing listener.
    let hostPairingCoordinator: RemoteMacHostPairingCoordinator
    let remoteMacsModel: RemoteMacsModel
    let remoteMacPairingDriverFactory: @MainActor () -> AddRemoteMacPairingDriving
    let remoteMacAccessEnabled: Bool
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
        self.hostPairingCoordinator = Self.makeHostPairingCoordinator(
            admission: pairingAdmission
        )
        let remoteMacsModel = RemoteMacsModel(store: RemoteMacStore())
        self.remoteMacsModel = remoteMacsModel
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
            let localFingerprint = try Self.localHostFingerprint()
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
        admission: HostPairingAdmission
    ) -> RemoteMacHostPairingCoordinator {
        let identityStore = HostIdentityStore(directory: HostIdentityStore.defaultDirectory)
        let peerStore = TrustedPeerStore(directory: TrustedPeerStore.defaultDirectory)
        do {
            _ = try identityStore.loadOrGenerateAndPersist()
        } catch {
            NSLog("[Graftty] failed to prepare host pairing identity: %@", String(describing: error))
        }
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

    func startRemoteMacAccessServices(hostAgent: WebRTCHostAgent?) async throws {
        guard remoteMacAccessEnabled else {
            throw RemoteMacAccessServiceError.disabled
        }
        guard lanRemoteAccessServer == nil else { return }
        guard let hostAgent else {
            throw RemoteMacAccessServiceError.hostAgentUnavailable
        }

        let endpoint = RemoteAccessEndpoint(
            host: Self.localLANHostName(),
            port: RemoteAccessProtocol.pairedAccessPort
        )
        endpoint.setRoutes(
            await Self.remoteAccessRoutes(
                lanBaseURL: endpoint.baseURL()
            )
        )
        let identityStore = HostIdentityStore(
            directory: HostIdentityStore.defaultDirectory
        )
        let peerStore = TrustedPeerStore(
            directory: TrustedPeerStore.defaultDirectory
        )
        let signalingServer = AuthenticatedSignalingServer(
            identityStore: identityStore,
            peerStore: peerStore,
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
                    let answer = try await hostAgent.acceptOffer(rtcOffer)
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
                    return .hostBusy("host is already handling an offer")
                } catch {
                    await signalingServer.releaseOffer(verified)
                    NSLog("[Graftty] LAN WebRTCHostAgent.acceptOffer failed: %@", String(describing: error))
                    return .internalFailure("acceptOffer failed: \(error)")
                }
            }
        )
        let server = LANRemoteAccessServer(
            config: .init(
                port: RemoteAccessProtocol.pairedAccessPort,
                bindHost: "::"
            ),
            routeHandler: routeHandler
        )
        // Resolve every throwing identity dependency before binding. If this
        // fails after `server.start()`, the listener would not yet be retained
        // by `lanRemoteAccessServer` and therefore could not be stopped.
        let localHostFingerprint = try Self.localHostFingerprint()
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

    fileprivate enum RemoteMacAccessServiceError: Error {
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

    private static func localHostFingerprint() throws -> RemoteIdentityFingerprint {
        let identityStore = HostIdentityStore(directory: HostIdentityStore.defaultDirectory)
        let hostKey = try identityStore.loadOrGenerateAndPersist()
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

    fileprivate static func localRemoteDeviceID() -> RemoteDeviceID {
        do {
            return try HostDeviceIDStore.shared.loadOrGenerateAndPersist()
        } catch {
            assertionFailure("Failed to persist the local remote device ID: \(error)")
            return RemoteDeviceID.generate()
        }
    }

    fileprivate static func localHostDisplayName() -> String {
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

enum WorktreeStartResult: Equatable {
    case started
    case alreadyRunning
    case notFound
    case unavailable
}

@main
struct GrafttyApp: App {
    // Keep this in menu order: the first host action for a chord wins.
    private static let macHostShortcutCommands =
        GhosttyCommandRegistry.macSplitActions
        + GhosttyCommandRegistry.macPaneFocusActions
        + GhosttyCommandRegistry.macPaneLayoutActions
        + GhosttyCommandRegistry.macPaneLifecycleActions
        + GhosttyCommandRegistry.macSettingsActions

    @State private var appState: AppState
    @StateObject private var terminalManager: TerminalManager
    @StateObject private var webController: WebServerController
    @StateObject private var updaterController: UpdaterController
    private let services: AppServices
    /// Same `TrustedPeerStore` instance the coordinator and
    /// `WebRTCHostAgent` share — `PairedDevicesSection` reads it directly
    /// (list/remove) since the coordinator doesn't expose it publicly.
    private let trustedPeerStore: TrustedPeerStore
    /// Same `SSHConnectionRegistry` instance `WebRTCHostAgent` registers
    /// its live SSH connection into (REMOTE-3.1 revocation, W4). Exposed
    /// alongside `trustedPeerStore` so `PairedDevicesSection`'s "Remove"
    /// action can call `registry.revoke(deviceID:)` right after removing
    /// the peer from `trustedPeerStore` — closing the live connection
    /// immediately rather than waiting for the peer's next userauth
    /// attempt to fail.
    private let sshConnectionRegistry: SSHConnectionRegistry

    /// Observable proxy for per-pane port bindings. Mutated by the
    /// `PortScanner` `onChange` callback; injected into the SwiftUI
    /// environment so `SidebarView` can render port chips on each row.
    @StateObject private var portBindingsModel = PortBindingsModel()

    /// Polls `lsof` against each registered pane's process subtree to
    /// detect listening sockets. Wired into `TerminalManager` so pane
    /// add/close flows propagate registration; tick cadence is driven
    /// by `portsTicker`.
    private let portScanner = PortScanner(
        runner: SystemLsofRunner(),
        walker: ProcessTreeWalker()
    )

    /// 2s cadence for `portScanner.tick()`. A user starting `npm run
    /// dev` should see the chip appear within a couple seconds without
    /// the chip noticeably flickering on/off across rebuilds.
    private let portsTicker = PollingTicker(interval: .seconds(2))

    // SwiftUI re-fires `.onAppear` on dock-reopen and File → New Window
    // because the WindowGroup content closure reruns; `startup()` is
    // one-time-per-launch (ghostty_init, pollers, observers). LAYOUT-5.3.
    @State private var didStartup = false

    init() {
        // Graftty is single-instance: the state.json, the graftty.sock
        // listener, and (most visibly) the per-pane zmx session names are
        // shared-global resources keyed off paths that don't vary between
        // app instances. Two Grafttys both attached to the same zmx
        // session will both echo the shell's output and both forward
        // keystrokes into the same PTY. Rather than isolate those three
        // resources per-instance (large refactor), we enforce one-at-a-time
        // here. Launch Services already dedupes normal Dock/Spotlight
        // opens; this guard catches `open -n` and same-bundle-id dev
        // relaunches.
        Self.terminateIfAnotherInstanceIsRunning()

        // ZMX-7.4: If Graftty.app was launched from a terminal that
        // was itself inside a zmx session, `ZMX_SESSION=<parent-name>`
        // is in the app's env. Host-managed native panes now route zmx
        // attach through `ZmxSpawnConfiguration`, which strips this per
        // spawn, but the app also launches other subprocesses. Strip the
        // leaky key globally before any surface or helper process spawns.
        ZmxLauncher.sanitizeProcessEnvironment()

        // Must run before any @AppStorage binding reads `teamEventRoutingPreferences`
        // (specifically the matrix in AgentTeamsSettingsPane) so SwiftUI binds
        // to the migrated value, not the default. TEAM-1.10.
        SettingsKeyMigration.run()

        // Must run before any UserDefaults read so non-binding readers see
        // the same defaults as @AppStorage. TEAM-1.6.
        UserDefaults.standard.register(defaults: DefaultPrompts.registrations)

        let loaded = AppState.loadOrFreshBackingUpCorruption(from: AppState.defaultDirectory)
        _appState = State(initialValue: loaded)

        let socketPath = AppState.defaultDirectory.appendingPathComponent("graftty.sock").path
        let terminalManager = TerminalManager(socketPath: socketPath)
        _terminalManager = StateObject(wrappedValue: terminalManager)
        let pairingAdmission = HostPairingAdmission()
        let appServices = AppServices(
            socketPath: socketPath,
            pairingAdmission: pairingAdmission
        )
        services = appServices

        // Web access server — reconstruct the same zmx paths that `startup()`
        // computes so the WebServerController's child `zmx attach` invocations
        // hit the same ZMX_DIR as panes spawned from the app UI. Keeping the
        // path derivation here (rather than routing it through AppServices)
        // keeps the controller's lifetime tied to the SwiftUI App via
        // @StateObject, which is what Settings scene re-entry expects.
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let zmxDir = appSupport
            .appendingPathComponent("Graftty", isDirectory: true)
            .appendingPathComponent("zmx", isDirectory: true)
        let zmxExe = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/zmx")
        let webController = WebServerController(
            settings: WebAccessSettings.shared,
            zmxExecutable: zmxExe,
            zmxDir: zmxDir,
            displayOwnershipStore: appServices.displayOwnershipStore
        )
        _webController = StateObject(wrappedValue: webController)
        _updaterController = StateObject(wrappedValue: UpdaterController())

        // R4: Construct the Mac-side WebRTC host agent. The dedicated
        // paired-access listener authenticates v2 offers with the device keys
        // before passing them to this agent, which opens SSH sessions over the
        // resulting DataChannel → zmx attach.
        let hostIdentityStore = HostIdentityStore(directory: HostIdentityStore.defaultDirectory)
        let trustedPeerStore = TrustedPeerStore(directory: TrustedPeerStore.defaultDirectory)
        self.trustedPeerStore = trustedPeerStore
        let sshConnectionRegistry = SSHConnectionRegistry()
        self.sshConnectionRegistry = sshConnectionRegistry

        do {
            let remoteMacsModel = appServices.remoteMacsModel
            appServices.hostAgent = WebRTCHostAgent(
                hostKey: try hostIdentityStore.loadOrGenerateAndPersist(),
                trustedPeerStore: trustedPeerStore,
                streamFactory: {
                    [registry = appServices.remoteAttachmentRegistry,
                     terminalManager] sessionName in
                    if sessionName.hasPrefix("relay-pane-") {
                        return try await remoteMacsModel.openRelayedTerminal(
                            alias: sessionName
                        )
                    }
                    let workingDirectoryPath = await MainActor.run {
                        terminalManager.worktreePath(
                            forSessionName: sessionName
                        )
                    }
                    let workingDirectory = workingDirectoryPath.map {
                        URL(fileURLWithPath: $0, isDirectory: true)
                    }
                    let engine = ZmxAttachEngine(config: ZmxAttachEngine.Config(
                        zmxExecutable: zmxExe,
                        zmxDir: zmxDir,
                        sessionName: sessionName,
                        workingDirectory: workingDirectory
                    ))
                    engine.attachmentRegistry = registry
                    try engine.start()
                    return engine
                },
                // R5 Task 11: init-time placeholder closures. The host
                // agent is constructed in `init()` (before SwiftUI `@State`
                // is accessible), then `startup()` calls
                // `setPanesStateSubscribe(_:)` and `setPaneControlMutator(_:)`
                // with the production wiring that actually reads from
                // `AppState`. The actor's FIFO ordering guarantees the
                // setter hops run before any `acceptOffer` hop, so no
                // incoming WebRTC offer ever sees these placeholders.
                panesStateSubscribe: { _ in
                    PanesStateChannelHandler.Cancellable(cancel: {})
                },
                paneControlMutator: { _ in
                    .error(code: "starting", message: "host not yet wired (startup did not run)")
                },
                displayOwnershipStore: appServices.displayOwnershipStore,
                sshConnectionRegistry: sshConnectionRegistry
            )
        } catch {
            // Identity-store I/O failure leaves hostAgent nil; the signaling
            // endpoint will serve 503. Log so a TestFlight crash dump or
            // console transcript surfaces the cause.
            NSLog("[Graftty] failed to construct WebRTCHostAgent: \(error)")
        }
    }

    /// If another Graftty process with our `CFBundleIdentifier` is
    /// already running, bring it to the front and exit our own process
    /// before any state, sockets, or zmx clients are created. Uses
    /// `exit(0)` instead of `NSApp.terminate` because we run before
    /// NSApplication has an app delegate, and because we have no
    /// allocated resources that need graceful teardown yet.
    private static func terminateIfAnotherInstanceIsRunning() {
        let myBundleID = Bundle.main.bundleIdentifier ?? "com.graftty.app"
        let myPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: myBundleID)
            .filter { $0.processIdentifier != myPID }
        guard let existing = others.first else { return }
        existing.activate()
        exit(0)
    }

    var body: some Scene {
        WindowGroup {
            MainWindow(
                appState: $appState,
                terminalManager: terminalManager,
                statsStore: services.statsStore,
                prStatusStore: services.prStatusStore,
                claudeSessionRegistry: services.claudeSessionRegistry,
                remoteBranchStore: services.remoteBranchStore,
                worktreeMonitor: services.worktreeMonitor,
                teamEventDispatcher: services.teamEventDispatcher,
                hostPairingCoordinator: services.hostPairingCoordinator,
                remoteMacsModel: services.remoteMacsModel,
                makeRemoteMacPairingDriver: services.remoteMacPairingDriverFactory
            )
                .environmentObject(webController)
                .environmentObject(updaterController)
                .environmentObject(portBindingsModel)
                .onAppear {
                    guard !didStartup else { return }
                    didStartup = true
                    startup()
                }
                .onChange(of: appState) { _, newState in
                    Self.persistAppState(newState)
                }
                .onOpenURL { url in
                    handleDeepLink(url)
                }
        }
        // Hide the macOS title bar so the breadcrumb row sits directly
        // under the traffic lights — Andy wanted a terminal-multiplexer
        // look, not a generic Cocoa app frame. Content can flow under
        // the title bar area; MainWindow leaves ~72pt of leading space
        // on the breadcrumb for the traffic lights.
        .windowStyle(.hiddenTitleBar)
        // Default size only. Restoration of the exact saved frame is handled
        // by WindowFrameTracker (see MainWindow), which applies the saved
        // NSWindow.frame directly after the window is created. We cannot use
        // SwiftUI's `.defaultPosition(_:)` for this because on macOS 14 it
        // takes a UnitPoint (normalized 0..1), not pixel coordinates — passing
        // pixel values is silently a no-op.
        .defaultSize(width: 1400, height: 900)
        .commands {
            let hostShortcutsByAction = NavigationCommandShortcutPolicy.hostShortcutWinners(
                commands: Self.macHostShortcutCommands,
                bridge: terminalManager.keybindBridge
            )

            CommandGroup(after: .newItem) {
                // "Add Repository..." keeps its hardcoded Cmd+Shift+O —
                // it's an Graftty-specific action with no Ghostty equivalent.
                Button("Add Repository...") {
                    // MainWindow handles the file picker via its own button.
                    // This menu item is a placeholder for the standard shortcut.
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                AddWorktreeCommandButton()

                Divider()

                ForEach(GhosttyCommandRegistry.macSplitActions, id: \.action) { command in
                    bridgedButton(command, shortcutsByAction: hostShortcutsByAction) {
                        handleGhosttyCommand(command)
                    }
                }

                Divider()

                ForEach(NavigationCommandShortcutPolicy.fixedPaneCommands, id: \.label) { command in
                    if let shortcut = KeyboardShortcutFromChord.shortcut(from: command.chord) {
                        Button(command.label) {
                            handleNavigateTreeOrder(forward: command.forward)
                        }
                        .keyboardShortcut(shortcut)
                    } else {
                        Button(command.label) {
                            handleNavigateTreeOrder(forward: command.forward)
                        }
                    }
                }

                ForEach(GhosttyCommandRegistry.macPaneFocusActions, id: \.action) { command in
                    bridgedButton(command, shortcutsByAction: hostShortcutsByAction) {
                        handleGhosttyCommand(command)
                    }
                }

                Divider()

                WorktreeNavCommandButtons()

                Divider()

                ForEach(GhosttyCommandRegistry.macPaneLayoutActions, id: \.action) { command in
                    bridgedButton(command, shortcutsByAction: hostShortcutsByAction) {
                        handleGhosttyCommand(command)
                    }
                }

                Divider()

                ForEach(GhosttyCommandRegistry.macPaneLifecycleActions, id: \.action) { command in
                    bridgedButton(command, shortcutsByAction: hostShortcutsByAction) {
                        handleGhosttyCommand(command)
                    }
                }
            }

            // TEAM-7.1: *Window → Team Activity Log* opens the activity
            // window for the focused worktree's team. Disabled when the
            // current selection has no team (single-worktree repo or
            // teams disabled). The button is hosted inside a tiny View
            // wrapper so it can read the `\.openWindow` environment
            // value, which is unavailable directly inside `.commands`.
            CommandGroup(after: .windowList) {
                TeamActivityLogMenuButton(appState: $appState)
            }

            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    updaterController.checkForUpdatesWithUI()
                }
                .disabled(!updaterController.canCheckForUpdates)

                Toggle("Automatically Check for Updates", isOn: Binding(
                    get: { updaterController.automaticallyChecksForUpdates },
                    set: { updaterController.automaticallyChecksForUpdates = $0 }
                ))

                Divider()

                Button("Install CLI Tool...") {
                    installCLI()
                }
                ForEach(GhosttyCommandRegistry.macSettingsActions, id: \.action) { command in
                    bridgedButton(command, shortcutsByAction: hostShortcutsByAction) {
                        handleGhosttyCommand(command)
                    }
                }
            }
        }

        // Settings scene — General pane, Web Access pane, and the unified
        // Agent Teams pane (absorbs Channels). WebServerController is injected
        // so WebSettingsPane can read `.status` / `.currentURL`, and so
        // toggling `WebAccessSettings.isEnabled` triggers the controller's
        // `reconcile()` via its Combine subscription.
        Settings {
            TabView {
                SettingsView(
                    onRestartZMX: { restartZMXWithConfirmation() },
                    editorPreference: terminalManager.editorPreference
                )
                    .tabItem { Label("General", systemImage: "gear") }
                WebSettingsPane(
                    pairingCoordinator: services.hostPairingCoordinator,
                    trustedPeerStore: trustedPeerStore,
                    sshConnectionRegistry: sshConnectionRegistry
                )
                    .environmentObject(webController)
                    .tabItem { Label("Web Access", systemImage: "network") }
                AgentTeamsSettingsPane()
                    .tabItem { Label("Agent Teams", systemImage: "person.2.fill") }
            }
        }

        // TEAM-7.1: Team Activity Log window. Opened via the *Window*
        // menu command (TEAM-7.1) and the sidebar's worktree-row
        // context menu (TEAM-7.2). The window's `for:` value is a
        // `TeamActivityLogWindowID` (Hashable+Codable) so SwiftUI can
        // route `openWindow(id:value:)` invocations and so each team
        // gets its own window instance keyed by team ID.
        WindowGroup(
            "Team Activity Log",
            id: TeamActivityLogWindowID.windowGroupID,
            for: TeamActivityLogWindowID.self
        ) { $boundID in
            if let boundID {
                TeamActivityLogWindow(
                    rootDirectory: AppState.defaultDirectory
                        .appendingPathComponent("team-inbox", isDirectory: true),
                    teamID: boundID.teamID,
                    teamName: boundID.teamName
                )
            } else {
                Text("No team selected.")
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(minWidth: 480, minHeight: 360)
            }
        }
    }

    /// Window-scoped `.onChange` handles normal UI mutations. Background
    /// services also call this directly because they remain active after the
    /// last window closes and therefore cannot rely on a live view observer.
    fileprivate static func persistAppState(_ state: AppState) {
        do {
            try state.save(to: AppState.defaultDirectory)
        } catch {
            // Silently dropping this error means a full disk, read-only
            // `$HOME`, or permissions clash silently stops persistence.
            // STATE-6.2 / PERSIST-2.2.
            NSLog("[Graftty] AppState.save failed: %@", String(describing: error))
        }
    }

    /// @spec URL-2.1: When the macOS app opens a `graftty://open` URL
    /// that resolves to a tracked worktree, the application shall select
    /// that worktree, focus the resolved pane when one is present and the
    /// worktree is running, and bring the app to the foreground.
    private func handleDeepLink(_ url: URL) {
        guard let target = GrafttyDeepLink.parse(url) else { return }
        guard case let .resolved(path, paneSlot) = DeepLinkResolver.resolve(target, inRepos: appState.repos) else {
            return
        }
        appState.selectedWorktreePath = path
        if let paneSlot,
           let wt = appState.worktree(forPath: path),
           wt.state == .running, wt.paneSessions[paneSlot] != nil {
            appState.setFocusedTerminal(paneSlot, forWorktreePath: path)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func startup() {
        let zmxBinary = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/zmx")
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let zmxDir = appSupport
            .appendingPathComponent("Graftty", isDirectory: true)
            .appendingPathComponent("zmx", isDirectory: true)
        try? FileManager.default.createDirectory(at: zmxDir, withIntermediateDirectories: true)
        let zmxLauncher = ZmxLauncher(executable: zmxBinary, zmxDir: zmxDir)
        terminalManager.zmxLauncher = zmxLauncher
        Task { @MainActor in
            await services.remoteMacsModel.loadSavedRemotes()
        }

        // TERM-11.5: pane backends consult the registry to decide whether
        // the IOS-12.1 silent gate applies (remote client attached to the
        // same zmx session).
        terminalManager.remoteAttachmentRegistry = services.remoteAttachmentRegistry
        terminalManager.displayOwnershipStore = services.displayOwnershipStore
        services.remoteAttachmentRegistry.onLastDetach = { [weak terminalManager] sessionName in
            // TERM-11.4: fires on the detaching connection's thread; hop to
            // the main actor where TerminalManager lives.
            Task { @MainActor in
                terminalManager?.remoteClientsDetached(fromSession: sessionName)
            }
        }

        // Hand the scanner to TerminalManager so pane add/close flows
        // propagate registration, then wire the scanner's onChange into
        // PortBindingsModel so SidebarView re-renders chips when a
        // pane's listening sockets change.
        terminalManager.portScanner = portScanner
        let tmRef = terminalManager
        Task {
            await portScanner.setOnChange { [weak portBindingsModel] id, list in
                portBindingsModel?.set(id, list)
            }
            // PORTS-4.5: panes registered before zmx wrote their `pty
            // spawned` log line need their PID resolved later.
            // `[weak]` breaks the cycle through TerminalManager.portScanner.
            await portScanner.setPIDResolver { [weak tmRef] id in
                await tmRef?.lookupShellPID(for: id)
            }
        }

        // 2s cadence for port-binding scans. Cheap (one batched lsof
        // across all registered shell PIDs per tick) and only meaningful
        // while the app is up; pause when inactive is the default.
        portsTicker.start { [portScanner] in
            await portScanner.tick()
        }

        // Wrappers always go on PATH; the Agent Teams toggle is read inside
        // the wrapper at request time.
        Self.installAgentHookAssets()

        // One-shot cleanup of the retired graftty-channel MCP integration
        // (TEAM-8.1 / TEAM-8.2 / TEAM-8.3). Runs idempotently every launch
        // until we drop it in a few releases.
        Task { await LegacyChannelCleanup.run() }

        // Strip the legacy `--dangerously-load-development-channels
        // server:graftty-channel` substring from `defaultCommand` and
        // disclose the change once via NSAlert. Runs on the main actor
        // so the modal alert can sit on the run loop after `startup()`
        // returns (TEAM-8.4).
        Task { @MainActor in
            if LegacyChannelCleanup.scrubDefaultCommandLaunchFlag() {
                let alert = NSAlert()
                alert.messageText = "Legacy launch flag removed"
                alert.informativeText = "Removed --dangerously-load-development-channels server:graftty-channel from your default command. Agent teams now run via the unified hook adapter."
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }

        if !zmxLauncher.isAvailable {
            DispatchQueue.main.async {
                ZmxFallbackBanner.presentIfNeeded()
            }
        }

        terminalManager.initialize()
        AgentNotificationRouter.shared.install()
        AgentNotificationRouter.shared.onActivate = { [appState = $appState, tm = terminalManager] payload in
            Self.activateAgentStopNotification(
                payload,
                appState: appState,
                terminalManager: tm
            )
        }
        services.remoteMacsModel.onRemoteNotification = {
            AgentNotificationRouter.shared.post($0)
        }
        AgentNotificationRouter.shared.onActivateRemote = {
            [remoteMacsModel = services.remoteMacsModel] event in
            NSApp.activate(ignoringOtherApps: true)
            remoteMacsModel.activateRemoteNotification(event)
        }

        terminalManager.editorPreference = EditorPreference(
            defaults: .standard,
            shellEnvProbe: LoginShellEnvProbe()
        )

        // Route context-menu split requests through the same insertion code
        // path that Cmd+D uses, but targeting the *menu's* surface rather
        // than the currently-focused one — the two can differ if the user
        // right-clicks an unfocused pane.
        terminalManager.onSplitRequest = { [appState = $appState, tm = terminalManager] terminalID, direction in
            MainActor.assumeIsolated {
                if tm.routeHostManagedPaneCommand(
                    .split(direction),
                    for: terminalID
                ) {
                    return
                }
                _ = Self.splitPane(
                    appState: appState,
                    terminalManager: tm,
                    targetID: terminalID,
                    split: direction
                )
            }
        }

        terminalManager.onOpenInEditorPane = { [appState = $appState, tm = terminalManager] terminalID, initialInput in
            Task { @MainActor in
                _ = Self.splitPane(
                    appState: appState,
                    terminalManager: tm,
                    targetID: terminalID,
                    split: .right,
                    extraInitialInput: initialInput
                )
            }
        }

        // TERM-8.10 / PWD-1.4: terminal surface menu and sidebar drag
        // both route through this callback to share the existing
        // PWD-2.x reassignment pipeline.
        terminalManager.onMovePane = { [appState = $appState, tm = terminalManager] terminalID, destinationPath in
            MainActor.assumeIsolated {
                Self.reassignPaneByPWD(
                    appState: appState,
                    terminalManager: tm,
                    terminalID: terminalID,
                    newPWD: destinationPath
                )
            }
        }

        // Surface menu (`SurfaceContextMenu`) calls this at right-click
        // time so the snapshot is fresh; nil makes it skip the Move
        // section (e.g. mid-reassignment race window).
        let paneMoveRemoteBranchStore = services.remoteBranchStore
        terminalManager.currentPaneMoveContext = { [appState = $appState, tm = terminalManager] terminalID in
            MainActor.assumeIsolated {
                let state = appState.wrappedValue
                let defaultBranches = PaneMoveMenuContext.defaultBranches(
                    for: state.repos,
                    using: paneMoveRemoteBranchStore
                )
                return PaneMoveMenuContext.resolve(
                    terminalID: terminalID,
                    appState: state,
                    shellCwd: tm.shellCwd(for: terminalID),
                    defaultBranchesByRepoPath: defaultBranches
                )
            }
        }

        // A user-issued close action targets the pane that emitted it.
        terminalManager.onCloseRequest = { [appState = $appState, tm = terminalManager] terminalID in
            MainActor.assumeIsolated {
                if tm.routeHostManagedPaneCommand(.close, for: terminalID) {
                    return
                }
                switch paneCloseAction() {
                case .closePane:
                    Self.closePane(
                        appState: appState,
                        terminalManager: tm,
                        targetID: terminalID,
                        userInitiated: true
                    )
                }
            }
        }

        // A surface can also disappear because its shell exited or, for a
        // host-managed proxy, its transport dropped. Keep that distinct from
        // user close so a network failure cannot kill the owning Mac's pane.
        terminalManager.onSurfaceClosed = {
            [appState = $appState, tm = terminalManager] terminalID in
            MainActor.assumeIsolated {
                if tm.routeHostManagedPaneCommand(
                    .surfaceClosed,
                    for: terminalID
                ) {
                    return
                }
                Self.closePane(
                    appState: appState,
                    terminalManager: tm,
                    targetID: terminalID
                )
            }
        }

        terminalManager.onGotoSplit = { [appState = $appState, tm = terminalManager] terminalID, direction in
            MainActor.assumeIsolated {
                if tm.routeHostManagedPaneCommand(
                    .focus(direction),
                    for: terminalID
                ) {
                    return
                }
                Self.navigatePane(
                    appState: appState,
                    terminalManager: tm,
                    from: terminalID,
                    direction: direction
                )
            }
        }

        terminalManager.onGotoSplitOrder = { [appState = $appState, tm = terminalManager] terminalID, forward in
            MainActor.assumeIsolated {
                if tm.routeHostManagedPaneCommand(
                    .focusOrder(forward: forward),
                    for: terminalID
                ) {
                    return
                }
                Self.navigatePaneInTreeOrder(
                    appState: appState,
                    terminalManager: tm,
                    from: terminalID,
                    forward: forward
                )
            }
        }

        terminalManager.onToggleZoom = { [appState = $appState, tm = terminalManager] terminalID in
            MainActor.assumeIsolated {
                if tm.routeHostManagedPaneCommand(
                    .toggleZoom,
                    for: terminalID
                ) {
                    return
                }
                Self.toggleZoom(appState: appState, on: terminalID)
            }
        }

        terminalManager.onResizeSplit = { [appState = $appState, tm = terminalManager] terminalID, direction, amount in
            MainActor.assumeIsolated {
                if tm.routeHostManagedPaneCommand(
                    .resize(direction: direction, amount: amount),
                    for: terminalID
                ) {
                    return
                }
                Self.resizeSplit(
                    appState: appState,
                    target: terminalID,
                    direction: direction,
                    pixels: amount
                )
            }
        }

        terminalManager.onEqualizeSplits = { [appState = $appState, tm = terminalManager] terminalID in
            MainActor.assumeIsolated {
                if tm.routeHostManagedPaneCommand(
                    .equalize,
                    for: terminalID
                ) {
                    return
                }
                Self.equalizeSplits(appState: appState, around: terminalID)
            }
        }

        // `ghostty_app_update_config` re-reads the config files and swaps
        // them into the live app; our bridge rebuild happens inside
        // `reloadGhosttyConfig`. TERM-9.1.
        terminalManager.onReloadConfig = { [tm = terminalManager] in
            MainActor.assumeIsolated {
                tm.reloadGhosttyConfig()
            }
        }

        // Ghostty keybind mapped to `open_config` → same flow as the
        // "Open Ghostty Settings" menu item: resolve the config path,
        // create it if missing, hand to NSWorkspace. TERM-9.2.
        terminalManager.onOpenConfig = {
            MainActor.assumeIsolated {
                Self.openGhosttySettings()
            }
        }

        // Shell integration semantic pings → sidebar attention badge on
        // the owning worktree. The badge is auto-clearing (3s) so it
        // behaves like a "ping", not a permanent state the user has to
        // dismiss. Non-zero exit codes get a longer (8s) dwell so the
        // user has a chance to notice errors across a worktree they're
        // not currently viewing.
        terminalManager.onCommandFinished = { [appState = $appState] terminalID, exitCode, _ in
            MainActor.assumeIsolated {
                Self.setAttentionForTerminal(
                    appState: appState,
                    terminalID: terminalID,
                    text: exitCode == 0 ? "✓" : "!",
                    clearAfter: exitCode == 0 ? 3 : 8,
                    source: .commandFinished
                )
            }
        }
        // PROGRESS_REPORT intentionally unhandled — shell-integration
        // progress pings (OSC 9;4 from tools emitting indeterminate or
        // percent status) were too loud relative to the urgency they
        // convey. The underlying plumbing in TerminalManager stays
        // wired; we can revisit with a dedicated, less-aggressive
        // visual if the need comes back.

        // First prompt on a newly-ready pane → maybe type the user's
        // default command. `maybeRunDefaultCommand` consults UserDefaults
        // and the TerminalManager's first-pane / rehydration markers to
        // decide; most of the time it's a no-op.
        terminalManager.onShellReady = { [tm = terminalManager] terminalID in
            MainActor.assumeIsolated {
                Self.maybeRunDefaultCommand(
                    terminalManager: tm,
                    terminalID: terminalID
                )
            }
        }

        do {
            try services.socketServer.start()
        } catch let error as SocketServerError {
            // Surface the failure in Console.app AND present a one-time
            // banner so the user sees it immediately rather than learning
            // about it later via a "not listening" CLI error (ATTN-3.4).
            NSLog("[Graftty] SocketServer.start() failed: %@", String(describing: error))
            DispatchQueue.main.async {
                NotifySocketBanner.presentIfNeeded(error: error)
            }
        } catch {
            NSLog("[Graftty] SocketServer.start() failed: %@", String(describing: error))
        }

        // Wire the AppState provider for the team PR-merged dispatch hook
        // (TEAM-5.4). @State is only accessible once SwiftUI's body has
        // run, so we capture a Binding here rather than in
        // AppServices.init().
        let channelAppStateBinding = $appState
        services.appStateProvider = { channelAppStateBinding.wrappedValue }

        // SocketServer already dispatches onMessage to the main queue.
        let binding = $appState
        let tm = terminalManager
        services.socketServer.onMessage = { message in
            MainActor.assumeIsolated {
                Self.handleNotification(message, appState: binding, terminalManager: tm)
            }
        }
        let teamInbox = services.teamInbox
        let teamEventDispatcher = services.teamEventDispatcher
        services.socketServer.onAsyncRequest = { message in
            await Self.handlePaneRequest(
                message,
                appState: binding,
                terminalManager: tm,
                teamInbox: teamInbox,
                teamEventDispatcher: teamEventDispatcher,
                worktreeMonitor: services.worktreeMonitor,
                statsStore: services.statsStore,
                prStatusStore: services.prStatusStore,
                worktreeCreations: services.cliWorktreeCreations,
                worktreeRemovals: services.cliWorktreeRemovals,
                remoteBranchStore: services.remoteBranchStore
            )
        }

        let remoteBranchStore = services.remoteBranchStore
        let prStatusStore = services.prStatusStore
        remoteBranchStore.onChange = { repoPath, old, new in
            guard let repo = binding.wrappedValue.repos.first(where: { $0.path == repoPath }) else { return }
            RemoteBranchPRRefreshRouter.route(
                repo: repo,
                oldBranches: old,
                newBranches: new,
                clear: { prStatusStore.clear(worktreePath: $0) },
                pulseRepo: { prStatusStore.pulse(repoPath: $0) }
            )
        }

        let bridge = WorktreeMonitorBridge(
            appState: $appState,
            statsStore: services.statsStore,
            prStatusStore: services.prStatusStore,
            remoteBranchStore: services.remoteBranchStore
        )
        services.worktreeMonitorBridge = bridge
        services.worktreeMonitor.delegate = bridge
        for repo in appState.repos {
            services.worktreeMonitor.installRepoWatchers(repo: repo)
        }

        // Deleted worktrees remain visible for a one-hour recovery window:
        // transient filesystem events and same-path re-adds can resurrect
        // them during that time. The persisted `staleSince` timestamp makes
        // the deadline survive relaunches. Keep ticking in the background
        // because the deletion may occur while the user is working in a
        // different app; the next tick after wake handles system sleep. Do
        // not start its immediate first tick until launch reconciliation has
        // had a chance to resurrect or relocate recoverable stale entries.
        let staleWorktreeAutoDismissTicker = PollingTicker(
            interval: .seconds(30),
            pauseWhenInactive: { false }
        )
        let autoDismissPRStatusStore = services.prStatusStore
        let autoDismissStatsStore = services.statsStore
        services.staleWorktreeAutoDismissTicker = staleWorktreeAutoDismissTicker
        reconcileOnLaunch {
            staleWorktreeAutoDismissTicker.start {
                _ = await StaleWorktreeDismissal.dismissExpired(
                    appState: binding,
                    now: Date(),
                    discoverWorktrees: { repo in
                        if !repo.isGitTracked,
                           !FileManager.default.fileExists(atPath: repo.path) {
                            return []
                        }
                        return try await WorktreeDiscovery.discover(repo: repo)
                    },
                    destroySurfaces: {
                        tm.destroySurfaces(terminalIDs: $0)
                    },
                    clearPRStatus: {
                        autoDismissPRStatusStore.clear(worktreePath: $0)
                    },
                    clearStats: {
                        autoDismissStatsStore.clear(worktreePath: $0)
                    },
                    onDismiss: {
                        Self.persistAppState($0)
                    }
                )
            }
        }

        // Start the stats safety-net poller: HEAD and origin-ref events
        // provide the prompt path, while this 5s ticker catches
        // coalesced or missed filesystem events. Per-repo, it gates the
        // 30-second `git fetch` cadence (DIVERGE-4.3); otherwise it rotates
        // through four running worktrees per tick (DIVERGE-4.6 / PERF-1.11).
        // Keeps polling while Graftty is backgrounded (DIVERGE-4.8) —
        // the user's Claude / editor session is often in a different
        // frontmost app, and that's exactly when a `git add` in an
        // external shell or a merge on origin needs to show up in the
        // sidebar without requiring a click back into Graftty first.
        let statsTicker = PollingTicker(
            interval: .seconds(5),
            pauseWhenInactive: { false }
        )
        services.statsStore.start(
            ticker: statsTicker,
            getRepos: { [appState] in appState.repos }
        )

        // Local remote-ref scans seed PR polling's pushed-branch gate. Each
        // scan is one `git for-each-ref`, and the ticker rotates through four
        // repos per tick. PollingTicker fires immediately, so `start` seeds
        // the first batch without a second explicit refresh pass; onChange
        // pulses PR polling as results land.
        let remoteBranchTicker = PollingTicker(
            interval: .seconds(10),
            pauseWhenInactive: { false }
        )
        services.remoteBranchStore.start(
            ticker: remoteBranchTicker,
            getRepos: { binding.wrappedValue.repos }
        )

        // The PR poller drives `gh pr list`, a GraphQL call metered
        // against a separate 5,000-point/hour budget. Unlike the stats
        // poller's local `git fetch`, every tick here costs API quota,
        // so the per-repo cadence gate is 60s (see
        // `PRStatusStore.cadenceFor`) — a 5s cadence exhausted the
        // entire GraphQL budget on a single repo. The ticker keeps
        // firing while Graftty is backgrounded (PR-7.6): `gh pr list`
        // is the only channel for an open→merged transition that
        // happens on GitHub without a local `git fetch`, and at 60s the
        // background cost is genuinely negligible. The 60s cadence is a
        // per-repo eligibility floor; ordinary ticks rotate through four
        // repos at a time, so larger workspaces trade additional safety-net
        // latency for bounded query volume. Explicit pulses still cover every
        // repo, while remote-ref changes pulse only their affected repo.
        let prTicker = PollingTicker(
            interval: .seconds(30),
            pauseWhenInactive: { false }
        )
        services.prStatusStore.start(
            ticker: prTicker,
            getRepos: { binding.wrappedValue.repos }
        )

        // Poll `claude agents --json` on a fast cadence to derive per-pane
        // busy/idle liveness. The registry retains this ticker internally
        // (like prStatusStore), so the local var is sufficient — the
        // registry itself outlives startup() via AppServices.
        let claudeAgentsTicker = PollingTicker(interval: .seconds(2))
        // AGENT-3.4: apply the resume rule at the model layer on every
        // liveness change, so the iPad/web snapshot and the headless
        // (window-closed) case stay consistent — not just the on-screen
        // Mac sidebar.
        services.claudeSessionRegistry.onLivenessChange = { [appState = $appState] liveness in
            appState.wrappedValue.clearAgentStopAttentionForBusyPanes(liveness: liveness)
        }
        services.claudeSessionRegistry.start(ticker: claudeAgentsTicker)

        // Sweep dangling presence files left behind by SIGKILL'd agents
        // whose wrapper trap never fired. The wrapper trap is the primary
        // cleanup path (TEAM-PRESENCE-1.3); this fallback runs on a slow
        // cadence and only deletes records whose recorded PID is no
        // longer alive per `kill(pid, 0)` semantics. Continues while
        // backgrounded for the same reason the stats poller does:
        // agent processes can die at any time and Graftty might not be
        // frontmost when it happens.
        let presenceTicker = PollingTicker(
            interval: .seconds(30),
            pauseWhenInactive: { false }
        )
        services.presenceCleanupTicker = presenceTicker
        let presenceStorage = TeamPresenceStorage(
            rootDirectory: TeamPresenceStorage.defaultRoot()
        )
        let presenceIndex = TeamPresenceIndex(
            records: (try? presenceStorage.listAll()) ?? []
        )
        func refreshPresenceIndex() -> [TeamPresenceRecord] {
            let records = (try? presenceStorage.listAll()) ?? []
            presenceIndex.replace(with: records)
            return records
        }

        let livePaneSessionNames = LivePaneSessionNames()
        func refreshDeliveryLiveness(records: [TeamPresenceRecord]? = nil) {
            let records = records ?? refreshPresenceIndex()
            let names = Self.livePaneSessionNamesForAutomaticDelivery(
                records: records,
                terminalManager: tm
            )
            livePaneSessionNames.replace(with: names)
        }

        let codexAppServerDeliveryService = CodexAppServerDeliveryService(
            inbox: services.teamInbox,
            presenceRecords: { (try? presenceStorage.listAll()) ?? [] },
            sessionStorage: CodexAppServerSessionStorage(rootDirectory: TeamPresenceStorage.defaultRoot()),
            liveness: AppTeamDeliveryLiveness(
                livePaneSession: { livePaneSessionNames.contains($0) },
                processStartTimeMicroseconds: { ProcessIdentityReader.startTimeMicroseconds(ofPID: $0) }
            ),
            client: CodexAppServerClient()
        )
        presenceTicker.start {
            TeamPresenceMonitor.cleanupStale(storage: presenceStorage)
            let records = refreshPresenceIndex()
            refreshDeliveryLiveness(records: records)
            await Self.retryCodexAppServerDeliveryForPresenceWorktrees(
                inbox: services.teamInbox,
                records: records,
                delivery: codexAppServerDeliveryService
            )
        }

        // Subscribe Codex app-server delivery to inbox file-system events.
        // TeamInboxObserver fires with the full message list on every
        // append. We track the previous count and fire onMessageArrival
        // only when new messages arrive, to avoid redundant delivers.
        // We watch each team's inbox for all repos that exist at startup time;
        // the watcher self-heals for the file-not-yet-created case via the
        // directory watch inside TeamInboxObserver.
        let inboxRoot = AppState.defaultDirectory
            .appendingPathComponent("team-inbox", isDirectory: true)
        for repo in binding.wrappedValue.repos {
            let teamID = repo.path
            let observer = TeamInboxObserver(rootDirectory: inboxRoot, teamID: teamID)
            // Per-observer state claims message ranges before awaiting
            // app-server delivery. `TeamInboxObserver` callbacks can overlap
            // once they hop through Task/MainActor, so the actor owns the
            // count update.
            // (A previous version used a shared `[String: Int]` map across
            // all observer closures and crashed under concurrent mutation
            // by multiple observer queues — Swift Dictionary is not
            // thread-safe.)
            let deliveryState = CodexAppServerInboxObserverDeliveryState(skipInitialSnapshot: true)
            let cancellable = observer.start { [weak codexAppServerDeliveryService] messages in
                Task { @MainActor in
                    refreshDeliveryLiveness()
                    guard let service = codexAppServerDeliveryService else {
                        await deliveryState.markSeen(messages)
                        return
                    }
                    let recipientWorktrees = await deliveryState.claimRecipientWorktrees(in: messages)
                    await Self.deliverCodexAppServerMessages(
                        teamID: teamID,
                        recipientWorktrees: recipientWorktrees,
                        delivery: service
                    )
                }
            }
            services.inboxObserverCancellables.append(cancellable)
            services.inboxObservers.append(observer)
        }

        // Persist the delivery service on AppServices so it outlives startup().
        services.codexAppServerDeliveryService = codexAppServerDeliveryService

        // When a pane is destroyed, sweep any TeamPresenceRecord whose
        // paneSessionName matches the closing pane. The agent's own
        // `team unregister` cleanup hook is the primary path; this fallback
        // covers the SIGKILL / hard-quit case where the pane went away
        // without the registered process getting a chance to clean up.
        tm.paneClosed = { [presenceStorage] _, sessionName in
            guard let sessionName else { return }
            _ = refreshPresenceIndex()
            for record in presenceIndex.records(forPaneSessionName: sessionName) {
                try? presenceStorage.delete(
                    teamID: record.teamID,
                    worktree: record.worktree,
                    runtime: record.runtime,
                    paneSessionName: record.paneSessionName
                )
                presenceIndex.remove(
                    teamID: record.teamID,
                    worktree: record.worktree,
                    runtime: record.runtime,
                    paneSessionName: record.paneSessionName
                )
            }
            let records = presenceIndex.allRecords()
            refreshDeliveryLiveness(records: records)
            Task {
                await Self.retryCodexAppServerDeliveryForPresenceWorktrees(
                    inbox: services.teamInbox,
                    records: records,
                    delivery: codexAppServerDeliveryService
                )
            }
        }

        restoreRunningWorktrees()

        // Restoring running worktrees installs the durable pane-to-session
        // mappings used by automatic delivery liveness. Refresh only after
        // those mappings exist, then retry unread rows from while the app was
        // down; otherwise a background owner can be skipped until the
        // 30-second presence ticker runs.
        let restoredPresenceRecords = refreshPresenceIndex()
        refreshDeliveryLiveness(records: restoredPresenceRecords)
        Task {
            await Self.retryCodexAppServerDeliveryForPresenceWorktrees(
                inbox: services.teamInbox,
                records: restoredPresenceRecords,
                delivery: codexAppServerDeliveryService
            )
        }

        // TERM-11.5: WebSocket `/ws` sessions report attach/detach into the
        // shared registry so Mac pane backends can see web-client attaches.
        webController.setRemoteAttachmentRegistry(services.remoteAttachmentRegistry)

        webController.setGhosttyKeybindingsProvider { [tm = terminalManager] in
            await MainActor.run { tm.keybindBridge.allChords }
        }

        // WEB-5.4: feed the web server a snapshot of running sessions on
        // each GET /sessions request. Binding snapshot is read on the
        // main actor; worktree names are routed through
        // `SidebarWorktreeLabel.text` so the iOS session picker matches
        // every other sidebar-adjacent surface — most notably, the main
        // checkout renders as the resolved default branch, not the
        // directory basename.
        let appStateBinding = $appState
        let panesRemoteBranchStore = services.remoteBranchStore
        webController.setSessionsProvider {
            await MainActor.run { () -> [SessionInfo] in
                var sessions: [SessionInfo] = []
                for repo in appStateBinding.wrappedValue.repos {
                    let siblingPaths = repo.worktrees.map(\.path)
                    let defaultBranch = panesRemoteBranchStore.resolvedDefaultBranch(
                        forRepoAt: repo.path,
                        hint: repo.defaultBranchHint
                    )
                    for wt in repo.worktrees where wt.state == .running {
                        let worktreeDisplayName = SidebarWorktreeLabel.text(
                            for: wt,
                            inRepoAtPath: repo.path,
                            siblingPaths: siblingPaths,
                            defaultBranch: defaultBranch
                        )
                        for leafID in wt.splitTree.allLeaves {
                            guard let sessionID = wt.paneSessions[leafID] else { continue }
                            let sessionName = ZmxLauncher.sessionName(for: sessionID)
                            sessions.append(SessionInfo(
                                name: sessionName,
                                worktreePath: wt.path,
                                repoDisplayName: repo.displayName,
                                worktreeDisplayName: worktreeDisplayName
                            ))
                        }
                    }
                }
                return sessions
            }
        }

        // Web/iOS attaches spawn their own `zmx attach` process. If that
        // attach wins the race to create a new zmx daemon, its cwd becomes
        // the daemon's shell cwd, so resolve the pane back to its worktree.
        webController.setSessionWorktreeProvider { sessionName in
            await MainActor.run { () -> String? in
                for repo in appStateBinding.wrappedValue.repos {
                    for wt in repo.worktrees where wt.state == .running {
                        for leafID in wt.splitTree.allLeaves
                        where wt.paneSessions[leafID].map(ZmxLauncher.sessionName(for:)) == sessionName {
                            return wt.path
                        }
                    }
                }
                return nil
            }
        }

        // IOS-4.10: per-worktree pane trees + titles for the mobile
        // client's sidebar mirror. Includes non-running worktrees so
        // closed/stale/creating rows render their state via icon +
        // color, same as on macOS.
        //
        // Hoisted out of `setWorktreePanesProvider` so the R5 SSH
        // `panes-state@graftty.dev` channel can re-use the same snapshot
        // shape. The two consumers (`/worktrees/panes` HTTP poll and
        // `panes-state` SSH channel) MUST produce identical envelopes
        // so the iPad's sidebar renders the same regardless of transport.
        let terminalManager = tm
        let panesStatsStore = services.statsStore
        let panesPRStore = services.prStatusStore
        let panesClaudeRegistry = services.claudeSessionRegistry
        let localWorktreeOrigin = WorktreeOrigin(
            deviceID: AppServices.localRemoteDeviceID(),
            deviceLabel: AppServices.localHostDisplayName(),
            relayDepth: 0
        )
        let buildWorktreePanesSnapshot: @Sendable @MainActor () -> [WorktreePanes] = {
            var out: [WorktreePanes] = []
            for repo in appStateBinding.wrappedValue.repos {
                let defaultBranch = panesRemoteBranchStore.resolvedDefaultBranch(
                    forRepoAt: repo.path,
                    hint: repo.defaultBranchHint
                )
                let labels = SidebarWorktreeLabel.texts(
                    for: repo.worktrees,
                    inRepoAtPath: repo.path,
                    defaultBranch: defaultBranch
                )
                for wt in repo.worktrees {
                    let stats = wt.state.hasOnDiskWorktree
                        ? panesStatsStore.stats[wt.path]
                        : nil
                    out.append(WorktreePanes(
                        path: wt.path,
                        displayName: labels[wt.id] ?? "",
                        repoDisplayName: repo.displayName,
                        repositoryID: repo.path,
                        displayBranch: wt.displayBranch,
                        state: WorktreeWireState(wt.state),
                        isMainCheckout: wt.path == repo.path,
                        prBadge: panesPRStore.infos[wt.path].map(PRBadge.init(from:)),
                        stats: stats?.toWire(),
                        attentionText: wt.attention?.text,
                        attentionSource: wt.attention?.source,
                        attentionTimestamp: wt.attention?.timestamp,
                        layout: (wt.state == .running ? wt.splitTree.root : nil)
                            .map {
                                paneLayoutNode(
                                    from: $0,
                                    paneSessions: wt.paneSessions,
                                    titles: terminalManager.titles,
                                    paneAttention: wt.paneAttention,
                                    liveness: panesClaudeRegistry.livenessBySession
                                )
                            },
                        origin: localWorktreeOrigin
                    ))
                }
            }
            return out
        }
        webController.setWorktreePanesProvider {
            await MainActor.run { buildWorktreePanesSnapshot() }
        }
        webController.setRelayedWorktreePanesProvider {
            await services.remoteMacsModel.promotedWorktreesForRelay()
        }

        let statsStore = services.statsStore

        // WEB-7.1: feed the web server the repo list for the "Add
        // Worktree" picker. Mirrors the native sidebar's top-level
        // repos.
        webController.setReposProvider {
            await MainActor.run { () -> [WebServer.RepoInfo] in
                appStateBinding.wrappedValue.repos.map { repo in
                    WebServer.RepoInfo(
                        path: repo.path,
                        displayName: repo.displayName,
                        defaultBranchStatus: defaultBranchStatus(
                            for: repo,
                            stats: statsStore.stats[repo.path]
                        ),
                        origin: localWorktreeOrigin
                    )
                }
            }
        }
        webController.setRelayedReposProvider {
            await services.remoteMacsModel
                .promotedRepositoriesForRelay()
                .map { repository in
                    WebServer.RepoInfo(
                        path: repository.id,
                        displayName: repository.displayName,
                        defaultBranchStatus: repository.defaultBranchStatus.map {
                            .init(
                                branchName: $0.branchName,
                                remoteRef: $0.remoteRef,
                                behindCount: $0.behindCount
                            )
                        },
                        branches: repository.branches,
                        origin: repository.origin
                    )
                }
        }

        // WEB-7.2: drive `POST /worktrees` into the shared
        // `AddWorktreeFlow`. `AddWorktreeFlow.add` is itself
        // `@MainActor`; calling it from this non-isolated async closure
        // inserts an implicit hop, so every write to appState and every
        // terminal-surface creation happens on the main actor — same
        // isolation as the native sidebar's "+" button.
        let worktreeMonitor = services.worktreeMonitor
        let dispatcherForWeb = services.teamEventDispatcher
        webController.setDefaultBranchPuller { req in
            let pullTarget = await MainActor.run {
                guard let repo = appStateBinding.wrappedValue.repos.first(where: { $0.path == req.repoPath }) else {
                    return (tracked: false, status: nil as WebServer.RepoInfo.DefaultBranchStatus?)
                }
                return (tracked: true, status: defaultBranchStatus(
                    for: repo,
                    stats: statsStore.stats[repo.path]
                ))
            }
            guard pullTarget.tracked else {
                return .invalid("repository not tracked")
            }
            guard let status = pullTarget.status else {
                return .invalid("default checkout is not behind origin")
            }
            do {
                try await GitDefaultBranchPull.pull(repoPath: req.repoPath, branchName: status.branchName)
            } catch GitDefaultBranchPull.Error.gitFailed(_, let stderr) {
                return .gitFailed(stderr)
            } catch {
                return .internalFailure("\(error)")
            }
            await MainActor.run {
                guard let repo = appStateBinding.wrappedValue.repos.first(where: { $0.path == req.repoPath }) else {
                    return
                }
                let branch = repo.worktrees.first(where: { $0.path == repo.path })?.branch ?? ""
                statsStore.refresh(worktreePath: repo.path, repoPath: repo.path, branch: branch)
            }
            return .success(WebServer.PullDefaultBranchResponse(ok: true))
        }
        webController.setWorktreeCreator { req in
            let branch: BranchSelection
            if req.existing {
                branch = .useExisting(name: req.branchName, source: .local)
            } else {
                branch = .createNew(name: req.branchName)
            }
            let result = await AddWorktreeFlow.add(
                repoPath: req.repoPath,
                worktreeName: req.worktreeName,
                branch: branch,
                appState: appStateBinding,
                worktreeMonitor: worktreeMonitor,
                statsStore: statsStore,
                terminalManager: tm,
                teamEventDispatcher: dispatcherForWeb
            )
            switch result {
            case .success(let outcome):
                return .success(WebServer.CreateWorktreeResponse(
                    sessionName: outcome.sessionName,
                    worktreePath: outcome.worktreePath
                ))
            case .failure(let err):
                switch err {
                case .gitFailed(let msg): return .gitFailed(msg)
                case .repoNotFound: return .invalid("repository not tracked")
                case .pathCollision: return .invalid("a worktree at that name already exists")
                case .branchAlreadyMounted:
                    return .conflict(message: err.userMessage ?? "branch already mounted")
                case .invalidInput(let msg): return .invalid(msg)
                case .discoveryFailed(let msg): return .internalFailure(msg)
                }
            }
        }

        // WEB-7.8: drive `POST /worktrees/delete` into the shared
        // `DeleteWorktreeFlow`. Mirrors the create wiring above —
        // closure runs on `MainActor` via `DeleteWorktreeFlow.delete`'s
        // `@MainActor` isolation, so every `appState` mutation and
        // surface teardown lands on the main actor, same as the native
        // sidebar's "Delete Worktree" path.
        webController.setWorktreeRemover { req in
            let result = await DeleteWorktreeFlow.delete(
                worktreePath: req.worktreePath,
                force: req.force,
                appState: appStateBinding,
                terminalManager: tm,
                statsStore: statsStore,
                prStatusStore: prStatusStore,
                teamEventDispatcher: dispatcherForWeb
            )
            switch result {
            case .success(let outcome):
                return .success(WebServer.DeleteWorktreeResponse(dismissed: outcome.dismissed))
            case .failure(.notFound):
                return .notFound("unknown worktree path")
            case .failure(.mainCheckoutRejected):
                return .invalid("cannot delete the repo's main checkout")
            case .failure(.gitFailedForceable(let stderr, let status)):
                return .gitFailedForceable(stderr: stderr, shortStatus: status)
            case .failure(.gitFailedFinal(let msg)):
                return .gitFailedFinal(msg)
            }
        }

        // R5 Task 11: wire production panes-state + pane-control closures into
        // the host agent before the paired-access listener starts, so no
        // incoming WebRTC offer can complete its data-channel handshake with
        // the Task 9 stubs still in place — `installSSHHandler` reads the
        // actor's stored closures synchronously when the DC opens.
        //
        // `panesStateSubscribe`: emits initial snapshot, then polls
        // `buildWorktreePanesSnapshot` on a 1Hz cadence and re-emits when
        // the snapshot differs from the previously-sent one. Polling
        // (rather than a pub-sub source) is intentional — AppState is a
        // SwiftUI `@State` value type with no Combine/AsyncStream publisher,
        // and the `/ws` HTTP path the desktop sidebar/web client uses is
        // itself poll-based, so the SSH transport doesn't promise tighter
        // freshness than the HTTP transport already provides. A pub-sub
        // hook is left as a post-R6 follow-up.
        //
        // `paneControlMutator`: maps session-name targets to `PaneSlotID`
        // via `TerminalManager.paneID(forSessionName:)` and dispatches to
        // the same `splitPane` / `closePane` static methods the Mac sidebar
        // context menu drives. `swap` returns `unsupported` — no native
        // implementation exists yet; tracked as a post-R5 follow-up.
        services.hostPairingCoordinator.setStartupError(
            "Paired access is still starting. Try again in a moment."
        )
        if let hostAgent = services.hostAgent {
            let panesStateSubscribe: PanesStateChannelHandler.Subscribe = { onChange in
                // Initial snapshot fires synchronously so the first frame
                // hits the wire before the polling loop's first sleep.
                let initial = await MainActor.run { buildWorktreePanesSnapshot() }
                await onChange(initial)

                let task = Task {
                    var last = initial
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1))
                        if Task.isCancelled { return }
                        let next = await MainActor.run { buildWorktreePanesSnapshot() }
                        if next != last {
                            last = next
                            await onChange(next)
                        }
                    }
                }
                return PanesStateChannelHandler.Cancellable {
                    task.cancel()
                }
            }

            let panesStateV2Subscribe: PanesStateChannelHandler.Subscribe = {
                onChange in
                let snapshot: @MainActor () -> [WorktreePanes] = {
                    buildWorktreePanesSnapshot()
                        + services.remoteMacsModel.promotedWorktreesForRelay()
                }
                let initial = await MainActor.run { snapshot() }
                await onChange(initial)

                let task = Task {
                    var last = initial
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1))
                        if Task.isCancelled { return }
                        let next = await MainActor.run { snapshot() }
                        if next != last {
                            last = next
                            await onChange(next)
                        }
                    }
                }
                return PanesStateChannelHandler.Cancellable {
                    task.cancel()
                }
            }

            let paneControlMutator: PaneControlChannelHandler.Mutator = { request in
                if let target = request.primaryTarget,
                   target.hasPrefix("relay-pane-") {
                    return await services.remoteMacsModel.sendRelayedPaneControl(request)
                        ?? .error(
                            code: "not-found",
                            message: "unknown or disconnected relayed pane"
                        )
                }
                return await MainActor.run { () -> PaneControlResponse in
                    switch request {
                    case .split(let target, let direction):
                        guard let paneID = terminalManager.paneID(forSessionName: target) else {
                            return .error(
                                code: "not-found",
                                message: "no pane with session name '\(target)'"
                            )
                        }
                        let split: PaneSplit
                        switch direction {
                        case .right:
                            split = .right
                        case .down:
                            split = .down
                        case .left:
                            split = .left
                        case .up:
                            split = .up
                        }
                        let slot = PaneSlotID(id: paneID)
                        let targetWorktreePath =
                            appStateBinding.wrappedValue.repos.lazy
                            .flatMap(\.worktrees)
                            .first(where: {
                                $0.splitTree.containsLeaf(slot)
                            })?.path
                        let targetIsVisible =
                            !NSApp.isHidden
                            && terminalManager.view(for: slot)?
                                .window?.isVisible == true
                            && appStateBinding.wrappedValue
                                .selectedWorktreePath.flatMap {
                                    appStateBinding.wrappedValue
                                        .worktree(forPath: $0)
                                }?.splitTree.containsLeaf(slot) == true
                        guard let newID = Self.splitPane(
                            appState: appStateBinding,
                            terminalManager: terminalManager,
                            targetID: slot,
                            split: split,
                            activateNewPane: false,
                            preserveZoom: true
                        ) else {
                            return .error(
                                code: "conflict",
                                message: "split rejected (target not in a running worktree, or surface creation failed)"
                            )
                        }
                        if !targetIsVisible {
                            terminalManager.setVisible(false, for: newID)
                        }
                        if let targetWorktreePath {
                            terminalManager.surfaceBudget.noteCreated(
                                worktreePath: targetWorktreePath,
                                splitTreesByPath: appStateBinding.wrappedValue
                                    .runningSplitTreesByPath()
                            )
                        }
                        guard let sessionName = terminalManager
                            .zmxSessionName(for: newID) else {
                            return .error(
                                code: "conflict",
                                message: "split succeeded without a pane session"
                            )
                        }
                        return .splitCreated(sessionName: sessionName)
                    case .close(let target):
                        guard let paneID = terminalManager.paneID(forSessionName: target) else {
                            return .error(
                                code: "not-found",
                                message: "no pane with session name '\(target)'"
                            )
                        }
                        let slot = PaneSlotID(id: paneID)
                        let targetIsVisible =
                            !NSApp.isHidden
                            && terminalManager.view(for: slot)?
                                .window?.isVisible == true
                            && appStateBinding.wrappedValue
                                .selectedWorktreePath.flatMap {
                                    appStateBinding.wrappedValue
                                        .worktree(forPath: $0)
                                }?.splitTree.containsLeaf(slot) == true
                        Self.closePane(
                            appState: appStateBinding,
                            terminalManager: terminalManager,
                            targetID: slot,
                            userInitiated: true,
                            activateReplacement: targetIsVisible
                        )
                        return .ok
                    case .swap:
                        // No `swapPanes` exists on the desktop side yet —
                        // the AppState splittree API doesn't expose a swap
                        // primitive, and adding one is out of scope for R5
                        // per the plan's "don't refactor AppState" guidance.
                        // Follow-up: REMOTE-7.x swap support.
                        return .error(
                            code: "unsupported",
                            message: "swap is not implemented on this host yet"
                        )
                    case .equalize(let target):
                        guard let paneID = terminalManager.paneID(
                            forSessionName: target
                        ) else {
                            return .error(
                                code: "not-found",
                                message: "no pane with session name '\(target)'"
                            )
                        }
                        Self.equalizeSplits(
                            appState: appStateBinding,
                            around: PaneSlotID(id: paneID),
                            preserveZoom: true
                        )
                        return .ok
                    case let .resize(
                        target,
                        direction,
                        amount,
                        viewportExtent
                    ):
                        guard let paneID = terminalManager.paneID(
                            forSessionName: target
                        ) else {
                            return .error(
                                code: "not-found",
                                message: "no pane with session name '\(target)'"
                            )
                        }
                        let resizeDirection: ResizeDirection
                        switch direction {
                        case .right:
                            resizeDirection = .right
                        case .down:
                            resizeDirection = .down
                        case .left:
                            resizeDirection = .left
                        case .up:
                            resizeDirection = .up
                        }
                        let viewerBounds = viewportExtent.map { extent in
                            switch direction {
                            case .left, .right:
                                return CGRect(
                                    x: 0,
                                    y: 0,
                                    width: CGFloat(extent),
                                    height: 1
                                )
                            case .up, .down:
                                return CGRect(
                                    x: 0,
                                    y: 0,
                                    width: 1,
                                    height: CGFloat(extent)
                                )
                            }
                        }
                        guard Self.resizeSplit(
                            appState: appStateBinding,
                            target: PaneSlotID(id: paneID),
                            direction: resizeDirection,
                            pixels: amount,
                            ancestorBounds: viewerBounds,
                            preserveZoom: true
                        ) else {
                            return .error(
                                code: "no-matching-split",
                                message: "no split in that direction can be resized"
                            )
                        }
                        return .ok
                    }
                }
            }

            let localRepositorySnapshot: @MainActor () -> [RemoteRepositoryInfo] = {
                appStateBinding.wrappedValue.repos.map { repo in
                    let snapshot = panesRemoteBranchStore.branchesByRepo[repo.path]
                        ?? RemoteBranchSnapshot()
                    var mounted: [String: String] = [:]
                    for worktree in repo.worktrees
                    where worktree.state.hasOnDiskWorktree {
                        mounted[worktree.branch] = worktree.path
                    }
                    let pullRequests = services.prStatusStore.prsByRepoBranch[
                        repo.path
                    ] ?? [:]
                    let branches = BranchPickerViewModel.entries(
                        branchSnapshot: snapshot,
                        mountedBranchToPath: mounted,
                        prsByBranch: pullRequests,
                        filterText: ""
                    ).map { branch in
                        RemoteRepositoryInfo.Branch(
                            name: branch.name,
                            source: branch.source == .local
                                ? .local
                                : .remoteOnly,
                            lastCommitDate: branch.lastCommitDate,
                            mountedWorktreeID: branch.mountedWorktreePath,
                            pullRequest: branch.pr.map {
                                .init(number: $0.number, title: $0.title)
                            }
                        )
                    }
                    let status = defaultBranchStatus(
                        for: repo,
                        stats: statsStore.stats[repo.path]
                    )
                    return RemoteRepositoryInfo(
                        id: repo.path,
                        displayName: repo.displayName,
                        origin: localWorktreeOrigin,
                        defaultBranchStatus: status.map {
                            .init(
                                branchName: $0.branchName,
                                remoteRef: $0.remoteRef,
                                behindCount: $0.behindCount
                            )
                        },
                        branches: branches
                    )
                }
            }

            let worktreeManagementMutator:
                WorktreeManagementChannelHandler.Mutator = { request in
                if request.targetsRelayedResource {
                    return await services.remoteMacsModel
                        .sendRelayedWorktreeManagement(request)
                        ?? .error(
                            code: "not-found",
                            message: "unknown or disconnected relayed resource",
                            forceAllowed: false,
                            shortStatus: nil
                        )
                }

                switch request {
                case .hostPresentation:
                    let presentation = await MainActor.run {
                        RemoteHostPresentation(
                            ghosttyConfig:
                                GhosttyConfigReader.resolvedConfig(),
                            keybindings: GhosttyKeybindingsResponse(
                                chords: terminalManager.keybindBridge.allChords
                            )
                        )
                    }
                    return .hostPresentation(presentation)

                case .listRepositories:
                    let local = await MainActor.run {
                        localRepositorySnapshot()
                    }
                    let remote = await services.remoteMacsModel
                        .promotedRepositoriesForRelay()
                    return .repositories(local + remote)

                case let .create(
                    repositoryID,
                    worktreeName,
                    branchName,
                    existingSource
                ):
                    let branch: BranchSelection
                    if let existingSource {
                        let resolvedSource:
                            BranchSelection.ExistingSource?
                        switch existingSource {
                        case .local:
                            resolvedSource = .local
                        case .remoteOnly:
                            resolvedSource = .remoteOnly
                        case .automatic:
                            resolvedSource = try? await
                                GitExistingBranchSource.resolve(
                                    repoPath: repositoryID,
                                    branchName: branchName
                                )
                        }
                        guard let resolvedSource else {
                            return .error(
                                code: "branch-not-found",
                                message:
                                    "No local or origin branch named "
                                    + branchName + " exists.",
                                forceAllowed: false,
                                shortStatus: nil
                            )
                        }
                        branch = .useExisting(
                            name: branchName,
                            source: resolvedSource
                        )
                    } else {
                        branch = .createNew(name: branchName)
                    }
                    let result = await AddWorktreeFlow.add(
                        repoPath: repositoryID,
                        worktreeName: worktreeName,
                        branch: branch,
                        appState: appStateBinding,
                        worktreeMonitor: worktreeMonitor,
                        statsStore: statsStore,
                        terminalManager: terminalManager,
                        teamEventDispatcher: dispatcherForWeb
                    )
                    switch result {
                    case .success(let outcome):
                        return .created(
                            worktreeID: outcome.worktreePath,
                            paneID: outcome.sessionName
                        )
                    case .failure(let error):
                        return .error(
                            code: "create-failed",
                            message: error.userMessage
                                ?? "could not create worktree",
                            forceAllowed: false,
                            shortStatus: nil
                        )
                    }

                case .pullDefaultBranch(let repositoryID):
                    let status = await MainActor.run {
                        () -> WebServer.RepoInfo.DefaultBranchStatus? in
                        guard let target = appStateBinding.wrappedValue.repos
                            .first(where: { $0.path == repositoryID }) else {
                            return nil
                        }
                        return defaultBranchStatus(
                            for: target,
                            stats: statsStore.stats[target.path]
                        )
                    }
                    guard let status else {
                        return .error(
                            code: "invalid",
                            message: "default checkout is not behind origin",
                            forceAllowed: false,
                            shortStatus: nil
                        )
                    }
                    do {
                        try await GitDefaultBranchPull.pull(
                            repoPath: repositoryID,
                            branchName: status.branchName
                        )
                        return .ok
                    } catch {
                        return .error(
                            code: "pull-failed",
                            message: String(describing: error),
                            forceAllowed: false,
                            shortStatus: nil
                        )
                    }

                case .open(let worktreeID):
                    return await MainActor.run {
                        let result = Self.startWorktree(
                            path: worktreeID,
                            appState: appStateBinding,
                            terminalManager: terminalManager,
                            startSurfacesInBackground: true
                        )
                        let targetIsVisible =
                            !NSApp.isHidden
                            && NSApp.mainWindow?.isVisible == true
                            && appStateBinding.wrappedValue
                                .selectedWorktreePath == worktreeID
                        if result == .started || result == .alreadyRunning {
                            let splitTrees = appStateBinding.wrappedValue
                                .runningSplitTreesByPath()
                            if targetIsVisible {
                                terminalManager.surfaceBudget.noteSelected(
                                    worktreePath: worktreeID,
                                    splitTreesByPath: splitTrees
                                )
                            } else {
                                terminalManager.surfaceBudget.noteCreated(
                                    worktreePath: worktreeID,
                                    splitTreesByPath: splitTrees
                                )
                            }
                        }
                        if result == .started,
                           !targetIsVisible,
                           let worktree = appStateBinding.wrappedValue
                               .worktree(forPath: worktreeID) {
                            for terminalID in worktree.splitTree.allLeaves {
                                terminalManager.setVisible(
                                    false,
                                    for: terminalID
                                )
                            }
                        }
                        switch result {
                        case .started, .alreadyRunning:
                            return .ok
                        case .notFound:
                            return .error(
                                code: "not-found",
                                message: "unknown worktree",
                                forceAllowed: false,
                                shortStatus: nil
                            )
                        case .unavailable:
                            return .error(
                                code: "unavailable",
                                message: "worktree cannot be opened in its current state",
                                forceAllowed: false,
                                shortStatus: nil
                            )
                        }
                    }

                case let .delete(worktreeID, force):
                    let result = await DeleteWorktreeFlow.delete(
                        worktreePath: worktreeID,
                        force: force,
                        appState: appStateBinding,
                        terminalManager: terminalManager,
                        statsStore: statsStore,
                        prStatusStore: services.prStatusStore,
                        teamEventDispatcher: dispatcherForWeb
                    )
                    switch result {
                    case .success(let outcome):
                        return .deleted(dismissed: outcome.dismissed)
                    case .failure(.notFound):
                        return .error(
                            code: "not-found",
                            message: "unknown worktree",
                            forceAllowed: false,
                            shortStatus: nil
                        )
                    case .failure(.mainCheckoutRejected):
                        return .error(
                            code: "invalid",
                            message: "cannot delete the main checkout",
                            forceAllowed: false,
                            shortStatus: nil
                        )
                    case .failure(.gitFailedForceable(let stderr, let status)):
                        return .error(
                            code: "git-failed",
                            message: stderr,
                            forceAllowed: true,
                            shortStatus: status
                        )
                    case .failure(.gitFailedFinal(let message)):
                        return .error(
                            code: "git-failed",
                            message: message,
                            forceAllowed: false,
                            shortStatus: nil
                        )
                    }

                case let .acknowledge(worktreeID, paneID):
                    return await MainActor.run {
                        for repoIndex in appStateBinding.wrappedValue.repos.indices {
                            for worktreeIndex in appStateBinding.wrappedValue
                                .repos[repoIndex].worktrees.indices
                            where appStateBinding.wrappedValue.repos[repoIndex]
                                .worktrees[worktreeIndex].path == worktreeID {
                                if let paneID {
                                    guard let slot = appStateBinding.wrappedValue
                                        .repos[repoIndex].worktrees[worktreeIndex]
                                        .paneSlot(forSessionName: paneID) else {
                                        return .error(
                                            code: "not-found",
                                            message: "unknown pane in worktree",
                                            forceAllowed: false,
                                            shortStatus: nil
                                        )
                                    }
                                    appStateBinding.wrappedValue.repos[repoIndex]
                                        .worktrees[worktreeIndex]
                                        .paneAttention[slot] = nil
                                } else {
                                    appStateBinding.wrappedValue.repos[repoIndex]
                                        .worktrees[worktreeIndex]
                                        .acknowledgeAttention()
                                }
                                return .ok
                            }
                        }
                        return .error(
                            code: "not-found",
                            message: "unknown worktree",
                            forceAllowed: false,
                            shortStatus: nil
                        )
                    }
                }
            }

            // Configure SSH channel handlers before starting the dedicated
            // paired-access listener. Browser Web Access deliberately has no
            // native signaling route.
            Task { @MainActor in
                await hostAgent.setPanesStateSubscribe(panesStateSubscribe)
                await hostAgent.setPanesStateV2Subscribe(panesStateV2Subscribe)
                await hostAgent.setPaneControlMutator(paneControlMutator)
                await hostAgent.setWorktreeManagementMutator(
                    worktreeManagementMutator
                )
                do {
                    try await services.startRemoteMacAccessServices(
                        hostAgent: hostAgent
                    )
                    services.hostPairingCoordinator.setStartupError(nil)
                } catch {
                    services.hostPairingCoordinator.setStartupError(
                        Self.remoteAccessStartupMessage(for: error)
                    )
                    NSLog(
                        "[Graftty] failed to start LAN remote access services: %@",
                        String(describing: error)
                    )
                }
            }
        } else {
            Task { @MainActor in
                do {
                    try await services.startRemoteMacAccessServices(
                        hostAgent: nil
                    )
                    services.hostPairingCoordinator.setStartupError(nil)
                } catch {
                    services.hostPairingCoordinator.setStartupError(
                        Self.remoteAccessStartupMessage(for: error)
                    )
                    NSLog(
                        "[Graftty] failed to start LAN remote access services: %@",
                        String(describing: error)
                    )
                }
            }
        }

        // WEB-4.3: close the NIO listen sockets + SIGTERM any in-flight
        // `zmx attach` children as part of normal shutdown. Process exit
        // would eventually do both, but we can't rely on that: WEB-4.6's
        // FD_CLOEXEC sweep inside PtyProcess is a defense-in-depth safety
        // net, not the primary teardown path. Running stop() explicitly
        // means the 500ms SIGTERM→waitpid window in WebSession.close()
        // gets a chance to reap cleanly before NSApplication pulls the
        // rug out.
        let controller = webController
        let appServices = services
        let stateBinding = binding
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                // PERSIST-2.1: save process-lifetime mutations even when the
                // main window (and its `.onChange` observer) is closed.
                Self.persistAppState(stateBinding.wrappedValue)
                appServices.stopRemoteMacAccessServices()
                appServices.remoteBranchStore.stop()
                appServices.prStatusStore.stop()
                appServices.statsStore.stop()
                controller.stop()
            }
        }
    }

    private static func remoteAccessStartupMessage(for error: Error) -> String {
        if let serviceError = error as? AppServices.RemoteMacAccessServiceError {
            switch serviceError {
            case .disabled:
                return "Paired-device access is disabled in this Graftty configuration."
            case .hostAgentUnavailable:
                return "Paired-device access is unavailable because WebRTC could not start."
            case .listenerPortUnavailable:
                break
            }
        }
        return """
        Paired-device access could not start on port \
        \(RemoteAccessProtocol.pairedAccessPort). Quit the other process using \
        that port, then restart Graftty. (\(error))
        """
    }

    actor CodexAppServerInboxObserverDeliveryState {
        private var lastSeenCount: Int
        private var skipInitialSnapshot: Bool

        init(lastSeenCount: Int = 0, skipInitialSnapshot: Bool = false) {
            self.lastSeenCount = lastSeenCount
            self.skipInitialSnapshot = skipInitialSnapshot
        }

        func markSeen(_ messages: [TeamInboxMessage]) {
            lastSeenCount = messages.count
            skipInitialSnapshot = false
        }

        func claimRecipientWorktrees(in messages: [TeamInboxMessage]) -> [String] {
            if skipInitialSnapshot {
                skipInitialSnapshot = false
                lastSeenCount = messages.count
                return []
            }

            let previousCount = lastSeenCount
            let currentCount = messages.count
            lastSeenCount = currentCount
            guard currentCount > previousCount else { return [] }

            var seenWorktrees: Set<String> = []
            var recipientWorktrees: [String] = []
            for message in messages[previousCount..<currentCount] where seenWorktrees.insert(message.to.worktree).inserted {
                recipientWorktrees.append(message.to.worktree)
            }
            return recipientWorktrees
        }
    }

    @MainActor
    static func livePaneSessionNamesForAutomaticDelivery(
        records: [TeamPresenceRecord],
        terminalManager: TerminalManager
    ) -> Set<String> {
        Set(records.compactMap { record -> String? in
            // A background or LRU-evicted pane intentionally has no mounted
            // SurfaceHandle, but its durable pane-to-zmx mapping remains
            // authoritative until the pane is destroyed. Delivery liveness
            // must follow that mapping rather than UI visibility; the owner
            // resolver separately verifies the registered process identity.
            guard let sessionName = record.paneSessionName,
                  terminalManager.paneID(forSessionName: sessionName) != nil else {
                return nil
            }
            return sessionName
        })
    }

    nonisolated static func deliverCodexAppServerMessages(
        teamID: String,
        recipientWorktrees: [String],
        delivery: CodexAppServerDeliveryTrigger
    ) async {
        await withTaskGroup(of: Void.self) { group in
            for recipientWorktree in recipientWorktrees {
                group.addTask {
                    await delivery.onMessageArrival(team: teamID, worktree: recipientWorktree)
                }
            }
        }
    }

    nonisolated static func retryCodexAppServerDeliveryForPresenceWorktrees(
        inbox: TeamInbox,
        records: [TeamPresenceRecord],
        delivery: CodexAppServerDeliveryTrigger
    ) async {
        var seen: Set<TeamDeliveryPresenceWorktreeKey> = []
        var keys: [TeamDeliveryPresenceWorktreeKey] = []
        for record in records where record.runtime == .codex {
            let key = TeamDeliveryPresenceWorktreeKey(teamID: record.teamID, worktree: record.worktree)
            guard seen.insert(key).inserted else { continue }
            if Self.hasPendingUnreadMessage(inbox: inbox, key: key) {
                keys.append(key)
            }
        }

        await withTaskGroup(of: Void.self) { group in
            for key in keys {
                group.addTask {
                    await delivery.onMessageArrival(team: key.teamID, worktree: key.worktree)
                }
            }
        }
    }

    private nonisolated static func hasPendingUnreadMessage(
        inbox: TeamInbox,
        key: TeamDeliveryPresenceWorktreeKey
    ) -> Bool {
        do {
            let watermark = try inbox.worktreeWatermark(
                teamID: key.teamID,
                worktree: key.worktree
            )?.lastDeliveredToAnySessionID
            let allUnread = try inbox.unreadMessages(
                teamID: key.teamID,
                recipientWorktree: key.worktree,
                after: watermark
            )
            guard let first = allUnread.first else { return false }
            return first.to.runtime == nil ||
                first.to.runtime == TeamHookRuntime.codex.rawValue
        } catch {
            return false
        }
    }

    private struct TeamDeliveryPresenceWorktreeKey: Hashable, Sendable {
        let teamID: String
        let worktree: String
    }

    /// Pre-pass for `reconcileOnLaunch` implementing LAYOUT-4.6 (bookmark
    /// resolution at launch) and LAYOUT-4.9 (backfill mint for pre-upgrade
    /// entries without bookmarks).
    ///
    /// For each `RepoEntry`:
    /// - If it has a bookmark, resolve it. If the resolved path differs
    ///   from the stored `path`, run the relocate cascade. If the
    ///   bookmark resolves to the same path but is stale, re-mint.
    /// - If it has no bookmark and the stored `path` exists on disk, mint
    ///   one in place (migration from pre-LAYOUT-4.5 state.json).
    ///
    /// Runs before any `WorktreeMonitor.watch*` calls in `startup()`
    /// would have armed watchers at stale paths; by the time
    /// `reconcileOnLaunch`'s own discover loop runs, each `RepoEntry` is
    /// already at its current-on-disk location.
    ///
    /// Static so the bridge (`WorktreeMonitorBridge`) can reach it
    /// without holding a reference to `GrafttyApp` (a SwiftUI App
    /// struct). Dependencies are threaded in as params.
    @MainActor
    fileprivate static func resolveRepoLocations(
        appState: Binding<AppState>,
        worktreeMonitor: WorktreeMonitor,
        statsStore: WorktreeStatsStore,
        prStatusStore: PRStatusStore,
        remoteBranchStore: RemoteBranchStore
    ) async {
        for repoIdx in appState.wrappedValue.repos.indices {
            let repo = appState.wrappedValue.repos[repoIdx]
            if let bookmark = repo.bookmark {
                do {
                    let resolved = try RepoBookmark.resolve(bookmark)
                    if resolved.url.path != repo.path {
                        await relocateRepo(
                            appState: appState,
                            worktreeMonitor: worktreeMonitor,
                            statsStore: statsStore,
                            prStatusStore: prStatusStore,
                            remoteBranchStore: remoteBranchStore,
                            repoIdx: repoIdx,
                            newURL: resolved.url,
                            isStale: resolved.isStale
                        )
                    } else if resolved.isStale {
                        // Same path, but the bookmark is stale (cross-
                        // volume move, APFS firmlink resolution). Re-mint
                        // so next launch's resolve is fast and we don't
                        // accumulate staleness.
                        appState.wrappedValue.repos[repoIdx].bookmark = try? RepoBookmark.mint(atPath: repo.path)
                    }
                } catch {
                    NSLog("[Graftty] resolveRepoLocations: bookmark resolve failed for %@: %@",
                          repo.path, String(describing: error))
                }
            } else if FileManager.default.fileExists(atPath: repo.path) {
                // LAYOUT-4.9: entry decoded from a pre-LAYOUT-4.5
                // state.json has no bookmark. The stored path resolves
                // on disk, so mint a fresh bookmark from it — subsequent
                // renames/moves will then be recoverable automatically.
                if let fresh = try? RepoBookmark.mint(atPath: repo.path) {
                    appState.wrappedValue.repos[repoIdx].bookmark = fresh
                }
            }
        }
    }

    /// Orchestrator for LAYOUT-4.8 — enacts the relocate decisions
    /// produced by `RepoRelocator` against the live model, watchers, and
    /// caches. Called from two entry points: the launch-time pre-pass
    /// (`resolveRepoLocations`) and the
    /// `WorktreeMonitor.worktreeMonitorDidDetectDeletion` FSEvents hook
    /// on `WorktreeMonitorBridge` (LAYOUT-4.7).
    ///
    /// Ordering matters: watcher stop + cache clear MUST happen before
    /// the `appState.repos[repoIdx].path` assignment, otherwise later
    /// `stopWatching(repoPath:)` / `clear(worktreePath:)` calls would
    /// see the new path and the old-path watchers + cache entries would
    /// leak (GIT-3.11 / GIT-3.13).
    ///
    /// Static so the bridge can reach it without capturing the SwiftUI
    /// `GrafttyApp` struct. All live deps (appState binding, watcher,
    /// stores) are threaded in as params.
    @MainActor
    fileprivate static func relocateRepo(
        appState: Binding<AppState>,
        worktreeMonitor: WorktreeMonitor,
        statsStore: WorktreeStatsStore,
        prStatusStore: PRStatusStore,
        remoteBranchStore: RemoteBranchStore,
        repoIdx: Int,
        newURL: URL,
        isStale: Bool
    ) async {
        // Guard: the caller may have suspended on an `await` between the
        // index lookup and here; if the repo vanished in the meantime
        // (e.g. concurrent Remove Repository), skip silently.
        guard appState.wrappedValue.repos.indices.contains(repoIdx) else {
            NSLog("[Graftty] relocateRepo: repoIdx %d out of range after suspension", repoIdx)
            return
        }

        let oldRepoPath = appState.wrappedValue.repos[repoIdx].path
        let newRepoPath = newURL.path

        // (a) Abort if the resolved folder is no longer a git repo.
        // A rename into a non-git directory (e.g. bookmark survived a
        // cross-volume move that clobbered `.git`) has no recovery path;
        // falling through to the stale transition is correct.
        do {
            let detection = try GitRepoDetector.detect(path: newRepoPath)
            guard case .repoRoot = detection else {
                NSLog("[Graftty] relocateRepo: resolved URL is not a repo root (detection=%@): %@",
                      String(describing: detection), newRepoPath)
                return
            }
        } catch {
            NSLog("[Graftty] relocateRepo: detect failed at %@: %@",
                  newRepoPath, String(describing: error))
            return
        }

        // (b) Re-mint stale bookmark from the new path so future
        // resolves don't pay the staleness cost.
        if isStale, let fresh = try? RepoBookmark.mint(atPath: newRepoPath) {
            appState.wrappedValue.repos[repoIdx].bookmark = fresh
        }

        // (c) + (d) Stop repo-level and per-worktree watchers and clear
        // per-old-path caches before any mutation of
        // `appState.repos[repoIdx].path` — `stopWatching` matches
        // watcher keys by the repoPath we pass in, not by the repo's
        // current model value, and caches keyed by the old path would
        // bleed into carried-forward worktrees. Shared with Remove
        // Repository via `RepoTeardown`.
        RepoTeardown.stopWatchersAndClearCaches(
            repo: appState.wrappedValue.repos[repoIdx],
            worktreeMonitor: worktreeMonitor,
            statsStore: statsStore,
            prStatusStore: prStatusStore,
            remoteBranchStore: remoteBranchStore
        )

        // (e) Snapshot the pre-relocate repo for the pure decision
        // function, then apply the repo-level path/displayName update.
        // The snapshot is load-bearing: the decision reads old paths to
        // compute rewrites, and we're about to clobber them in the
        // model.
        let pre = appState.wrappedValue.repos[repoIdx]
        appState.wrappedValue.repos[repoIdx].path = newRepoPath
        appState.wrappedValue.repos[repoIdx].displayName = newURL.lastPathComponent

        // (f) Discover at the new location. On failure, leave the
        // repo.path updated but worktrees untouched — the per-worktree
        // stale transitions will happen naturally on the next
        // reconcile / FSEvents delete, so this is a recoverable state.
        var discovered: [DiscoveredWorktree]
        do {
            discovered = try await WorktreeDiscovery.discover(repo: appState.wrappedValue.repos[repoIdx])
        } catch {
            NSLog("[Graftty] relocateRepo: discover failed at %@: %@",
                  newRepoPath, String(describing: error))
            return
        }

        // (g) Ask the pure decision function whether a repair is needed.
        // If yes, run `git worktree repair` (which rewrites the `gitdir:`
        // files of linked worktrees whose paths moved) and re-discover.
        let firstDecision = RepoRelocator.decide(
            repo: pre,
            newRepoPath: newRepoPath,
            discovered: discovered,
            selectedWorktreePath: appState.wrappedValue.selectedWorktreePath
        )
        let finalDecision: RepoRelocator.Decision
        if firstDecision.needsRepair {
            do {
                try await GitWorktreeRepair.repair(
                    repoPath: newRepoPath,
                    worktreePaths: firstDecision.repairCandidatePaths
                )
                discovered = try await WorktreeDiscovery.discover(repo: appState.wrappedValue.repos[repoIdx])
            } catch {
                NSLog("[Graftty] relocateRepo: repair/rediscover failed at %@: %@",
                      newRepoPath, String(describing: error))
                // Fall through with the current `discovered` snapshot;
                // unmatched pre-worktrees will go stale and the user can
                // dismiss them manually.
            }
            finalDecision = RepoRelocator.decidePostRepair(
                repo: pre,
                newRepoPath: newRepoPath,
                discovered: discovered,
                selectedWorktreePath: appState.wrappedValue.selectedWorktreePath
            )
        } else {
            finalDecision = firstDecision
        }

        // (h) Build the new worktrees array:
        //  - Carried-forward: mutate path (and latest branch label)
        //    in place on the `pre` copy, preserving id / splitTree /
        //    state / attention / paneAttention / focusedPaneSlotID /
        //    primaryPaneSlotID / offeredDeleteForResolvedPR.
        //  - Gone-stale: preserve the full entry, flip state to `.stale`
        //    so the sidebar can still offer a Dismiss action.
        //  - Fresh: discovered branches that didn't match any existing
        //    entry are brand-new worktrees (git added while we weren't
        //    watching). Append as `.closed`.
        var newWorktrees: [WorktreeEntry] = []
        for cf in finalDecision.carriedForward {
            if var existing = pre.worktrees.first(where: { $0.id == cf.existingID }) {
                existing.path = cf.newPath
                existing.branch = cf.branch
                newWorktrees.append(existing)
            }
        }
        for stale in finalDecision.goneStale {
            if var existing = pre.worktrees.first(where: { $0.id == stale.existingID }) {
                existing.markStale()
                newWorktrees.append(existing)
            }
        }
        // Fresh (unmatched) discovered entries — carried-forward already
        // claimed the matched ones, so any discovered worktree whose
        // `(branch, path)` pair isn't in `carriedForward` is new.
        let carriedPaths = Set(finalDecision.carriedForward.map(\.newPath))
        for d in discovered where !carriedPaths.contains(d.path) {
            newWorktrees.append(WorktreeEntry(path: d.path, branch: d.branch))
        }
        appState.wrappedValue.repos[repoIdx].worktrees = WorktreeOrdering.staleLast(newWorktrees)

        // (i) Update selection to the relocated path (decision already
        // mapped old→new or nil'd it when the selected worktree went
        // stale).
        appState.wrappedValue.selectedWorktreePath = finalDecision.newSelectedWorktreePath

        // (j) Install fresh watchers at the new paths. Matches
        // `startup()`'s initial watcher-install loop exactly so the
        // post-relocate watcher graph is indistinguishable from a
        // from-scratch launch at the new location.
        worktreeMonitor.installRepoWatchers(repo: appState.wrappedValue.repos[repoIdx])
        remoteBranchStore.refresh(repoPath: newRepoPath)
        Self.persistAppState(appState.wrappedValue)

        NSLog("[Graftty] relocateRepo: %@ → %@", oldRepoPath, newRepoPath)
    }

    private func reconcileOnLaunch(
        onComplete: @MainActor @escaping () -> Void
    ) {
        let binding = $appState
        let statsStore = services.statsStore
        let prStatusStore = services.prStatusStore
        let remoteBranchStore = services.remoteBranchStore
        let worktreeMonitor = services.worktreeMonitor
        Task { @MainActor in
            defer { onComplete() }
            // LAYOUT-4.6 / LAYOUT-4.9: resolve bookmarks and run any
            // relocate cascades BEFORE the discover+reconcile loop below.
            // If a repo moved in Finder between runs, this fixes up its
            // path (and per-worktree paths) so the subsequent discover
            // uses the right repoPath and the reconcile doesn't flag
            // every worktree as newly-stale.
            await Self.resolveRepoLocations(
                appState: binding,
                worktreeMonitor: worktreeMonitor,
                statsStore: statsStore,
                prStatusStore: prStatusStore,
                remoteBranchStore: remoteBranchStore
            )

            for repoIdx in binding.wrappedValue.repos.indices {
                let repoPath = binding.wrappedValue.repos[repoIdx].path
                let discovered: [DiscoveredWorktree]
                do {
                    discovered = try await WorktreeDiscovery.discover(repo: binding.wrappedValue.repos[repoIdx])
                } catch {
                    NSLog("[Graftty] reconcileOnLaunch: discover failed for %@: %@",
                          repoPath, String(describing: error))
                    continue
                }

                let result = WorktreeReconciler.reconcile(
                    existing: binding.wrappedValue.repos[repoIdx].worktrees,
                    discovered: discovered
                )
                binding.wrappedValue.repos[repoIdx].worktrees = result.merged

                // GIT-3.13 / GIT-3.15: clear cached stats/PR AND drop
                // the worktree's path/head/content watchers on every
                // stale transition — not just the FSEvents-deletion
                // path. Without this, a reconcile-driven stale keeps
                // zombie fds that block a same-path resurrection from
                // re-arming.
                for wt in result.newlyStale {
                    statsStore.clear(worktreePath: wt.path)
                    prStatusStore.clear(worktreePath: wt.path)
                    services.worktreeMonitor.stopWatchingWorktree(wt.path)
                }

                // Kick initial stats refresh for running worktrees after
                // reconciliation. Closed worktrees can be numerous sidebar
                // history; polling them makes CPU scale with inactive rows.
                for wt in binding.wrappedValue.repos[repoIdx].worktrees where wt.state == .running {
                    statsStore.refresh(worktreePath: wt.path, repoPath: repoPath, branch: wt.branch)
                }
            }
        }
    }

    @MainActor
    internal static func prepareRunningWorktreeForRestore(
        _ worktree: inout WorktreeEntry,
        terminalManager: TerminalManager
    ) {
        if worktree.splitTree.root == nil {
            worktree.splitTree = SplitTree(root: .leaf(PaneSlotID()))
        }
        worktree.ensurePaneSessionsForRunningRestore()
        terminalManager.recordPaneSessions(
            for: worktree.splitTree,
            paneSessions: worktree.paneSessions,
            worktreePath: worktree.path
        )
        _ = worktree.normalizeFocusedPane()
        let primaryPane = worktree.ensurePrimaryPane()
        // Mark every restored leaf as rehydrated *before* surface creation
        // so surviving zmx sessions never receive another default command.
        for leafID in worktree.splitTree.allLeaves {
            terminalManager.markRehydrated(leafID)
        }
        // If zmx reports a session missing, createSurfaces clears only that
        // leaf's rehydration marker. Retaining one primary marker lets the
        // first-pane-only policy restart exactly one default command.
        if let primaryPane {
            terminalManager.markFirstPane(primaryPane)
        }
    }

    private func restoreRunningWorktrees() {
        let selectedPath = appState.selectedWorktreePath
        for repoIdx in appState.repos.indices {
            for wtIdx in appState.repos[repoIdx].worktrees.indices
            where appState.repos[repoIdx].worktrees[wtIdx].state == .running {
                Self.prepareRunningWorktreeForRestore(
                    &appState.repos[repoIdx].worktrees[wtIdx],
                    terminalManager: terminalManager
                )
                let wt = appState.repos[repoIdx].worktrees[wtIdx]
                guard wt.path == selectedPath else { continue }
                _ = terminalManager.createSurfaces(
                    for: wt.splitTree,
                    paneSessions: wt.paneSessions,
                    worktreePath: wt.path
                )
            }
        }

        // Tell libghostty which pane is active for the currently-selected
        // worktree, so the cursor blinks in the right place on launch.
        // AppKit first-responder follows via `SurfaceNSView.viewDidMoveToWindow`
        // once SwiftUI attaches the view.
        if let path = appState.selectedWorktreePath,
           let wt = appState.worktree(forPath: path),
           wt.state == .running,
           let target = wt.firstPane {
            terminalManager.setFocus(target)
        }

        // STATE-2.12: resume auto-clear timers for any persisted attention
        // that carried a `clearAfter`. The timer is in-memory only when
        // first set (handleNotification / setAttentionForTerminal schedule
        // a `DispatchQueue.main.asyncAfter`), so a force-quit mid-window
        // leaves the attention stuck in state.json with no live timer.
        // Without this resume step, the badge persists until the user
        // clicks the worktree (STATE-2.4).
        resumePersistedAttentionTimers()
    }

    @MainActor
    private func resumePersistedAttentionTimers() {
        let now = Date()
        for repoIdx in appState.repos.indices {
            for wtIdx in appState.repos[repoIdx].worktrees.indices {
                let wt = appState.repos[repoIdx].worktrees[wtIdx]
                let path = wt.path

                if let attention = wt.attention,
                   let remaining = AttentionResumePolicy.remainingTime(for: attention, now: now) {
                    let stamp = attention.timestamp
                    let appStateBinding = $appState
                    DispatchQueue.main.asyncAfter(deadline: .now() + remaining) {
                        for ri in appStateBinding.wrappedValue.repos.indices {
                            for wi in appStateBinding.wrappedValue.repos[ri].worktrees.indices {
                                if appStateBinding.wrappedValue.repos[ri].worktrees[wi].path == path {
                                    appStateBinding.wrappedValue.repos[ri].worktrees[wi]
                                        .clearAttentionIfTimestamp(stamp)
                                }
                            }
                        }
                    }
                }

                for (terminalID, attention) in wt.paneAttention {
                    guard let remaining = AttentionResumePolicy.remainingTime(for: attention, now: now) else {
                        continue
                    }
                    let stamp = attention.timestamp
                    let appStateBinding = $appState
                    DispatchQueue.main.asyncAfter(deadline: .now() + remaining) {
                        for ri in appStateBinding.wrappedValue.repos.indices {
                            for wi in appStateBinding.wrappedValue.repos[ri].worktrees.indices {
                                if appStateBinding.wrappedValue.repos[ri].worktrees[wi].path == path {
                                    appStateBinding.wrappedValue.repos[ri].worktrees[wi]
                                        .clearPaneAttentionIfTimestamp(stamp, for: terminalID)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @MainActor
    private static func handleNotification(
        _ message: NotificationMessage,
        appState: Binding<AppState>,
        terminalManager: TerminalManager
    ) {
        switch message {
        case .notify(let path, let text, let clearAfter, let paneSessionName):
            // Defense-in-depth behind the CLI's ATTN-1.7 guard: reject
            // empty / whitespace-only text silently so a raw socket
            // client (`nc -U`, custom script, web surface) can't write
            // an invisible red capsule Andy can't read or dismiss.
            guard Attention.isValidText(text) else { return }
            // Normalize the requested auto-clear duration against the
            // server's contract: ≤0 → nil (STATE-2.8), >24h → clamped
            // to 24h (STATE-2.9). A non-CLI socket client can still
            // send ridiculous values; `effectiveClearAfter` makes the
            // server a single source of truth for what actually
            // schedules.
            let effectiveClearAfter = Attention.effectiveClearAfter(clearAfter)
            // AGENT-4.1/4.2: when the message carries a pane session name,
            // resolve it to a pane slot within the targeted worktree and
            // write pane-scoped attention. Reuse `setAttentionForTerminal`
            // for the auto-clear path; for the no-clear case write the slot
            // directly. Falls through to worktree-scoped if it resolves no
            // live pane (e.g. the session ended).
            if let paneSessionName {
                for repoIdx in appState.wrappedValue.repos.indices {
                    for wtIdx in appState.wrappedValue.repos[repoIdx].worktrees.indices
                        where appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].path == path {
                        guard let slot = appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                            .paneSlot(forSessionName: paneSessionName) else { continue }
                        if let effectiveClearAfter {
                            setAttentionForTerminal(
                                appState: appState,
                                terminalID: slot,
                                text: text,
                                clearAfter: effectiveClearAfter,
                                source: .userNotify
                            )
                        } else {
                            appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                                .setAttention(
                                    Attention(text: text, timestamp: Date(), source: .userNotify),
                                    pane: slot
                                )
                        }
                        return
                    }
                }
            }
            // Pin the timestamp the attention carries AND the auto-clear
            // timer closes over, so the timer can verify it's still OUR
            // notification when it fires (cf. WorktreeEntry.clearAttentionIfTimestamp).
            let stamp = Date()
            for repoIdx in appState.wrappedValue.repos.indices {
                for wtIdx in appState.wrappedValue.repos[repoIdx].worktrees.indices {
                    if appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].path == path {
                        appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].setAttention(
                            Attention(
                                text: text,
                                timestamp: stamp,
                                clearAfter: effectiveClearAfter,
                                source: .userNotify
                            ),
                            pane: nil
                        )

                        if let effectiveClearAfter {
                            DispatchQueue.main.asyncAfter(deadline: .now() + effectiveClearAfter) {
                                for ri in appState.wrappedValue.repos.indices {
                                    for wi in appState.wrappedValue.repos[ri].worktrees.indices {
                                        if appState.wrappedValue.repos[ri].worktrees[wi].path == path {
                                            appState.wrappedValue.repos[ri].worktrees[wi].clearAttentionIfTimestamp(stamp)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        case .clear(let path, let paneSessionName):
            // AGENT-4.x: a pane-scoped clear targets just that pane's
            // attention slot; resolve the session name within the worktree
            // and fall through to worktree-scoped clear if unresolved.
            if let paneSessionName {
                for repoIdx in appState.wrappedValue.repos.indices {
                    for wtIdx in appState.wrappedValue.repos[repoIdx].worktrees.indices
                        where appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].path == path {
                        if let slot = appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                            .paneSlot(forSessionName: paneSessionName) {
                            appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                                .paneAttention[slot] = nil
                            return
                        }
                    }
                }
            }
            for repoIdx in appState.wrappedValue.repos.indices {
                for wtIdx in appState.wrappedValue.repos[repoIdx].worktrees.indices {
                    if appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].path == path {
                        appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].attention = nil
                    }
                }
            }
        case .listPanes, .addPane, .closePane, .showPane, .sendPane, .teamMessage, .teamSend,
             .teamBroadcast, .teamHook, .teamInbox, .teamMembers, .teamList,
             .createWorktree, .agentPromptStagingCapability, .worktreeBaseCapability,
             .worktreeCreateIdempotencyCapability,
             .worktreeCreateStatus, .removeWorktree, .worktreeRemoveCapability,
             .worktreeRemoveStatus:
            // Request-style messages are handled by handlePaneRequest via
            // the SocketServer.onRequest callback; they are no-ops on the
            // fire-and-forget onMessage path.
            break
        }
    }

    /// Dispatcher for request-style messages from the CLI. Returns a
    /// `ResponseMessage` the server writes back to the client. Must run
    /// on the main actor because it touches `appState` and `terminalManager`.
    @MainActor
    fileprivate static func handlePaneRequest(
        _ message: NotificationMessage,
        appState: Binding<AppState>,
        terminalManager: TerminalManager,
        teamInbox: TeamInbox,
        teamEventDispatcher: TeamEventDispatcher,
        worktreeMonitor: WorktreeMonitor,
        statsStore: WorktreeStatsStore,
        prStatusStore: PRStatusStore,
        worktreeCreations: CLIWorktreeCreationStore,
        worktreeRemovals: CLIWorktreeRemovalStore,
        remoteBranchStore: RemoteBranchStore
    ) async -> ResponseMessage? {
        switch message {
        case .listPanes(let path):
            return listPanes(path: path, appState: appState, terminalManager: terminalManager)
        case .addPane(let path, let direction, let command):
            return addPane(path: path, direction: direction, command: command,
                           appState: appState, terminalManager: terminalManager)
        case .closePane(let path, let index):
            return closePaneByIndex(path: path, index: index,
                                    appState: appState, terminalManager: terminalManager)
        case .showPane(let path, let index, let lines):
            guard let launcher = terminalManager.zmxLauncher else {
                return .error("zmx unavailable")
            }
            guard let wt = appState.wrappedValue.worktree(forPath: path) else {
                return .error("not tracked")
            }
            guard wt.state == .running else {
                return .error("worktree not running")
            }
            guard let terminalID = wt.splitTree.leaf(atPaneID: index) else {
                return .error("no pane with id \(index) in this worktree")
            }
            guard let sessionID = wt.paneSessions[terminalID] else {
                return .error("pane has no session")
            }
            let reader = ZmxHistorySubprocessReader(launcher: launcher)
            let sessionName = ZmxLauncher.sessionName(for: sessionID)
            return await Task.detached(priority: .utility) {
                do {
                    let body = try reader.history(sessionName: sessionName)
                    return .paneShow(ScrollbackTail.tail(body, lines: lines))
                } catch {
                    return .error("zmx history failed: \(error.localizedDescription)")
                }
            }.value
        case .sendPane(let path, let index, let text, let pressEnter):
            return await handleSendPane(
                path: path, index: index, text: text, pressEnter: pressEnter,
                appState: appState, terminalManager: terminalManager
            )
        case .teamMessage(let callerPath, let recipient, let text):
            return await handleTeamSend(
                callerPath: callerPath,
                recipient: recipient,
                text: text,
                priority: .normal,
                appState: appState,
                teamInbox: teamInbox,
                teamEventDispatcher: teamEventDispatcher
            )
        case .teamSend(let callerPath, let recipient, let text, let priority):
            return await handleTeamSend(
                callerPath: callerPath,
                recipient: recipient,
                text: text,
                priority: priority,
                appState: appState,
                teamInbox: teamInbox,
                teamEventDispatcher: teamEventDispatcher
            )
        case .teamBroadcast(let callerPath, let text, let priority):
            return await handleTeamBroadcast(
                callerPath: callerPath,
                text: text,
                priority: priority,
                appState: appState,
                teamInbox: teamInbox,
                teamEventDispatcher: teamEventDispatcher
            )
        case .teamHook(let callerPath, let runtime, let event, let sessionID, let paneSessionName):
            return await handleTeamHook(
                callerPath: callerPath,
                runtime: runtime,
                event: event,
                sessionID: sessionID,
                paneSessionName: paneSessionName,
                appState: appState,
                teamInbox: teamInbox,
                teamEventDispatcher: teamEventDispatcher,
                terminalManager: terminalManager,
                remoteBranchStore: remoteBranchStore
            )
        case .teamInbox(let callerPath, let worktree, let repo, let member, let unread, let all, let beforeID, let limit):
            return await handleTeamInbox(
                callerPath: callerPath,
                worktree: worktree,
                repo: repo,
                member: member,
                unread: unread,
                all: all,
                beforeID: beforeID,
                limit: limit,
                appState: appState,
                teamInbox: teamInbox,
                teamEventDispatcher: teamEventDispatcher
            )
        case .teamMembers(let callerPath, let worktree, let repo):
            return handleTeamMembers(
                callerPath: callerPath,
                worktree: worktree,
                repo: repo,
                appState: appState,
                teamInbox: teamInbox,
                teamEventDispatcher: teamEventDispatcher
            )
        case .teamList(let callerPath):
            return handleTeamMembers(
                callerPath: callerPath,
                worktree: nil,
                repo: nil,
                appState: appState,
                teamInbox: teamInbox,
                teamEventDispatcher: teamEventDispatcher
            )
        case .agentPromptStagingCapability:
            return .ok
        case .worktreeBaseCapability:
            return .ok
        case .worktreeCreateIdempotencyCapability:
            return .ok
        case .worktreeRemoveCapability:
            return .ok
        case .createWorktree(
            let callerPath,
            let worktreeName,
            let branchName,
            let existing,
            let base,
            let command,
            let agentRuntime,
            let agentPrompt,
            let operationID
        ):
            return beginCLIWorktreeCreation(
                callerPath: callerPath,
                worktreeName: worktreeName,
                branchName: branchName,
                existing: existing,
                base: base,
                command: command,
                agentRuntime: agentRuntime,
                agentPrompt: agentPrompt,
                operationID: operationID,
                appState: appState,
                terminalManager: terminalManager,
                teamEventDispatcher: teamEventDispatcher,
                worktreeMonitor: worktreeMonitor,
                statsStore: statsStore,
                worktreeCreations: worktreeCreations
            )
        case .worktreeCreateStatus(let operationID):
            guard let status = worktreeCreations.status(operationID: operationID) else {
                return .error("unknown or expired worktree creation operation")
            }
            return .worktreeCreate(status)
        case .removeWorktree(let worktreePath, let force):
            return beginCLIWorktreeRemoval(
                worktreePath: worktreePath,
                force: force,
                appState: appState,
                terminalManager: terminalManager,
                statsStore: statsStore,
                prStatusStore: prStatusStore,
                teamEventDispatcher: teamEventDispatcher,
                worktreeRemovals: worktreeRemovals
            )
        case .worktreeRemoveStatus(let operationID):
            guard let status = worktreeRemovals.status(operationID: operationID) else {
                return .error("unknown or expired worktree removal operation")
            }
            return .worktreeRemove(status)
        case .notify, .clear:
            // Fire-and-forget cases — no response. `onMessage` already handled them.
            return nil
        }
    }

    @MainActor
    private static func beginCLIWorktreeRemoval(
        worktreePath: String,
        force: Bool,
        appState: Binding<AppState>,
        terminalManager: TerminalManager,
        statsStore: WorktreeStatsStore,
        prStatusStore: PRStatusStore,
        teamEventDispatcher: TeamEventDispatcher,
        worktreeRemovals: CLIWorktreeRemovalStore
    ) -> ResponseMessage {
        guard let (repoIndex, worktreeIndex) = appState.wrappedValue
            .indices(forWorktreePath: worktreePath) else {
            return .error("unknown worktree")
        }
        let repo = appState.wrappedValue.repos[repoIndex]
        let worktree = repo.worktrees[worktreeIndex]
        guard worktree.path != repo.path else {
            return .error("cannot remove the main checkout")
        }
        guard worktree.state != .deleting else {
            return .error("worktree removal is already in progress")
        }
        guard !worktreeRemovals.hasPendingRemoval(worktreePath: worktreePath) else {
            return .error("worktree removal is already in progress")
        }

        let status = worktreeRemovals.begin(worktreePath: worktreePath)
        Task { @MainActor in
            let result = await DeleteWorktreeFlow.delete(
                worktreePath: worktreePath,
                force: force,
                appState: appState,
                terminalManager: terminalManager,
                statsStore: statsStore,
                prStatusStore: prStatusStore,
                teamEventDispatcher: teamEventDispatcher
            )
            switch result {
            case .success:
                worktreeRemovals.markRemoved(operationID: status.operationID)
            case .failure(.gitFailedForceable(let stderr, let shortStatus)):
                worktreeRemovals.markFailed(
                    operationID: status.operationID,
                    error: stderr,
                    forceAllowed: true,
                    shortStatus: shortStatus.isEmpty ? nil : shortStatus
                )
            case .failure(.gitFailedFinal(let message)):
                worktreeRemovals.markFailed(
                    operationID: status.operationID,
                    error: message,
                    forceAllowed: false
                )
            case .failure(.notFound):
                worktreeRemovals.markFailed(
                    operationID: status.operationID,
                    error: "unknown worktree",
                    forceAllowed: false
                )
            case .failure(.mainCheckoutRejected):
                worktreeRemovals.markFailed(
                    operationID: status.operationID,
                    error: "cannot remove the main checkout",
                    forceAllowed: false
                )
            }
        }
        return .worktreeRemove(status)
    }

    @MainActor
    private static func beginCLIWorktreeCreation(
        callerPath: String,
        worktreeName: String,
        branchName: String,
        existing: Bool,
        base: String?,
        command: String?,
        agentRuntime: TeamHookRuntime?,
        agentPrompt: String?,
        operationID: String?,
        appState: Binding<AppState>,
        terminalManager: TerminalManager,
        teamEventDispatcher: TeamEventDispatcher,
        worktreeMonitor: WorktreeMonitor,
        statsStore: WorktreeStatsStore,
        worktreeCreations: CLIWorktreeCreationStore
    ) -> ResponseMessage {
        if let operationID,
           let existing = worktreeCreations.status(operationID: operationID) {
            return .worktreeCreate(existing)
        }
        if let error = CLIWorktreeCreationPolicy.validationError(
            agentRuntime: agentRuntime,
            teamsEnabled: UserDefaults.standard.bool(forKey: SettingsKeys.agentTeamsEnabled)
        ) {
            return .error(error)
        }
        guard let repo = appState.wrappedValue.repos.first(where: { repo in
            repo.worktrees.contains(where: { $0.path == callerPath })
        }) else {
            return .error("caller is not inside a tracked worktree")
        }

        if agentPrompt != nil, agentRuntime == nil {
            return .error("an agent prompt requires an agent runtime")
        }
        if let error = CLIWorktreeCreationPolicy.obsoletePromptLoaderError(
            agentRuntime: agentRuntime,
            command: command,
            agentPrompt: agentPrompt
        ) {
            return .error(error)
        }
        let launch: PreparedWorktreeAgentLaunch
        if let agentRuntime,
           CLIWorktreeCreationPolicy.shouldStageAgentPrompt(
               agentRuntime: agentRuntime,
               command: command,
               agentPrompt: agentPrompt
           ) {
            do {
                launch = try WorktreeAgentLaunchCommand.prepare(
                    agent: agentRuntime,
                    prompt: agentPrompt,
                    exactCommand: nil
                )
            } catch {
                return .error("could not stage agent prompt: \(error.localizedDescription)")
            }
        } else {
            launch = PreparedWorktreeAgentLaunch(command: command, promptFile: nil)
        }

        let branch: BranchSelection = existing
            ? .useExisting(name: branchName, source: .local)
            : .createNew(name: branchName)
        let worktreePath: String
        switch AddWorktreeFlow.beginCreate(
            repoPath: repo.path,
            worktreeName: worktreeName,
            branch: branch,
            base: base,
            appState: appState
        ) {
        case .success(let path):
            worktreePath = path
        case .failure(let error):
            launch.discardPromptFile()
            return .error(error.userMessage ?? "could not begin worktree creation")
        }

        let status = worktreeCreations.begin(
            worktreePath: worktreePath,
            messageAddress: worktreePath,
            stagedPromptFile: launch.promptFile,
            operationID: operationID
        )
        let initialCommand = launch.command.flatMap { value in
            value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
        }
        Task { @MainActor in
            let result = await AddWorktreeFlow.finishCreate(
                repoPath: repo.path,
                worktreePath: worktreePath,
                branch: branch,
                base: base,
                baseResolutionPath: callerPath,
                appState: appState,
                worktreeMonitor: worktreeMonitor,
                statsStore: statsStore,
                terminalManager: terminalManager,
                teamEventDispatcher: teamEventDispatcher,
                initialCommand: initialCommand,
                terminalStartTiming: AddWorktreeFlow.terminalStartTiming(for: .cli)
            )
            switch result {
            case .success:
                worktreeCreations.markReady(operationID: status.operationID)
            case .failure(let error):
                let message: String
                if case .discoveryFailed(let detail) = error {
                    message = detail
                } else {
                    message = error.userMessage ?? "worktree creation failed"
                }
                worktreeCreations.markFailed(operationID: status.operationID, error: message)
            }
        }
        return .worktreeCreate(status)
    }

    @MainActor
    private static func handleTeamSend(
        callerPath: String,
        recipient: String,
        text: String,
        priority: TeamInboxPriority,
        appState: Binding<AppState>,
        teamInbox: TeamInbox,
        teamEventDispatcher: TeamEventDispatcher
    ) async -> ResponseMessage {
        do {
            let handler = teamInboxRequestHandler(inbox: teamInbox, dispatcher: teamEventDispatcher)
            let repos = appState.wrappedValue.repos
            let teamsEnabled = UserDefaults.standard.bool(forKey: SettingsKeys.agentTeamsEnabled)
            // ATTN-2.19: the append happens off the main actor so inbox
            // file contention cannot wedge the control socket.
            _ = try await OffMainIO.run {
                try handler.send(
                    callerWorktree: callerPath,
                    recipient: recipient,
                    text: text,
                    priority: priority,
                    repos: repos,
                    teamsEnabled: teamsEnabled
                )
            }
            return .ok
        } catch let error as TeamInboxRequestError {
            return .error(error.description)
        } catch {
            return .error("failed to write team inbox message: \(error)")
        }
    }

    @MainActor
    private static func handleTeamBroadcast(
        callerPath: String,
        text: String,
        priority: TeamInboxPriority,
        appState: Binding<AppState>,
        teamInbox: TeamInbox,
        teamEventDispatcher: TeamEventDispatcher
    ) async -> ResponseMessage {
        do {
            let handler = teamInboxRequestHandler(inbox: teamInbox, dispatcher: teamEventDispatcher)
            let repos = appState.wrappedValue.repos
            let teamsEnabled = UserDefaults.standard.bool(forKey: SettingsKeys.agentTeamsEnabled)
            // ATTN-2.19: see handleTeamSend.
            _ = try await OffMainIO.run {
                try handler.broadcast(
                    callerWorktree: callerPath,
                    text: text,
                    priority: priority,
                    repos: repos,
                    teamsEnabled: teamsEnabled
                )
            }
            return .ok
        } catch let error as TeamInboxRequestError {
            return .error(error.description)
        } catch {
            return .error("failed to write team inbox broadcast: \(error)")
        }
    }

    @MainActor
    private static func handleTeamHook(
        callerPath: String,
        runtime: TeamHookRuntime,
        event: TeamHookEvent,
        sessionID: String?,
        paneSessionName: String?,
        appState: Binding<AppState>,
        teamInbox: TeamInbox,
        teamEventDispatcher: TeamEventDispatcher,
        terminalManager: TerminalManager,
        remoteBranchStore: RemoteBranchStore
    ) async -> ResponseMessage {
        do {
            let teamsEnabled = UserDefaults.standard.bool(forKey: SettingsKeys.agentTeamsEnabled)
            // Snapshotted before the instruction render's `await`; the
            // ownership decision below therefore reads presence as it stood
            // at hook entry, not as it stands when the decision runs. That
            // was already true of any await on this path — the render only
            // widens the window — and a stale snapshot at worst hands
            // delivery to a pane that has just gone away.
            // ATTN-2.19: the presence read is file I/O, so it runs off the
            // main actor like the inbox work below.
            let presenceRecords = await OffMainIO.run {
                (try? TeamPresenceStorage(
                    rootDirectory: TeamPresenceStorage.defaultRoot()
                ).listAll()) ?? []
            }
            let liveSessionNames = Self.livePaneSessionNamesForAutomaticDelivery(
                records: presenceRecords,
                terminalManager: terminalManager
            )
            let instructions: String
            if event == .sessionStart,
               teamsEnabled,
               let team = TeamLookup.team(
                   for: callerPath,
                   in: appState.wrappedValue.repos
               ),
               let viewer = team.members.first(where: { $0.worktreePath == callerPath }) {
                instructions = await InstructionSessionText.render(
                    team: team,
                    viewer: viewer,
                    defaultBranch: remoteBranchStore.resolvedDefaultBranch(
                        forRepoAt: team.repoPath,
                        hint: appState.wrappedValue
                            .repo(forWorktreePath: callerPath)?.defaultBranchHint
                    )
                )
            } else {
                instructions = ""
            }
            let handler = teamInboxRequestHandler(
                inbox: teamInbox,
                dispatcher: teamEventDispatcher,
                automaticDeliveryOwner: { teamID, worktree, runtime, paneSessionName in
                    let resolver = TeamDeliveryOwnershipResolver(
                        records: { presenceRecords },
                        liveness: AppTeamDeliveryLiveness(
                            livePaneSession: { liveSessionNames.contains($0) },
                            processStartTimeMicroseconds: { ProcessIdentityReader.startTimeMicroseconds(ofPID: $0) }
                        )
                    )
                    let key = TeamDeliveryOwnerKey(teamID: teamID, worktree: worktree, runtime: runtime)
                    guard let owner = resolver.owner(for: key) else {
                        // Preserve direct-shell / registration-failure fallback:
                        // only suppress a hook when another live pane is a
                        // positively identified owner.
                        return true
                    }
                    return owner.paneSessionName == paneSessionName
                }
            )
            let repos = appState.wrappedValue.repos
            // ATTN-2.19: hook delivery parses the full inbox history and
            // can wait on the inter-process watermark lock; it fires on
            // every PostToolUse of every agent, so on the main actor it
            // wedged the control socket under agent activity.
            let output = try await OffMainIO.run {
                try handler.hook(
                    callerWorktree: callerPath,
                    runtime: runtime,
                    event: event,
                    sessionID: sessionID,
                    paneSessionName: paneSessionName,
                    repos: repos,
                    teamsEnabled: teamsEnabled,
                    instructions: instructions
                )
            }
            if event == .stop {
                recordAgentStop(
                    callerPath: callerPath,
                    runtime: runtime,
                    sessionID: sessionID,
                    paneSessionName: paneSessionName,
                    appState: appState
                )
            }
            return .teamHookOutput(output)
        } catch let error as TeamInboxRequestError {
            return .error(error.description)
        } catch {
            return .error("failed to render team hook context: \(error)")
        }
    }

    @MainActor
    private static func recordAgentStop(
        callerPath: String,
        runtime: TeamHookRuntime,
        sessionID: String?,
        paneSessionName: String?,
        appState: Binding<AppState>
    ) {
        let timestamp = Date()
        for repoIndex in appState.wrappedValue.repos.indices {
            for worktreeIndex in appState.wrappedValue.repos[repoIndex].worktrees.indices
                where appState.wrappedValue.repos[repoIndex].worktrees[worktreeIndex].path == callerPath {
                let worktree = appState.wrappedValue.repos[repoIndex].worktrees[worktreeIndex]
                let worktreeName = WorktreeNameSanitizer.sanitize(worktree.branch)
                let resolvedSessionID = sessionID ?? "\(runtime.rawValue):\(worktreeName):\(callerPath)"
                let attention = Attention(
                    text: "\(AgentStopNotification.displayName(runtime)) needs input",
                    timestamp: timestamp,
                    source: .agentStop
                )
                let pane: PaneSlotID?
                switch AgentStopAttentionTarget.resolve(worktree: worktree, paneSessionName: paneSessionName) {
                case .pane(let slot): pane = slot
                case .worktree: pane = nil
                }
                appState.wrappedValue.repos[repoIndex].worktrees[worktreeIndex]
                    .setAttention(attention, pane: pane)
                AgentNotificationRouter.shared.post(
                    AgentStopNotification.content(
                        runtime: runtime,
                        worktreeName: worktreeName,
                        worktreePath: callerPath,
                        sessionID: resolvedSessionID,
                        paneSessionName: paneSessionName,
                        timestamp: timestamp
                    )
                )
                return
            }
        }
    }

    @MainActor
    private static func activateAgentStopNotification(
        _ payload: AgentStopNotificationPayload,
        appState: Binding<AppState>,
        terminalManager: TerminalManager
    ) {
        NSApp.activate(ignoringOtherApps: true)
        AgentStopNotification.acknowledgeSelection(
            appState: &appState.wrappedValue,
            worktreePath: payload.worktreePath
        )
        if let worktree = appState.wrappedValue.worktree(forPath: payload.worktreePath),
           let terminalID = agentStopFocusTarget(
               worktree: worktree, paneSessionName: payload.paneSessionName) {
            terminalManager.setFocus(terminalID)
        }
    }

    /// AGENT-3.3: the pane to focus when an agent-stop notification is
    /// activated — the pane whose session produced it (resolved by the
    /// same `AgentStopAttentionTarget` rule the post path uses to place
    /// the attention capsule, so focus and capsule can't disagree),
    /// falling back to the worktree's first pane when it no longer
    /// resolves (e.g. the agent's pane was closed, or it was a
    /// worktree-scoped ping).
    static func agentStopFocusTarget(
        worktree: WorktreeEntry,
        paneSessionName: String?
    ) -> PaneSlotID? {
        switch AgentStopAttentionTarget.resolve(
            worktree: worktree, paneSessionName: paneSessionName) {
        case .pane(let slot): return slot
        case .worktree: return worktree.firstPane
        }
    }

    @MainActor
    private static func handleTeamInbox(
        callerPath: String?,
        worktree: String?,
        repo: String?,
        member: String?,
        unread: Bool,
        all: Bool,
        beforeID: String?,
        limit: Int?,
        appState: Binding<AppState>,
        teamInbox: TeamInbox,
        teamEventDispatcher: TeamEventDispatcher
    ) async -> ResponseMessage {
        do {
            let handler = teamInboxRequestHandler(inbox: teamInbox, dispatcher: teamEventDispatcher)
            let repos = appState.wrappedValue.repos
            let teamsEnabled = UserDefaults.standard.bool(forKey: SettingsKeys.agentTeamsEnabled)
            // ATTN-2.19: the inbox page parses the full message history
            // off the main actor.
            let page = try await OffMainIO.run {
                try handler.diagnosticPage(
                    callerWorktree: callerPath,
                    worktree: worktree,
                    repo: repo,
                    member: member,
                    unread: unread,
                    all: all,
                    beforeID: beforeID,
                    limit: limit,
                    repos: repos,
                    teamsEnabled: teamsEnabled
                )
            }
            return .teamInbox(messages: page.messages, nextBeforeID: page.nextBeforeID)
        } catch let error as TeamInboxRequestError {
            return .error(error.description)
        } catch {
            return .error("failed to read team inbox: \(error)")
        }
    }

    @MainActor
    private static func handleTeamMembers(
        callerPath: String?,
        worktree: String?,
        repo: String?,
        appState: Binding<AppState>,
        teamInbox: TeamInbox,
        teamEventDispatcher: TeamEventDispatcher
    ) -> ResponseMessage {
        do {
            let result = try teamInboxRequestHandler(inbox: teamInbox, dispatcher: teamEventDispatcher).members(
                callerWorktree: callerPath,
                worktree: worktree,
                repo: repo,
                repos: appState.wrappedValue.repos,
                teamsEnabled: UserDefaults.standard.bool(forKey: SettingsKeys.agentTeamsEnabled)
            )
            return .teamList(teamName: result.teamName, members: result.members)
        } catch let error as TeamInboxRequestError {
            return .error(error.description)
        } catch {
            return .error("failed to list team members: \(error)")
        }
    }

    private static func teamInboxRequestHandler(
        inbox: TeamInbox,
        dispatcher: TeamEventDispatcher,
        automaticDeliveryOwner: (@Sendable (
            _ teamID: String,
            _ worktree: String,
            _ runtime: TeamHookRuntime,
            _ paneSessionName: String?
        ) -> Bool)? = nil
    ) -> TeamInboxRequestHandler {
        TeamInboxRequestHandler(
            inbox: inbox,
            dispatcher: dispatcher,
            sessionPromptRenderer: renderTeamSessionPrompt(team:viewer:),
            automaticDeliveryOwner: automaticDeliveryOwner
        )
    }

    private static func renderTeamSessionPrompt(team: TeamView, viewer: TeamMember) -> String? {
        let template = UserDefaults.standard.string(forKey: SettingsKeys.teamSessionPrompt) ?? ""
        return TeamInstructionsRenderer.render(
            template: template,
            team: team,
            viewer: viewer
        )
    }

    @MainActor
    private static func listPanes(
        path: String,
        appState: Binding<AppState>,
        terminalManager: TerminalManager
    ) -> ResponseMessage {
        guard let wt = appState.wrappedValue.worktree(forPath: path) else {
            return .error("not tracked")
        }
        // Symmetric with `addPane` / `closePaneByIndex`: a .closed worktree
        // has no panes by construction, and returning an empty `.paneList`
        // looks like a silent success to scripts. Surface the state
        // explicitly instead (ATTN-3.5).
        guard wt.state == .running else {
            return .error("worktree not running")
        }
        let leaves = wt.splitTree.allLeaves
        let panes = leaves.enumerated().map { (i, terminalID) -> PaneInfo in
            // Use the derived label (title → PWD basename → nil) so the
            // CLI sees the same fallback chain the sidebar renders. Map
            // the view-level empty sentinel back to nil for the CLI
            // contract "title is nil when unknown".
            let display = terminalManager.displayTitle(for: terminalID)
            return PaneInfo(
                id: i + 1,
                title: display.isEmpty ? nil : display,
                focused: terminalID == wt.focusedPaneSlotID
            )
        }
        return .paneList(panes)
    }

    @MainActor
    private static func addPane(
        path: String,
        direction: PaneSplit,
        command: String?,
        appState: Binding<AppState>,
        terminalManager: TerminalManager
    ) -> ResponseMessage {
        guard let wt = appState.wrappedValue.worktree(forPath: path) else {
            return .error("not tracked")
        }
        guard wt.state == .running else {
            return .error("worktree not running")
        }
        guard let targetID = wt.firstPane else {
            return .error("no panes to split")
        }
        guard let newID = splitPane(
            appState: appState,
            terminalManager: terminalManager,
            targetID: targetID,
            split: direction
        ) else {
            return .error("split failed")
        }
        if let command, !command.isEmpty {
            // splitPane's `command` is automation, not a user keystroke
            // on the newly-created surface — keep IOS-12.1's silent
            // gate closed.
            terminalManager.handle(for: newID)?.typeText(command + "\r", claimEngagement: false)
        }
        return .ok
    }

    @MainActor
    private static func closePaneByIndex(
        path: String,
        index: Int,
        appState: Binding<AppState>,
        terminalManager: TerminalManager
    ) -> ResponseMessage {
        guard let wt = appState.wrappedValue.worktree(forPath: path) else {
            return .error("not tracked")
        }
        // Symmetric with `addPane`. A .closed worktree's splitTree is
        // empty; the "no pane with id N" error would technically be
        // correct but misleads about the root cause (ATTN-3.5).
        guard wt.state == .running else {
            return .error("worktree not running")
        }
        guard let targetID = wt.splitTree.leaf(atPaneID: index) else {
            return .error("no pane with id \(index) in this worktree")
        }
        closePane(
            appState: appState,
            terminalManager: terminalManager,
            targetID: targetID,
            userInitiated: true
        )
        return .ok
    }

    @MainActor
    fileprivate static func handleShowPane(
        path: String,
        index: Int,
        lines: Int,
        appState: Binding<AppState>,
        terminalManager: TerminalManager,
        reader: ZmxHistoryReader
    ) -> ResponseMessage {
        guard let wt = appState.wrappedValue.worktree(forPath: path) else {
            return .error("not tracked")
        }
        guard wt.state == .running else {
            return .error("worktree not running")
        }
        guard let terminalID = wt.splitTree.leaf(atPaneID: index) else {
            return .error("no pane with id \(index) in this worktree")
        }
        guard let sessionID = wt.paneSessions[terminalID] else {
            return .error("pane has no session")
        }
        let session = ZmxLauncher.sessionName(for: sessionID)
        do {
            let body = try reader.history(sessionName: session)
            return .paneShow(ScrollbackTail.tail(body, lines: lines))
        } catch {
            return .error("zmx history failed: \(error.localizedDescription)")
        }
    }

    /// Test seam: lets the spec test exercise `handleShowPane` without
    /// constructing a full `AppState`. Skips worktree lookup / state checks
    /// and goes straight to the reader so we exercise the read+tail logic
    /// in isolation.
    @MainActor
    internal static func handleShowPane_forTesting(
        path: String, index: Int, lines: Int,
        reader: ZmxHistoryReader
    ) -> ResponseMessage {
        do {
            let body = try reader.history(sessionName: "graftty-stub")
            return .paneShow(ScrollbackTail.tail(body, lines: lines))
        } catch {
            return .error("zmx history failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    fileprivate static func handleSendPane(
        path: String,
        index: Int,
        text: String,
        pressEnter: Bool,
        appState: Binding<AppState>,
        terminalManager: TerminalManager
    ) async -> ResponseMessage {
        guard let wt = appState.wrappedValue.worktree(forPath: path) else {
            return .error("not tracked")
        }
        guard wt.state == .running else {
            return .error("worktree not running")
        }
        guard let terminalID = wt.splitTree.leaf(atPaneID: index) else {
            return .error("no pane with id \(index) in this worktree")
        }
        if let handle = terminalManager.handle(for: terminalID) {
            return handleSendPane_forTesting(
                text: text,
                pressEnter: pressEnter,
                sink: SurfaceHandlePaneInputSink(handle: handle)
            )
        }

        guard let sessionID = wt.paneSessions[terminalID] else {
            return .error("pane has no session")
        }
        guard let launcher = terminalManager.zmxLauncher else {
            return .error("pane has no surface and zmx is unavailable")
        }
        let sessionName = ZmxLauncher.sessionName(for: sessionID)
        let writer = ZmxPaneInputSubprocessWriter(launcher: launcher)
        return await Task.detached(priority: .utility) {
            handleSendPaneWithoutSurface_forTesting(
                text: text,
                pressEnter: pressEnter,
                sessionName: sessionName,
                writer: writer
            )
        }.value
    }

    /// Test seam: lets the spec test exercise acknowledged delivery without
    /// driving a libghostty surface. Production callers
    /// go through `handleSendPane` which performs worktree/pane validation
    /// before constructing a `SurfaceHandlePaneInputSink`.
    @MainActor
    internal static func handleSendPane_forTesting(
        text: String,
        pressEnter: Bool,
        sink: PaneInputSink
    ) -> ResponseMessage {
        guard sink.send(text: text, pressEnter: pressEnter) else {
            return .error("pane input was not accepted")
        }
        return .ok
    }

    nonisolated internal static func handleSendPaneWithoutSurface_forTesting(
        text: String,
        pressEnter: Bool,
        sessionName: String,
        writer: ZmxPaneInputWriter
    ) -> ResponseMessage {
        do {
            try writer.send(
                sessionName: sessionName,
                text: text + (pressEnter ? "\r" : "")
            )
            return .ok
        } catch {
            return .error("zmx send failed: \(error.localizedDescription)")
        }
    }

    private func splitFocusedPane(direction: SplitDirection) {
        guard let path = appState.selectedWorktreePath else { return }
        for repoIdx in appState.repos.indices {
            for wtIdx in appState.repos[repoIdx].worktrees.indices {
                let wt = appState.repos[repoIdx].worktrees[wtIdx]
                if wt.path == path, wt.state == .running,
                   let focused = wt.firstPane {
                    // Cmd+D = "Split Horizontally" = new pane to the right;
                    // Cmd+Shift+D = "Split Vertically" = new pane below. Map
                    // to `PaneSplit` so we reuse the same insertion logic as
                    // the context menu.
                    let split: PaneSplit = direction == .horizontal ? .right : .down
                    Self.splitPane(
                        appState: $appState,
                        terminalManager: terminalManager,
                        targetID: focused,
                        split: split
                    )
                    return
                }
            }
        }
    }

    /// Shared closed-to-running transition used by local sidebar selection
    /// and authenticated remote-open requests.
    @MainActor
    static func startWorktree(
        path: String,
        appState: Binding<AppState>,
        terminalManager: TerminalManager,
        startSurfacesInBackground: Bool = false
    ) -> WorktreeStartResult {
        for repoIdx in appState.wrappedValue.repos.indices {
            for wtIdx in appState.wrappedValue.repos[repoIdx].worktrees.indices
            where appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].path
                == path {
                let state = appState.wrappedValue.repos[repoIdx]
                    .worktrees[wtIdx].state
                guard state != .running else { return .alreadyRunning }
                guard state == .closed else { return .unavailable }

                if appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                    .splitTree.root == nil {
                    let id = PaneSlotID()
                    appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                        .splitTree = SplitTree(root: .leaf(id))
                }

                let splitTree = appState.wrappedValue.repos[repoIdx]
                    .worktrees[wtIdx].splitTree
                let leaves = splitTree.allLeaves
                for leafID in leaves {
                    appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                        .ensurePaneSession(for: leafID)
                }
                // TERM-1.4: a saved multi-pane layout still has only one
                // "first" pane for default-command eligibility. Keep that
                // pane stable even when focus has since moved elsewhere.
                _ = appState.wrappedValue.repos[repoIdx]
                    .worktrees[wtIdx].normalizeFocusedPane()
                let primaryPane = appState.wrappedValue.repos[repoIdx]
                    .worktrees[wtIdx].ensurePrimaryPane()
                if let primaryPane {
                    terminalManager.markFirstPane(primaryPane)
                }
                _ = terminalManager.createSurfaces(
                    for: splitTree,
                    paneSessions: appState.wrappedValue.repos[repoIdx]
                        .worktrees[wtIdx].paneSessions,
                    worktreePath: path
                )
                if startSurfacesInBackground,
                   !terminalManager.startSurfacesForBackgroundLaunch(
                       in: splitTree
                   ) {
                    NSLog(
                        "[Graftty] failed to start one or more background panes for %@",
                        path
                    )
                }
                appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].state =
                    .running
                return .started
            }
        }
        return .notFound
    }

    /// Shared split implementation used by local commands and authenticated
    /// pane-control requests. Remote callers can suppress host focus changes.
    @MainActor
    @discardableResult
    fileprivate static func splitPane(
        appState: Binding<AppState>,
        terminalManager: TerminalManager,
        targetID: PaneSlotID,
        split: PaneSplit,
        extraInitialInput: String? = nil,
        activateNewPane: Bool = true,
        preserveZoom: Bool = false
    ) -> PaneSlotID? {
        for repoIdx in appState.wrappedValue.repos.indices {
            for wtIdx in appState.wrappedValue.repos[repoIdx].worktrees.indices {
                let candidate = appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                guard candidate.state == .running,
                      candidate.splitTree.containsLeaf(targetID) else {
                    continue
                }
                // A split never changes which existing pane is primary.
                // Migrate legacy running state before adding a new leaf so
                // Split Left/Up cannot accidentally elect the new pane by
                // tree order.
                _ = appState.wrappedValue.repos[repoIdx]
                    .worktrees[wtIdx].ensurePrimaryPane()
                let wt = appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                if let primaryPane = wt.primaryPane {
                    terminalManager.markFirstPane(primaryPane)
                }

                let direction: SplitDirection = (split == .right || split == .left) ? .horizontal : .vertical
                let newID = PaneSlotID()
                var newTree: SplitTree
                switch split {
                case .right, .down:
                    newTree = wt.splitTree.inserting(newID, at: targetID, direction: direction)
                case .left, .up:
                    newTree = wt.splitTree.insertingBefore(newID, at: targetID, direction: direction)
                }
                if preserveZoom, let zoomed = wt.splitTree.zoomed {
                    newTree = newTree.withZoom(zoomed)
                }
                appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].splitTree = newTree
                let paneSessionID = appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                    .ensurePaneSession(for: newID)
                // TERM-5.5: createSurface can now fail gracefully
                // (libghostty returned null). Roll back the split-tree
                // mutation so we don't leave a dangling leaf that renders
                // forever as `Color.black + ProgressView`. Returning nil
                // propagates to callers like `addPane` which emit a
                // readable socket `.error`.
                guard terminalManager.createSurface(
                    terminalID: newID,
                    paneSessionID: paneSessionID,
                    worktreePath: wt.path,
                    extraInitialInput: extraInitialInput
                ) != nil else {
                    appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].splitTree = wt.splitTree
                    appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].clearPaneSession(for: newID)
                    terminalManager.discardPaneSessionMetadata(for: newID)
                    return nil
                }
                if activateNewPane {
                    appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                        .focusedPaneSlotID = newID
                    terminalManager.setFocus(newID)
                }
                return newID
            }
        }
        return nil
    }

    /// Find the worktree that owns `terminalID` and set the attention
    /// badge on *that specific pane*. The shell-integration event that
    /// drives this callback (`COMMAND_FINISHED`) is emitted by one
    /// concrete pane, so the badge belongs on its row and nobody else's —
    /// writing to the worktree-level `attention` slot would light up
    /// every sibling pane in the sidebar. No-op if the terminal isn't
    /// in any worktree (e.g., it was just destroyed). Auto-clears after
    /// `clearAfter` seconds.
    @MainActor
    fileprivate static func setAttentionForTerminal(
        appState: Binding<AppState>,
        terminalID: PaneSlotID,
        text: String,
        clearAfter: TimeInterval,
        source: AttentionSource
    ) {
        // Pin a single Date so the stored attention AND the closure
        // share the same generation token (same shape as the
        // worktree-scoped fix in handleNotification). The closure
        // checks current timestamp == captured before clearing, so a
        // newer ping or an explicit clear that lands between the
        // schedule and the fire can't be wiped.
        let stamp = Date()
        for repoIdx in appState.wrappedValue.repos.indices {
            for wtIdx in appState.wrappedValue.repos[repoIdx].worktrees.indices {
                if appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                    .splitTree.containsLeaf(terminalID) {
                    appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                        .setAttention(
                            Attention(text: text, timestamp: stamp, clearAfter: clearAfter, source: source),
                            pane: terminalID
                        )
                    let path = appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].path
                    DispatchQueue.main.asyncAfter(deadline: .now() + clearAfter) {
                        for ri in appState.wrappedValue.repos.indices {
                            for wi in appState.wrappedValue.repos[ri].worktrees.indices {
                                if appState.wrappedValue.repos[ri].worktrees[wi].path == path {
                                    appState.wrappedValue.repos[ri].worktrees[wi]
                                        .clearPaneAttentionIfTimestamp(stamp, for: terminalID)
                                }
                            }
                        }
                    }
                    return
                }
            }
        }
    }

    /// Move a pane to the worktree whose path is the longest prefix of
    /// `newPWD`. No-op when `newPWD` matches no worktree, or matches the
    /// pane's current home.
    @MainActor
    static func reassignPaneByPWD(
        appState: Binding<AppState>,
        terminalManager: TerminalManager,
        terminalID: PaneSlotID,
        newPWD: String
    ) {
        // Find the currently-hosting worktree (by scanning splitTrees) so
        // we can compare against the target worktree and short-circuit if
        // nothing has changed.
        var currentRepoIdx: Int?
        var currentWorktreeIdx: Int?
        for (ri, repo) in appState.wrappedValue.repos.enumerated() {
            for (wi, wt) in repo.worktrees.enumerated() where wt.splitTree.containsLeaf(terminalID) {
                currentRepoIdx = ri
                currentWorktreeIdx = wi
            }
        }
        guard let currentRepoIdx, let currentWorktreeIdx else { return }

        // Longest-prefix match across every repo (handles nested worktrees:
        // a linked worktree at `/r/wt/feature` beats the main checkout at
        // `/r`). `AppState.worktreeIndicesMatching` is the single source
        // of truth — also called by the sidebar menu's auto-detect label.
        guard let (targetRepoIdx, targetWorktreeIdx) =
                appState.wrappedValue.worktreeIndicesMatching(path: newPWD),
              (targetRepoIdx, targetWorktreeIdx) != (currentRepoIdx, currentWorktreeIdx)
        else { return }

        // Remember where this pane was sitting in the source tree *before*
        // we remove it, so a later return trip can land it in (roughly)
        // the same spot.
        _ = appState.wrappedValue.repos[currentRepoIdx]
            .worktrees[currentWorktreeIdx].ensurePrimaryPane()
        let sourceWt = appState.wrappedValue.repos[currentRepoIdx].worktrees[currentWorktreeIdx]
        terminalManager.rememberPosition(
            terminalID: terminalID,
            worktreePath: sourceWt.path,
            in: sourceWt.splitTree
        )

        // Remove from source tree; if the source becomes empty, transition
        // its worktree back to .closed so the sidebar reflects that no
        // panes live there anymore.
        let sourceTree = sourceWt.splitTree.removing(terminalID)
        appState.wrappedValue.repos[currentRepoIdx].worktrees[currentWorktreeIdx].splitTree = sourceTree
        // Drop any pane-scoped attention badge attached to the moving
        // pane. The ping was tied to the source-worktree context; the
        // target worktree has its own separate attention state.
        appState.wrappedValue.repos[currentRepoIdx].worktrees[currentWorktreeIdx]
            .paneAttention[terminalID] = nil
        var sessionSource = appState.wrappedValue.repos[currentRepoIdx].worktrees[currentWorktreeIdx]
        var sessionTarget = appState.wrappedValue.repos[targetRepoIdx].worktrees[targetWorktreeIdx]
        _ = sessionSource.movePaneSession(for: terminalID, to: &sessionTarget)
        appState.wrappedValue.repos[currentRepoIdx].worktrees[currentWorktreeIdx].paneSessions =
            sessionSource.paneSessions
        appState.wrappedValue.repos[targetRepoIdx].worktrees[targetWorktreeIdx].paneSessions =
            sessionTarget.paneSessions
        if sourceTree.root == nil {
            appState.wrappedValue.repos[currentRepoIdx].worktrees[currentWorktreeIdx].state = .closed
            appState.wrappedValue.repos[currentRepoIdx].worktrees[currentWorktreeIdx].focusedPaneSlotID = nil
        } else {
            appState.wrappedValue.repos[currentRepoIdx].worktrees[currentWorktreeIdx].focusedPaneSlotID =
                SplitTree.focusAfterRemoving(
                    currentFocus: sourceWt.focusedPaneSlotID,
                    removed: terminalID,
                    remainingTree: sourceTree
                )
        }
        // Preserve the source's primary pane unless that was the pane that
        // moved. If it was, persist the focused survivor (or first leaf) as
        // the replacement; an empty source clears the primary.
        let replacementSourcePrimary = appState.wrappedValue.repos[currentRepoIdx]
            .worktrees[currentWorktreeIdx].ensurePrimaryPane()

        // Graft onto the target tree. Prefer a previously-remembered
        // position (pane is returning to a worktree it once occupied); if
        // the anchor from that memory is still present, reinsert there so
        // the layout feels like the pane "came back to its seat." Fall
        // back to inserting at an arbitrary leaf when no usable
        // breadcrumb exists.
        // Migrate an existing target's primary before inserting the moving
        // pane. Otherwise a left/top insertion could become primary merely
        // because it moved to the front of tree order.
        _ = appState.wrappedValue.repos[targetRepoIdx]
            .worktrees[targetWorktreeIdx].ensurePrimaryPane()
        let targetWt = appState.wrappedValue.repos[targetRepoIdx].worktrees[targetWorktreeIdx]
        let targetTree: SplitTree
        let remembered = terminalManager.rememberedPosition(
            terminalID: terminalID,
            worktreePath: targetWt.path
        )
        if let remembered, targetWt.splitTree.containsLeaf(remembered.anchorID) {
            switch remembered.placement {
            case .before:
                targetTree = targetWt.splitTree.insertingBefore(
                    terminalID,
                    at: remembered.anchorID,
                    direction: remembered.direction
                )
            case .after:
                targetTree = targetWt.splitTree.inserting(
                    terminalID,
                    at: remembered.anchorID,
                    direction: remembered.direction
                )
            }
            terminalManager.forgetPosition(terminalID: terminalID, worktreePath: targetWt.path)
        } else if let anchor = targetWt.splitTree.allLeaves.first {
            targetTree = targetWt.splitTree.inserting(terminalID, at: anchor, direction: .horizontal)
        } else {
            targetTree = SplitTree(root: .leaf(terminalID))
        }
        appState.wrappedValue.repos[targetRepoIdx].worktrees[targetWorktreeIdx].splitTree = targetTree
        appState.wrappedValue.repos[targetRepoIdx].worktrees[targetWorktreeIdx].state = .running
        appState.wrappedValue.repos[targetRepoIdx].worktrees[targetWorktreeIdx].focusedPaneSlotID = terminalID
        let targetPrimary = appState.wrappedValue.repos[targetRepoIdx]
            .worktrees[targetWorktreeIdx].ensurePrimaryPane()
        // PaneSlotIDs are globally unique, so moving a pane can safely
        // clear its source marker before applying both worktrees' current
        // primary ownership. This also handles an empty target electing
        // the moved pane.
        terminalManager.unmarkFirstPane(terminalID)
        if let replacementSourcePrimary {
            terminalManager.markFirstPane(replacementSourcePrimary)
        }
        if let targetPrimary {
            terminalManager.markFirstPane(targetPrimary)
        }
        let targetPath = targetWt.path
        if let paneSession = sessionTarget.paneSessions[terminalID] {
            terminalManager.recordPaneSession(
                paneSession,
                for: terminalID,
                worktreePath: targetPath
            )
        }

        // Follow the pane with the UI ONLY when the reassigned pane was the
        // user's active typing target — i.e. the focused pane of the
        // currently-selected worktree. `PWDReassignmentPolicy` encodes the
        // decision. Unconditionally switching selection used to hijack the
        // user's view whenever ANY background pane `cd`'d across a
        // worktree boundary — Andy's 3–6 concurrent Claude-session setup
        // made that immediately pathological. `PWD-2.3` (revised).
        let follow = PWDReassignmentPolicy.shouldFollowToDestination(
            selectedWorktreePath: appState.wrappedValue.selectedWorktreePath,
            sourceWorktreePath: sourceWt.path,
            sourceFocusedPaneSlotID: sourceWt.focusedPaneSlotID,
            reassignedPaneSlotID: terminalID
        )
        if follow {
            appState.wrappedValue.selectedWorktreePath = targetPath
            terminalManager.setFocus(terminalID)
        }
    }

    /// Static navigate used by the `onGotoSplit` callback (triggered from
    /// libghostty keybinds). Uses `SplitTree.spatialNeighbor` (`TERM-7.3`)
    /// so `.down` genuinely means "the pane spatially below," not "the
    /// next leaf in DFS order." When there is no neighbor in the requested
    /// direction the keypress is ignored — matching upstream Ghostty and
    /// terminal multiplexers like tmux, which leave focus put rather than
    /// wrapping to an unrelated pane.
    @MainActor
    fileprivate static func navigatePane(
        appState: Binding<AppState>,
        terminalManager: TerminalManager,
        from terminalID: PaneSlotID,
        direction: NavigationDirection
    ) {
        for repoIdx in appState.wrappedValue.repos.indices {
            for wtIdx in appState.wrappedValue.repos[repoIdx].worktrees.indices {
                let wt = appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                guard wt.splitTree.containsLeaf(terminalID) else { continue }
                guard let nextID = wt.splitTree.spatialNeighbor(
                    of: terminalID,
                    direction: direction.asSpatial
                ) else {
                    // No spatial neighbor — no-op, focus stays where it is.
                    return
                }
                // Zoom preservation: Ghostty 1.3 `split-preserve-zoom = navigation` opt-in.
                if wt.splitTree.zoomed != nil {
                    let newTree = terminalManager.splitPreserveZoomOnNavigation
                        ? wt.splitTree.withZoom(nextID)
                        : wt.splitTree.withZoom(nil)
                    appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].splitTree = newTree
                }
                appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].focusedPaneSlotID = nextID
                terminalManager.setFocus(nextID)
                return
            }
        }
    }

    /// `Previous Pane` / `Next Pane` cycle through the worktree's leaves in
    /// DFS order regardless of the spatial layout — that's what the menu
    /// items promise. Kept separate from the spatial `navigatePane` so
    /// TERM-7.3 (arrow-key spatial nav) doesn't silently change the
    /// round-robin semantics shared by fixed and host tab-action chords.
    @MainActor
    static func navigatePaneInTreeOrder(
        appState: Binding<AppState>,
        terminalManager: TerminalManager,
        from terminalID: PaneSlotID,
        forward: Bool
    ) {
        for repoIdx in appState.wrappedValue.repos.indices {
            for wtIdx in appState.wrappedValue.repos[repoIdx].worktrees.indices {
                let wt = appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                let leaves = wt.splitTree.allLeaves
                guard let currentIdx = leaves.firstIndex(of: terminalID) else { continue }
                guard leaves.count > 1 else { return }
                let nextIdx = forward
                    ? (currentIdx + 1) % leaves.count
                    : (currentIdx - 1 + leaves.count) % leaves.count
                let nextID = leaves[nextIdx]
                if wt.splitTree.zoomed != nil {
                    let newTree = terminalManager.splitPreserveZoomOnNavigation
                        ? wt.splitTree.withZoom(nextID)
                        : wt.splitTree.withZoom(nil)
                    appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].splitTree = newTree
                }
                appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].focusedPaneSlotID = nextID
                terminalManager.setFocus(nextID)
                return
            }
        }
    }

    @MainActor
    fileprivate static func toggleZoom(appState: Binding<AppState>, on terminalID: PaneSlotID) {
        mutateWorktreeContaining(appState: appState, leaf: terminalID) { wt in
            var copy = wt
            copy.splitTree = wt.splitTree.togglingZoom(at: terminalID)
            return copy
        }
    }

    @MainActor
    fileprivate static func equalizeSplits(
        appState: Binding<AppState>,
        around terminalID: PaneSlotID,
        preserveZoom: Bool = false
    ) {
        mutateWorktreeContaining(appState: appState, leaf: terminalID) { wt in
            var copy = wt
            copy.splitTree = wt.splitTree.equalizing()
            if preserveZoom, let zoomed = wt.splitTree.zoomed {
                copy.splitTree = copy.splitTree.withZoom(zoomed)
            }
            return copy
        }
    }

    @MainActor
    @discardableResult
    fileprivate static func resizeSplit(
        appState: Binding<AppState>,
        target: PaneSlotID,
        direction: ResizeDirection,
        pixels: UInt16,
        ancestorBounds: CGRect? = nil,
        preserveZoom: Bool = false
    ) -> Bool {
        // MVP: use the key window's content-area bounds as a proxy for the
        // ancestor split bounds. Accurate for single-split layouts; for nested
        // splits the delta will be slightly off. A follow-up can capture
        // per-split bounds via SwiftUI preference keys.
        // TODO: plumb per-split GeometryReader bounds for multi-level accuracy.
        let bounds = ancestorBounds
            ?? NSApp.keyWindow?.contentView?.bounds
            ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        var didResize = false
        mutateWorktreeContaining(appState: appState, leaf: target) { wt in
            var copy = wt
            do {
                copy.splitTree = try wt.splitTree.resizing(
                    target: target,
                    direction: direction,
                    pixels: pixels,
                    ancestorBounds: bounds
                )
                if preserveZoom, let zoomed = wt.splitTree.zoomed {
                    copy.splitTree = copy.splitTree.withZoom(zoomed)
                }
                didResize = true
            } catch {
                // No matching orientation ancestor — silent no-op, matches Ghostty.
            }
            return copy
        }
        return didResize
    }

    /// Find the worktree that owns `leaf` and apply `transform` to it.
    /// Idempotent and safe for callers that don't know which worktree owns a pane.
    @MainActor
    private static func mutateWorktreeContaining(
        appState: Binding<AppState>,
        leaf: PaneSlotID,
        transform: (WorktreeEntry) -> WorktreeEntry
    ) {
        for repoIdx in appState.wrappedValue.repos.indices {
            for wtIdx in appState.wrappedValue.repos[repoIdx].worktrees.indices {
                if appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].splitTree.containsLeaf(leaf) {
                    let wt = appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                    appState.wrappedValue.repos[repoIdx].worktrees[wtIdx] = transform(wt)
                    return
                }
            }
        }
    }

    /// Shared close-pane implementation used by Cmd+W and libghostty's
    /// `close_surface_cb` (shell exit). Removes the pane from its worktree's
    /// split tree, destroys the surface, promotes focus to a sibling, and
    /// transitions the worktree to `.closed` when the last pane goes away.
    /// Idempotent: no-op if the terminal isn't in any tree.
    ///
    /// `userInitiated`: distinguishes Cmd+W / CLI / context-menu close
    /// (`true`) from libghostty's async `close_surface_cb` (`false`).
    /// `PhantomPaneClosePolicy.shouldRemoveFromTree` uses this to let
    /// user-initiated closes clean up phantom leaves (surface creation
    /// failed, `TERM-5.8`) while keeping the `TERM-5.7` Stop-cascade guard
    /// for libghostty-initiated callbacks.
    @MainActor
    fileprivate static func closePane(
        appState: Binding<AppState>,
        terminalManager: TerminalManager,
        targetID: PaneSlotID,
        userInitiated: Bool = false,
        activateReplacement: Bool = true
    ) {
        for repoIdx in appState.wrappedValue.repos.indices {
            for wtIdx in appState.wrappedValue.repos[repoIdx].worktrees.indices {
                let candidate = appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                guard candidate.splitTree.containsLeaf(targetID) else { continue }

                // TERM-5.7 (Stop cascade) vs TERM-5.8 (phantom leaf).
                // `handle == nil` can mean either:
                //   * destroySurface just ran during Stop and the late
                //     close_surface_cb arrived with splitTree preserved
                //     per TERM-1.2 → leave it alone, or
                //   * the surface never instantiated at all (libghostty
                //     OOM, TERM-5.5) → the user's Cmd+W / CLI close is
                //     their ONLY way to remove the phantom leaf.
                // The caller tells us which by `userInitiated`.
                guard PhantomPaneClosePolicy.shouldRemoveFromTree(
                    userInitiated: userInitiated,
                    handleExists: terminalManager.handle(for: targetID) != nil
                ) else { continue }

                _ = appState.wrappedValue.repos[repoIdx]
                    .worktrees[wtIdx].ensurePrimaryPane()
                let wt = appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                terminalManager.destroySurface(terminalID: targetID)
                let newTree = wt.splitTree.removing(targetID)
                appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].splitTree = newTree
                // Drop any lingering per-pane attention so a destroyed
                // terminal doesn't leak a badge entry into the model.
                appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                    .paneAttention[targetID] = nil
                appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                    .clearPaneSession(for: targetID)

                if newTree.root == nil {
                    appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].state = .closed
                    appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].focusedPaneSlotID = nil
                } else {
                    // TERM-5.6: only promote focus when the CLOSED pane
                    // was the focused one. Pre-fix, this branch always
                    // reassigned focus to `newTree.allLeaves.first`,
                    // silently jumping focus away from whatever pane the
                    // user was typing in if they closed a different pane.
                    let previousFocus = wt.focusedPaneSlotID
                    let newFocus = SplitTree.focusAfterRemoving(
                        currentFocus: previousFocus,
                        removed: targetID,
                        remainingTree: newTree
                    )
                    appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].focusedPaneSlotID = newFocus
                    // Only push focus to libghostty if it actually
                    // changed — otherwise we're re-raising the same
                    // surface for no reason.
                    if activateReplacement,
                       let newFocus,
                       newFocus != previousFocus {
                        terminalManager.setFocus(newFocus)
                    }
                }
                // Closing a non-primary pane preserves startup ownership.
                // Closing the primary elects and persists a survivor.
                let primaryPane = appState.wrappedValue.repos[repoIdx]
                    .worktrees[wtIdx].ensurePrimaryPane()
                if let primaryPane {
                    terminalManager.markFirstPane(primaryPane)
                }
                return
            }
        }
    }

    /// Called on the first `onShellReady` signal for a pane. Reads the
    /// user's default-command preferences from UserDefaults, consults the
    /// pure decision function in GrafttyKit, and — if the decision is
    /// `.type(command)` — types the command into the pane via
    /// `SurfaceHandle.typeText` followed by `\r` to trigger execution.
    @MainActor
    fileprivate static func maybeRunDefaultCommand(
        terminalManager: TerminalManager,
        terminalID: PaneSlotID
    ) {
        let defaults = UserDefaults.standard
        let command = defaults.string(forKey: SettingsKeys.defaultCommand) ?? ""
        // `@AppStorage` defaults apply only in the SwiftUI view; when
        // read directly from UserDefaults the key returns nil on
        // first run. Treat nil as `true` to match the SettingsView default.
        let firstPaneOnly = defaults.object(forKey: "defaultCommandFirstPaneOnly") as? Bool ?? true

        let decision = defaultCommandDecision(
            defaultCommand: command,
            firstPaneOnly: firstPaneOnly,
            isFirstPane: terminalManager.isFirstPane(terminalID),
            wasRehydrated: terminalManager.wasRehydrated(terminalID),
            hasExplicitInitialInput: terminalManager.consumeExplicitInitialInputMarker(terminalID)
        )

        switch decision {
        case .skip:
            return
        case .type(let trimmedCommand):
            // The default-command auto-injection runs once when a fresh
            // pane's shell becomes ready — programmatic input, not a
            // user keystroke. IOS-12.1's silent gate stays closed.
            terminalManager.handle(for: terminalID)?.typeText(trimmedCommand + "\r", claimEngagement: false)
        }
    }

    // MARK: - Focused-pane helpers for menu actions

    /// The terminal currently holding focus in the selected worktree.
    private var focusedPaneSlotID: PaneSlotID? {
        guard let path = appState.selectedWorktreePath else { return nil }
        for repo in appState.repos {
            for wt in repo.worktrees where wt.path == path && wt.state == .running {
                return wt.firstPane
            }
        }
        return nil
    }

    private func handleSplit(_ split: PaneSplit) {
        if routeFocusedHostManagedPaneCommand(.split(split)) { return }
        guard let id = focusedPaneSlotID else { return }
        _ = Self.splitPane(appState: $appState, terminalManager: terminalManager, targetID: id, split: split)
    }

    private func handleNavigate(_ dir: NavigationDirection) {
        if routeFocusedHostManagedPaneCommand(.focus(dir)) { return }
        guard let id = focusedPaneSlotID else { return }
        Self.navigatePane(appState: $appState, terminalManager: terminalManager, from: id, direction: dir)
    }

    private func handleNavigateTreeOrder(forward: Bool) {
        if routeFocusedHostManagedPaneCommand(
            .focusOrder(forward: forward)
        ) {
            return
        }
        guard let id = focusedPaneSlotID else { return }
        Self.navigatePaneInTreeOrder(appState: $appState, terminalManager: terminalManager, from: id, forward: forward)
    }

    private func handleToggleZoom() {
        if routeFocusedHostManagedPaneCommand(.toggleZoom) { return }
        guard let id = focusedPaneSlotID else { return }
        Self.toggleZoom(appState: $appState, on: id)
    }

    private func handleEqualizeSplits() {
        if routeFocusedHostManagedPaneCommand(.equalize) { return }
        guard let id = focusedPaneSlotID else { return }
        Self.equalizeSplits(appState: $appState, around: id)
    }

    private func handleClosePane() {
        if routeFocusedHostManagedPaneCommand(.close) { return }
        guard let id = focusedPaneSlotID else { return }
        Self.closePane(
            appState: $appState,
            terminalManager: terminalManager,
            targetID: id,
            userInitiated: true
        )
    }

    private func routeFocusedHostManagedPaneCommand(
        _ command: HostManagedPaneCommand
    ) -> Bool {
        guard let terminalID = terminalManager.focusedTerminalID else {
            return false
        }
        return terminalManager.routeHostManagedPaneCommand(
            command,
            for: terminalID
        )
    }

    private func handleReloadConfig() {
        terminalManager.reloadGhosttyConfig()
    }

    private func handleOpenGhosttySettings() {
        Self.openGhosttySettings()
    }

    private func handleGhosttyCommand(_ command: GhosttyCommandRegistry.Entry) {
        switch command.kind {
        case .split(let direction):
            handleSplit(paneSplit(for: direction))
        case .closePane:
            handleClosePane()
        case .focusPane(let direction):
            handleNavigate(navigationDirection(for: direction))
        case .focusPaneByOrder(let forward):
            handleNavigateTreeOrder(forward: forward)
        case .unsupported:
            handleUnsupportedGhosttyAction(command.action)
        }
    }

    private func handleUnsupportedGhosttyAction(_ action: GhosttyAction) {
        switch action {
        case .toggleSplitZoom:
            handleToggleZoom()
        case .equalizeSplits:
            handleEqualizeSplits()
        case .reloadConfig:
            handleReloadConfig()
        case .openConfig:
            handleOpenGhosttySettings()
        default:
            break
        }
    }

    private func paneSplit(for direction: GhosttySplitDirection) -> PaneSplit {
        switch direction {
        case .left:
            return .left
        case .right:
            return .right
        case .up:
            return .up
        case .down:
            return .down
        }
    }

    private func navigationDirection(for direction: GhosttyPaneFocusDirection) -> NavigationDirection {
        switch direction {
        case .left:
            return .left
        case .right:
            return .right
        case .up:
            return .up
        case .down:
            return .down
        }
    }

    /// Confirm with the user, then destroy every running worktree's panes
    /// (which fires `zmx kill --force` per session via `destroySurface` →
    /// `killZmxSession`) and mark those worktrees `.closed` via
    /// `prepareForStop` — mirroring the per-worktree Stop flow (`TERM-1.2` /
    /// `STATE-2.11`) but applied in bulk. Re-opening any worktree
    /// afterwards spawns fresh zmx daemons. `ZMX-8.1`.
    private func restartZMXWithConfirmation() {
        struct RunningEntry {
            let repoIdx: Int
            let worktreeIdx: Int
            let terminalIDs: [PaneSlotID]
        }
        var running: [RunningEntry] = []
        var totalPanes = 0
        for (repoIdx, repo) in appState.repos.enumerated() {
            for (wtIdx, wt) in repo.worktrees.enumerated() where wt.state == .running {
                let leaves = wt.splitTree.allLeaves
                running.append(RunningEntry(repoIdx: repoIdx, worktreeIdx: wtIdx, terminalIDs: leaves))
                totalPanes += leaves.count
            }
        }

        let alert = NSAlert()
        alert.messageText = "Restart ZMX?"
        alert.informativeText = ZmxRestartConfirmation.informativeText(
            paneCount: totalPanes,
            worktreeCount: running.count
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Restart ZMX")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        for entry in running {
            terminalManager.destroySurfaces(terminalIDs: entry.terminalIDs)
            appState.repos[entry.repoIdx].worktrees[entry.worktreeIdx].prepareForStop()
        }
    }

    /// Resolve the user's Ghostty config file path, create it if missing,
    /// and hand it to `NSWorkspace.open` so it launches in the user's
    /// default editor for that file type — same behavior as Ghostty.app's
    /// own "Open Configuration" menu. `TERM-9.2`.
    ///
    /// Static so the `open_config` keybind callback in `startup()` (which
    /// can't capture `self` cleanly) can share the implementation with
    /// the menu button's instance handler.
    fileprivate static func openGhosttySettings() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = GhosttyConfigLocator.resolveURL(home: home)
        do {
            try GhosttyConfigLocator.ensureExists(at: url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could Not Create Ghostty Config"
            alert.informativeText = "Failed to create \(url.path): \(error.localizedDescription)"
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - View builder for bridge-shortcutted menu buttons

    /// Wraps a menu button so its keyboard shortcut is derived from the
    /// keybind bridge at runtime, not hardcoded. If the action has no
    /// configured binding (or the key can't be translated to a
    /// `KeyboardShortcut`), the button renders without a shortcut hint.
    @MainActor
    @ViewBuilder
    private func bridgedButton(
        _ command: GhosttyCommandRegistry.Entry,
        shortcutsByAction: [GhosttyAction: KeyboardShortcut],
        onTap: @escaping () -> Void
    ) -> some View {
        Group {
            if let shortcut = shortcutsByAction[command.action] {
                Button(command.label, action: onTap).keyboardShortcut(shortcut)
            } else {
                Button(command.label, action: onTap)
            }
        }
    }

    static func installAgentHookAssets() {
        do {
            _ = try AgentHookInstaller(
                rootDirectory: AgentHookInstaller.rootDirectory(),
                grafttyCLIPath: agentHookCLIPath()
            ).install()
        } catch {
            NSLog("[Graftty] Agent hook asset install failed: %@", String(describing: error))
        }
    }

    private static func agentHookCLIPath() -> String {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/graftty")
            .path
        if FileManager.default.fileExists(atPath: bundled) {
            return bundled
        }
        return "graftty"
    }

    private func installCLI() {
        let bundleCLI = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/graftty")
        let symlink = "/usr/local/bin/graftty"

        switch CLIInstaller.plan(source: bundleCLI.path, destination: symlink) {
        case .directSymlink(let source, let destination):
            runDirectSymlink(source: source, destination: destination)
        case .showSudoCommand(let command, let destination):
            showSudoInstallAlert(command: command, destination: destination)
        case .sourceMissing(let source):
            // Dev build: `swift run Graftty` skips bundle.sh so the
            // Helpers dir doesn't exist. Surface it instead of
            // creating a dangling symlink. `ATTN-1.1`.
            let alert = NSAlert()
            alert.messageText = "CLI Binary Not Found"
            alert.informativeText = """
                The bundled CLI was not found at \(source). \
                If you are running a development build, run \
                `scripts/bundle.sh` first, then install from the bundled app.
                """
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    private func runDirectSymlink(source: String, destination: String) {
        let alert = NSAlert()
        alert.messageText = "Install CLI Tool"
        alert.informativeText = "Create a symlink at \(destination) pointing to the Graftty CLI?"
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try? FileManager.default.removeItem(atPath: destination)
            try FileManager.default.createSymbolicLink(
                atPath: destination,
                withDestinationPath: source
            )
        } catch {
            let errorAlert = NSAlert()
            errorAlert.messageText = "Installation Failed"
            errorAlert.informativeText = error.localizedDescription
            errorAlert.runModal()
        }
    }

    /// Parent directory isn't writable (e.g. /usr/local/bin owned by root).
    /// Surface a sudo command the user can copy and run in Terminal.
    private func showSudoInstallAlert(command: String, destination: String) {
        let alert = NSAlert()
        alert.messageText = "Administrator Access Required"
        alert.informativeText = "Installing to \(destination) requires sudo. Copy this command and run it in Terminal:"
        alert.addButton(withTitle: "Copy Command")
        alert.addButton(withTitle: "Cancel")

        // Attach a selectable, read-only text field so the user can also
        // eyeball / manually select the exact command.
        let textField = NSTextField(string: command)
        textField.isEditable = false
        textField.isSelectable = true
        textField.drawsBackground = true
        textField.backgroundColor = .textBackgroundColor
        textField.frame = NSRect(x: 0, y: 0, width: 440, height: 44)
        textField.isBordered = true
        textField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        alert.accessoryView = textField

        if alert.runModal() == .alertFirstButtonReturn {
            Pasteboard.copy(command)
        }
    }
}

 extension PaneControlRequest {
    fileprivate
    var primaryTarget: String? {
        switch self {
        case .split(let target, _), .close(let target),
             .equalize(let target), .resize(let target, _, _, _):
            return target
        case .swap(let source, _):
            return source
        }
    }
}

 extension WorktreeManagementRequest {
    fileprivate
    var targetsRelayedResource: Bool {
        switch self {
        case .hostPresentation, .listRepositories:
            return false
        case .create(let repositoryID, _, _, _),
             .pullDefaultBranch(let repositoryID):
            return repositoryID.hasPrefix("relay-repository-")
        case .open(let worktreeID),
             .delete(let worktreeID, _),
             .acknowledge(let worktreeID, _):
            return worktreeID.hasPrefix("relay-worktree-")
        }
    }
}

@MainActor
final class WorktreeMonitorBridge: WorktreeMonitorDelegate {
    typealias DiscoverWorktrees = @Sendable (
        _ repo: RepoEntry
    ) async throws -> [DiscoveredWorktree]

    nonisolated static let defaultDiscoverWorktrees: DiscoverWorktrees = { repo in
        try await WorktreeDiscovery.discover(repo: repo)
    }

    /// Tests substitute an immediate-fire recorder so a CI MainActor
    /// starvation episode can't push the wall-clock follow-up sleep
    /// past the test's `waitUntil` window.
    typealias FollowUpScheduler = @Sendable (
        _ delay: Duration,
        _ work: @escaping @Sendable () async -> Void
    ) -> Void

    nonisolated static let defaultFollowUpScheduler: FollowUpScheduler = { delay, work in
        Task.detached {
            try? await Task.sleep(for: delay)
            if Task.isCancelled { return }
            await work()
        }
    }

    let appState: Binding<AppState>
    let statsStore: WorktreeStatsStore
    let prStatusStore: PRStatusStore
    let remoteBranchStore: RemoteBranchStore
    private let discoverWorktrees: DiscoverWorktrees
    private let originRefPRFollowUpScheduler: FollowUpScheduler

    init(
        appState: Binding<AppState>,
        statsStore: WorktreeStatsStore,
        prStatusStore: PRStatusStore,
        remoteBranchStore: RemoteBranchStore,
        discoverWorktrees: @escaping DiscoverWorktrees = WorktreeMonitorBridge.defaultDiscoverWorktrees,
        originRefPRFollowUpScheduler: @escaping FollowUpScheduler = WorktreeMonitorBridge.defaultFollowUpScheduler
    ) {
        self.appState = appState
        self.statsStore = statsStore
        self.prStatusStore = prStatusStore
        self.remoteBranchStore = remoteBranchStore
        self.discoverWorktrees = discoverWorktrees
        self.originRefPRFollowUpScheduler = originRefPRFollowUpScheduler
    }

    /// Called when `.git/worktrees/` changes (new worktree added, existing
    /// one removed externally). After reconciling appState, refresh stats
    /// for every non-stale worktree in the repo — new worktrees need their
    /// initial stats, removed ones will be marked stale (and stats cleared
    /// by `worktreeMonitorDidDetectDeletion`).
    nonisolated func worktreeMonitorDidDetectChange(_ monitor: WorktreeMonitor, repoPath: String) {
        let binding = appState
        let store = statsStore
        let prStore = prStatusStore
        let discover = discoverWorktrees
        // `git worktree list --porcelain` is a subprocess wait. Awaiting the
        // now-async `GitWorktreeDiscovery.discover` yields the main actor
        // during the wait so ghostty keystrokes aren't delayed (prior
        // manifestation: intermittent ~1s input/render hangs under fs/
        // indexing pressure).
        Task { @MainActor in
            guard let repo = binding.wrappedValue.repos.first(where: { $0.path == repoPath }) else { return }
            let discovered: [DiscoveredWorktree]
            do {
                discovered = try await discover(repo)
            } catch {
                NSLog("[Graftty] worktreeMonitorDidDetectChange: discover failed for %@: %@",
                      repoPath, String(describing: error))
                return
            }
            guard let repoIdx = binding.wrappedValue.repos.firstIndex(where: { $0.path == repoPath }) else { return }

            let previousWorktrees = binding.wrappedValue.repos[repoIdx].worktrees
            let result = WorktreeReconciler.reconcile(
                existing: previousWorktrees,
                discovered: discovered
            )
            binding.wrappedValue.repos[repoIdx].worktrees = result.merged
            if result.merged != previousWorktrees {
                // This delegate remains active with no visible window; the
                // WindowGroup's `.onChange` observer may not exist then.
                GrafttyApp.persistAppState(binding.wrappedValue)
            }

            // GIT-3.13 / GIT-3.15: clear cached stats/PR AND drop the
            // worktree's watchers on every stale transition, matching
            // the FSEvents-deletion path. Zombie watchers bound to
            // the reaped inode would otherwise block same-path
            // resurrection from re-arming cleanly.
            for wt in result.newlyStale {
                store.clear(worktreePath: wt.path)
                prStore.clear(worktreePath: wt.path)
                monitor.stopWatchingWorktree(wt.path)
            }

            // watchWorktreePath / watchHeadRef / watchWorktreeContents are
            // idempotent, so registering for the whole repo is cheap; this
            // is how newly-discovered worktrees (external `git worktree
            // add`) start getting HEAD + working-tree tracking without an
            // app restart. Includes resurrected entries.
            for wt in binding.wrappedValue.repos[repoIdx].worktrees where wt.state.hasOnDiskWorktree {
                monitor.watchWorktreePath(wt.path)
                monitor.watchHeadRef(worktreePath: wt.path, repoPath: repoPath)
                monitor.watchWorktreeContents(worktreePath: wt.path)
            }

            // Existing worktrees' stats are driven by their own HEAD and
            // origin-ref callbacks plus the polling fallback, so a
            // `.git/worktrees/` directory tick only needs to seed stats
            // for new entries.
            for wt in result.newlyAdded where wt.state == .running {
                store.refresh(worktreePath: wt.path, repoPath: repoPath, branch: wt.branch)
            }
        }
    }

    nonisolated func worktreeMonitorDidDetectDeletion(_ monitor: WorktreeMonitor, worktreePath: String) {
        let binding = appState
        let store = statsStore
        let prStore = prStatusStore
        let remoteBranchStore = remoteBranchStore
        Task { @MainActor in
            let previousState = binding.wrappedValue
            // LAYOUT-4.7: before marking the worktree stale, see if the
            // owning repo has a bookmark and whether it now resolves to
            // a different path. If it does, run the relocate cascade —
            // this catches the "user renamed the repo folder in Finder
            // while Graftty was running" case. FSEvents delivered a
            // deletion on the old path; the bookmark points at the new
            // one. Running the cascade here means the user never sees
            // the yellow stale state for a renamed repo.
            if let (repoIdx, _) = binding.wrappedValue.indices(forWorktreePath: worktreePath),
               let bookmark = binding.wrappedValue.repos[repoIdx].bookmark {
                do {
                    let resolved = try RepoBookmark.resolve(bookmark)
                    if resolved.url.path != binding.wrappedValue.repos[repoIdx].path {
                        await GrafttyApp.relocateRepo(
                            appState: binding,
                            worktreeMonitor: monitor,
                            statsStore: store,
                            prStatusStore: prStore,
                            remoteBranchStore: remoteBranchStore,
                            repoIdx: repoIdx,
                            newURL: resolved.url,
                            isStale: resolved.isStale
                        )
                        // Relocate ran — worktrees either moved with
                        // it or went stale via RepoRelocator
                        // decisions. Skip the existing unconditional
                        // stale path below so we don't double-clear
                        // caches or re-stop already-stopped watchers.
                        return
                    }
                } catch {
                    NSLog("[Graftty] worktreeMonitorDidDetectDeletion: bookmark resolve failed: %@",
                          String(describing: error))
                    // fall through to the existing stale path
                }
            }

            if let indices = binding.wrappedValue.indices(forWorktreePath: worktreePath) {
                let repoID = binding.wrappedValue.repos[indices.repo].id
                if binding.wrappedValue.repos[indices.repo].worktrees[indices.worktree].state != .stale {
                    binding.wrappedValue.repos[indices.repo].worktrees[indices.worktree].markStale()
                } else if binding.wrappedValue.repos[indices.repo]
                    .worktrees[indices.worktree].staleSince == nil {
                    binding.wrappedValue.repos[indices.repo]
                        .worktrees[indices.worktree].markStale()
                }
                binding.wrappedValue.moveStaleWorktreesToBottom(inRepoID: repoID)
            }
            store.clear(worktreePath: worktreePath)
            prStore.clear(worktreePath: worktreePath)
            // `GIT-3.15`: drop the path / head / content watchers for
            // the deleted worktree so a subsequent `git worktree add`
            // at the same path (detected by the repo-level watcher)
            // re-arms fresh fds on the new inode, rather than the
            // reconciler's "idempotent" re-register skipping over
            // zombie fds bound to the reaped inode.
            monitor.stopWatchingWorktree(worktreePath)
            if binding.wrappedValue != previousState {
                GrafttyApp.persistAppState(binding.wrappedValue)
            }
        }
    }

    /// Fires when any remote-tracking ref under
    /// `<repoPath>/.git/logs/refs/remotes/origin/` moves — i.e. a
    /// `git push` or `git fetch` landed. Covers the `gh pr create`
    /// flow, which pushes then creates the PR via API without touching
    /// local HEAD. Refreshes divergence for the repo's running
    /// worktrees immediately, then drives the remote-branch and PR
    /// refresh. The polling tick remains a fallback for a coalesced or
    /// missed FSEvent.
    nonisolated func worktreeMonitorDidDetectOriginRefChange(_ monitor: WorktreeMonitor, repoPath: String) {
        let binding = appState
        let store = statsStore
        let remoteBranchStore = remoteBranchStore
        Task { @MainActor in
            guard let repo = binding.wrappedValue.repos.first(where: {
                $0.path == repoPath && $0.isGitTracked
            }) else { return }
            // Graftty's own periodic fetch also moves origin refs. Limit
            // this repo-wide signal to running rows so it doesn't turn
            // into recurring work proportional to closed history.
            for wt in repo.worktrees where wt.state == .running {
                store.refresh(worktreePath: wt.path, repoPath: repoPath, branch: wt.branch)
            }
            remoteBranchStore.refresh(repoPath: repoPath) { [weak self] in
                self?.refreshPushedPRs(repoPath: repoPath)
                self?.scheduleOriginRefPRFollowUps(repoPath: repoPath)
            }
        }
    }

    private func refreshPushedPRs(repoPath: String) {
        guard let repo = appState.wrappedValue.repos.first(where: { $0.path == repoPath }) else { return }
        for wt in repo.worktrees where wt.state.hasOnDiskWorktree {
            guard remoteBranchStore.hasRemote(repoPath: repoPath, branch: wt.branch) else { continue }
            prStatusStore.refresh(worktreePath: wt.path, repoPath: repoPath, branch: wt.branch)
        }
    }

    private func scheduleOriginRefPRFollowUps(repoPath: String) {
        // Detached so a starved MainActor (heavy app startup, CI
        // test parallelism) can't push the sleep out by many
        // seconds; only the eventual `refreshPushedPRs` hops back.
        let delays: [Duration] = [.seconds(1), .seconds(5)]
        for delay in delays {
            originRefPRFollowUpScheduler(delay) { [weak self] in
                await self?.refreshPushedPRs(repoPath: repoPath)
            }
        }
    }

    nonisolated func worktreeMonitorDidDetectBranchChange(_ monitor: WorktreeMonitor, worktreePath: String) {
        let binding = appState
        let store = statsStore
        let prStore = prStatusStore
        let remoteBranchStore = remoteBranchStore
        let discover = discoverWorktrees
        // Branch changes fire in bursts (rebase, interactive checkout), so
        // `GitWorktreeDiscovery.discover`'s subprocess wait must yield the
        // main actor — the async version does that naturally. Scope the
        // discover call to the owning repo only, not every tracked repo.
        Task { @MainActor in
            guard let repo = binding.wrappedValue.repos.first(where: { repo in
                repo.isGitTracked && repo.worktrees.contains(where: { $0.path == worktreePath })
            }) else { return }
            let repoPath = repo.path
            let discovered: [DiscoveredWorktree]
            do {
                discovered = try await discover(repo)
            } catch {
                NSLog("[Graftty] worktreeMonitorDidDetectBranchChange: discover failed for %@: %@",
                      repoPath, String(describing: error))
                return
            }
            guard let match = discovered.first(where: { $0.path == worktreePath }) else { return }
            guard let repoIdx = binding.wrappedValue.repos.firstIndex(where: { $0.path == repoPath }),
                  let wtIdx = binding.wrappedValue.repos[repoIdx].worktrees.firstIndex(where: { $0.path == worktreePath }) else { return }
            binding.wrappedValue.repos[repoIdx].worktrees[wtIdx].branch = match.branch
            if binding.wrappedValue.repos[repoIdx].worktrees[wtIdx].state.hasOnDiskWorktree {
                store.refresh(worktreePath: worktreePath, repoPath: repoPath, branch: match.branch)
            }
            prStore.clear(worktreePath: worktreePath)
            remoteBranchStore.refresh(repoPath: repoPath) {
                guard let repo = binding.wrappedValue.repos.first(where: { $0.path == repoPath }),
                      let wt = repo.worktrees.first(where: {
                          $0.path == worktreePath && $0.state.hasOnDiskWorktree
                      })
                else { return }
                prStore.refresh(worktreePath: worktreePath, repoPath: repoPath, branch: wt.branch)
            }
        }
    }
}

/// Convert the Mac-side `SplitTree.Node` into the wire-format
/// `PaneLayoutNode`. Leaves carry the ZMX session name, the pane's
/// current title (or the empty string if libghostty hasn't emitted
/// one yet), and the pane-scoped attention text from the worktree's
/// `paneAttention`.
@MainActor
private func paneLayoutNode(
    from node: SplitTree.Node,
    paneSessions: [PaneSlotID: PaneSessionID],
    titles: [PaneSlotID: String],
    paneAttention: [PaneSlotID: Attention],
    liveness: [String: AgentLiveness]
) -> PaneLayoutNode {
    switch node {
    case .leaf(let id):
        let sessionName = paneSessions[id].map(ZmxLauncher.sessionName(for:))
        return .leaf(
            sessionName: sessionName ?? "",
            title: titles[id] ?? "",
            attentionText: paneAttention[id]?.text,
            isBusy: AgentLivenessMerge.isPaneBusy(
                sessionName: sessionName,
                liveness: liveness),
            attentionSource: paneAttention[id]?.source,
            attentionTimestamp: paneAttention[id]?.timestamp
        )
    case .split(let s):
        return .split(
            direction: s.direction == .horizontal ? .horizontal : .vertical,
            ratio: s.ratio,
            left: paneLayoutNode(
                from: s.left,
                paneSessions: paneSessions,
                titles: titles,
                paneAttention: paneAttention,
                liveness: liveness
            ),
            right: paneLayoutNode(
                from: s.right,
                paneSessions: paneSessions,
                titles: titles,
                paneAttention: paneAttention,
                liveness: liveness
            )
        )
    }
}

extension WorktreeWireState {
    /// Exhaustive bridge from the persistence-side `WorktreeState` (in
    /// GrafttyKit, whose `encode(to:)` coerces `.creating` and
    /// `.deleting` to `.closed`) to the wire enum. A `switch` rather
    /// than `rawValue` round-trip so a future `WorktreeState` case is a
    /// compile error here.
    init(_ state: WorktreeState) {
        switch state {
        case .closed: self = .closed
        case .running: self = .running
        case .stale: self = .stale
        case .creating: self = .creating
        case .deleting: self = .deleting
        }
    }
}
