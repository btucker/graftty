import Foundation
import NIO
import NIOHTTP1
import NIOSSL
import NIOWebSocket
import GrafttyProtocol

internal final class WebDisplayOwnershipBroadcaster: @unchecked Sendable {
    internal final class Registration: @unchecked Sendable {
        private let onCancel: () -> Void
        private let lock = NSLock()
        private var cancelled = false

        init(onCancel: @escaping () -> Void) {
            self.onCancel = onCancel
        }

        func cancel() {
            lock.lock()
            if cancelled {
                lock.unlock()
                return
            }
            cancelled = true
            lock.unlock()
            onCancel()
        }

        deinit {
            cancel()
        }
    }

    private struct Subscriber {
        let clientID: DisplayClientID
        let send: @Sendable (DisplayOwnershipSnapshot) -> Void
    }

    private let lock = NSLock()
    private var subscribers: [String: [UUID: Subscriber]] = [:]
    /// Held for the broadcaster's lifetime so it stays subscribed to the
    /// shared ownership store; cancels (unsubscribes) when this broadcaster
    /// is torn down.
    private var storeObserverToken: SessionDisplayOwnershipStore.ObserverToken?

    /// When `store` is provided, the broadcaster subscribes to every owner
    /// mutation on it and re-broadcasts the snapshot to connected clients.
    /// This is what propagates *Mac-host* ownership changes — those mutate the
    /// shared store directly (via `HostManagedZmxOwnership`) and never pass
    /// through this bridge's own broadcast calls, so without this subscription
    /// web/iOS followers never learn the Mac took or released the display.
    init(store: SessionDisplayOwnershipStore? = nil) {
        if let store {
            storeObserverToken = store.addObserver { [weak self] snapshot in
                self?.broadcast(snapshot)
            }
        }
    }

    func register(
        sessionName: String,
        clientID: DisplayClientID,
        send: @escaping @Sendable (DisplayOwnershipSnapshot) -> Void
    ) -> Registration {
        let id = UUID()
        lock.lock()
        var sessionSubscribers = subscribers[sessionName] ?? [:]
        sessionSubscribers[id] = Subscriber(clientID: clientID, send: send)
        subscribers[sessionName] = sessionSubscribers
        lock.unlock()

        return Registration { [weak self] in
            self?.unregister(sessionName: sessionName, id: id)
        }
    }

    func broadcast(_ snapshot: DisplayOwnershipSnapshot) {
        lock.lock()
        let sends = subscribers[snapshot.sessionName]?.values.map(\.send) ?? []
        lock.unlock()

        for send in sends {
            send(snapshot)
        }
    }

    private func unregister(sessionName: String, id: UUID) {
        lock.lock()
        if var sessionSubscribers = subscribers[sessionName] {
            sessionSubscribers.removeValue(forKey: id)
            subscribers[sessionName] = sessionSubscribers.isEmpty ? nil : sessionSubscribers
        }
        lock.unlock()
    }
}

internal final class WebSocketBridgeCoordinator: @unchecked Sendable {
    private let sessionName: String
    private let clientID: DisplayClientID
    private let defaultKind: DisplayClientKind
    private let ownershipStore: SessionDisplayOwnershipStore
    private let broadcaster: WebDisplayOwnershipBroadcaster
    private let sendText: @Sendable (String) -> Void
    private let resize: @Sendable (UInt16, UInt16) -> Void
    private let write: @Sendable (Data) -> Void
    private let lock = NSLock()

    private var registration: WebDisplayOwnershipBroadcaster.Registration?
    private var boundProtocolClientID: DisplayClientID?
    private var attachedKind: DisplayClientKind?
    private var attached = false
    private var detached = false
    private var lastAcceptedOwnerGrid: DisplayGrid?

    init(
        sessionName: String,
        clientID: DisplayClientID,
        defaultKind: DisplayClientKind,
        ownershipStore: SessionDisplayOwnershipStore,
        broadcaster: WebDisplayOwnershipBroadcaster,
        sendText: @escaping @Sendable (String) -> Void,
        resize: @escaping @Sendable (UInt16, UInt16) -> Void,
        write: @escaping @Sendable (Data) -> Void
    ) {
        self.sessionName = sessionName
        self.clientID = clientID
        self.defaultKind = defaultKind
        self.ownershipStore = ownershipStore
        self.broadcaster = broadcaster
        self.sendText = sendText
        self.resize = resize
        self.write = write
        self.registration = broadcaster.register(sessionName: sessionName, clientID: clientID) { [weak self] snapshot in
            self?.sendOwnershipSnapshot(snapshot)
        }
    }

    deinit {
        detach()
    }

    func handleControl(_ envelope: WebControlEnvelope) {
        switch envelope {
        case let .hello(protocolClientID, _, role, visible, cols, rows):
            guard bindOrVerify(protocolClientID: protocolClientID) else { return }
            let kind = defaultKind
            let grid = try! DisplayGrid(cols: cols, rows: rows)
            lock.lock()
            attached = true
            attachedKind = kind
            lock.unlock()
            let snapshot = ownershipStore.attachClient(
                sessionName: sessionName,
                clientID: clientID,
                kind: kind,
                role: role,
                visible: visible,
                grid: grid
            )
            noteAcceptedOwnerGridIfCurrentOwner(snapshot: snapshot)
            broadcaster.broadcast(snapshot)

        case let .takeControl(protocolClientID, _, cols, rows):
            guard bindOrVerify(protocolClientID: protocolClientID) else { return }
            let kind = currentKind() ?? defaultKind
            ensureAttached(kind: kind, grid: try! DisplayGrid(cols: cols, rows: rows))
            let grid = try! DisplayGrid(cols: cols, rows: rows)
            let result = ownershipStore.claimOwner(
                sessionName: sessionName,
                clientID: clientID,
                kind: kind,
                grid: grid,
                fallbackGrid: grid
            )
            if result.accepted {
                acceptOwnerGrid(grid)
                resize(cols, rows)
            }
            broadcaster.broadcast(result.snapshot)

        case let .ownerResize(protocolClientID, epoch, cols, rows):
            guard bindOrVerify(protocolClientID: protocolClientID) else { return }
            let grid = try! DisplayGrid(cols: cols, rows: rows)
            let result = ownershipStore.ownerResize(
                sessionName: sessionName,
                clientID: clientID,
                epoch: epoch,
                grid: grid
            )
            if result.accepted {
                acceptOwnerGrid(grid)
                resize(cols, rows)
            }
            broadcaster.broadcast(result.snapshot)

        case let .resize(cols, rows):
            handleLegacyResize(cols: cols, rows: rows)

        case .grid, .ownership:
            break
        }
    }

    func handleBinary(_ data: Data) {
        if isCurrentOwner() {
            write(data)
            return
        }

        let snapshot = ownershipStore.snapshot(sessionName: sessionName)
        broadcaster.broadcast(snapshot)
    }

    func handlePTYSize(cols: UInt16, rows: UInt16) {
        guard let grid = try? DisplayGrid(cols: cols, rows: rows) else { return }
        sendText(WebControlEnvelope.grid(cols: cols, rows: rows).encoded())
        let snapshot = ownershipStore.snapshot(sessionName: sessionName, fallbackGrid: grid)
        if isCurrentOwner(), currentLastAcceptedOwnerGrid() == grid {
            broadcaster.broadcast(snapshot)
        } else {
            sendOwnershipSnapshot(snapshot)
        }
    }

    func detach() {
        lock.lock()
        if detached {
            lock.unlock()
            return
        }
        detached = true
        let wasAttached = attached
        let fallbackGrid = lastAcceptedOwnerGrid
        let registration = self.registration
        self.registration = nil
        lock.unlock()

        registration?.cancel()
        guard wasAttached else { return }
        let snapshot = ownershipStore.detachClient(
            sessionName: sessionName,
            clientID: clientID,
            fallbackGrid: fallbackGrid ?? .daemonFallback
        )
        broadcaster.broadcast(snapshot)
    }

    private func handleLegacyResize(cols: UInt16, rows: UInt16) {
        let grid = try! DisplayGrid(cols: cols, rows: rows)
        let kind = currentKind() ?? defaultKind
        ensureAttached(kind: kind, grid: grid)

        let snapshot = ownershipStore.snapshot(sessionName: sessionName, fallbackGrid: grid)
        if snapshot.ownerClientID == clientID {
            let result = ownershipStore.ownerResize(
                sessionName: sessionName,
                clientID: clientID,
                epoch: snapshot.epoch,
                grid: grid
            )
            if result.accepted {
                acceptOwnerGrid(grid)
                resize(cols, rows)
            }
            broadcaster.broadcast(result.snapshot)
            return
        }

        broadcaster.broadcast(snapshot)
    }

    private func ensureAttached(kind: DisplayClientKind, grid: DisplayGrid) {
        lock.lock()
        if attached {
            lock.unlock()
            return
        }
        attached = true
        attachedKind = kind
        lock.unlock()
        let snapshot = ownershipStore.attachClient(
            sessionName: sessionName,
            clientID: clientID,
            kind: kind,
            role: .interactive,
            visible: true,
            grid: grid
        )
        noteAcceptedOwnerGridIfCurrentOwner(snapshot: snapshot)
        broadcaster.broadcast(snapshot)
    }

    private func bindOrVerify(protocolClientID: DisplayClientID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if protocolClientID == clientID { return true }
        if let boundProtocolClientID {
            return boundProtocolClientID == protocolClientID
        }
        boundProtocolClientID = protocolClientID
        return true
    }

    private func currentKind() -> DisplayClientKind? {
        lock.lock()
        defer { lock.unlock() }
        return attachedKind
    }

    private func isCurrentOwner() -> Bool {
        ownershipStore.snapshot(sessionName: sessionName).ownerClientID == clientID
    }

    private func acceptOwnerGrid(_ grid: DisplayGrid) {
        lock.lock()
        lastAcceptedOwnerGrid = grid
        lock.unlock()
    }

    private func currentLastAcceptedOwnerGrid() -> DisplayGrid? {
        lock.lock()
        defer { lock.unlock() }
        return lastAcceptedOwnerGrid
    }

    private func noteAcceptedOwnerGridIfCurrentOwner(snapshot: DisplayOwnershipSnapshot) {
        guard snapshot.ownerClientID == clientID else { return }
        acceptOwnerGrid(snapshot.grid)
    }

    private func sendOwnershipSnapshot(_ snapshot: DisplayOwnershipSnapshot) {
        sendText(WebControlEnvelope.ownership(localizedSnapshot(snapshot)).encoded())
    }

    private func localizedSnapshot(_ snapshot: DisplayOwnershipSnapshot) -> DisplayOwnershipSnapshot {
        guard let ownerClientID = snapshot.ownerClientID else { return snapshot }
        let protocolClientID = currentProtocolClientID()
        let localizedOwnerID: DisplayClientID
        if ownerClientID == clientID {
            localizedOwnerID = protocolClientID ?? ownerClientID
        } else if ownerClientID == protocolClientID {
            localizedOwnerID = DisplayClientID("remote-owner:\(ownerClientID.rawValue)")
        } else {
            localizedOwnerID = ownerClientID
        }

        return try! DisplayOwnershipSnapshot(
            sessionName: snapshot.sessionName,
            ownerClientID: localizedOwnerID,
            ownerKind: snapshot.ownerKind,
            grid: snapshot.grid,
            epoch: snapshot.epoch
        )
    }

    private func currentProtocolClientID() -> DisplayClientID? {
        lock.lock()
        defer { lock.unlock() }
        return boundProtocolClientID
    }
}

/// HTTP + WebSocket server for Phase 2 web access. Binds to each
/// Tailscale IP (plus 127.0.0.1), serves static assets at `/`,
/// upgrades `/ws?session=<name>` to WebSocket, and gates both
/// paths via `AuthPolicy.isAllowed(peerIP:)`.
public final class WebServer {

    public enum Status: Equatable {
        case stopped
        case listening(addresses: [String], port: Int)
        case tailscaleUnavailable
        case magicDNSDisabled
        case httpsCertsNotEnabled
        /// Tailscale is up and MagicDNS is configured; we're awaiting
        /// the cert pair from `/localapi/v0/cert/<fqdn>?type=pair`. On
        /// first-mint the ACME exchange runs 10–30s, so the Settings
        /// pane renders progress instead of freezing the UI. WEB-8.6.
        case provisioningCert
        case certFetchFailed(String)
        case portUnavailable
        case error(String)
    }

    /// One entry served by `GET /repos` — the set of repositories the
    /// web user can create a new worktree under, mirroring the native
    /// sidebar's repo disclosures. `path` is opaque to the client and
    /// round-tripped as `repoPath` on `POST /worktrees` so the server
    /// doesn't have to re-derive it from a display name (which could
    /// collide when two repos share a basename).
    public struct RepoInfo: Codable, Sendable, Equatable {
        public let path: String
        public let displayName: String

        public init(path: String, displayName: String) {
            self.path = path
            self.displayName = displayName
        }
    }

    /// JSON shape accepted by `POST /worktrees`.
    public struct CreateWorktreeRequest: Codable, Sendable, Equatable {
        public let repoPath: String
        public let worktreeName: String
        public let branchName: String
        /// When `true`, the server routes to `.useExisting` rather than
        /// `.createNew`. Omitting the field on the wire is treated as `false`
        /// so existing clients don't break.
        public let existing: Bool

        public init(
            repoPath: String,
            worktreeName: String,
            branchName: String,
            existing: Bool = false
        ) {
            self.repoPath = repoPath
            self.worktreeName = worktreeName
            self.branchName = branchName
            self.existing = existing
        }

        // Custom decoder so `existing` defaults to false when absent on
        // the wire (older clients that don't know about this field).
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.repoPath = try container.decode(String.self, forKey: .repoPath)
            self.worktreeName = try container.decode(String.self, forKey: .worktreeName)
            self.branchName = try container.decode(String.self, forKey: .branchName)
            self.existing = try container.decodeIfPresent(Bool.self, forKey: .existing) ?? false
        }

        private enum CodingKeys: String, CodingKey {
            case repoPath, worktreeName, branchName, existing
        }
    }

    /// JSON shape returned by `POST /worktrees` on success. Callers
    /// navigate to `/session/<sessionName>` to attach to the first pane
    /// of the new worktree.
    public struct CreateWorktreeResponse: Codable, Sendable, Equatable {
        public let sessionName: String
        public let worktreePath: String

        public init(sessionName: String, worktreePath: String) {
            self.sessionName = sessionName
            self.worktreePath = worktreePath
        }
    }

    /// Outcome a `worktreeCreator` reports back. Success carries the
    /// session name to steer the client to; failure carries the
    /// user-visible message (typically `git worktree add`'s stderr) and
    /// a coarse reason so the handler can pick the right HTTP status.
    public enum CreateWorktreeOutcome: Sendable {
        case success(CreateWorktreeResponse)
        case invalid(String)       // 400 — bad input (empty names, unknown repo)
        case gitFailed(String)     // 409 — `git worktree add` rejected the request
        case conflict(message: String) // 409 — semantic conflict (e.g. branch already mounted)
        case internalFailure(String) // 500 — post-success discovery or spawn broke
    }

    /// JSON body accepted by `POST /worktrees/delete`. `force` mirrors
    /// the Mac's GIT-4.12 "Force Delete" branch — clients send `false`
    /// first, then re-issue with `true` if they receive a 409 carrying
    /// `forceAllowed: true`.
    public struct DeleteWorktreeRequest: Codable, Sendable, Equatable {
        public let worktreePath: String
        public let force: Bool

        public init(worktreePath: String, force: Bool) {
            self.worktreePath = worktreePath
            self.force = force
        }
    }

    /// JSON body returned by `POST /worktrees/delete` on success.
    /// `dismissed == true` when the flow ran the GIT-4.13 prune-on-
    /// vanished branch; `false` when `git worktree remove` succeeded.
    public struct DeleteWorktreeResponse: Codable, Sendable, Equatable {
        public let dismissed: Bool

        public init(dismissed: Bool) {
            self.dismissed = dismissed
        }
    }

    /// Outcome a `worktreeRemover` reports back. `gitFailedForceable`
    /// holds the trimmed `git status --short` snapshot captured at the
    /// failure point — that's what the iOS Force Delete dialog shows
    /// the user, matching ForceDeleteAlert's macOS behavior.
    public enum DeleteWorktreeOutcome: Sendable {
        case success(DeleteWorktreeResponse)
        case invalid(String)                       // 400 — empty/main checkout
        case notFound(String)                      // 404 — unknown worktree path
        case gitFailedForceable(stderr: String, shortStatus: String) // 409 forceAllowed:true
        case gitFailedFinal(String)                // 409 forceAllowed:false
        case internalFailure(String)               // 500
    }

    public enum SignalingHandlerOutcome: Sendable {
        case success(SignalingAnswer)
        case invalid(String)        // 400 — malformed offer
        case unavailable(String)    // 503 — handler not wired
        case internalFailure(String) // 500
    }

    public struct Config {
        public let port: Int
        public let zmxExecutable: URL
        public let zmxDir: URL
        /// Source for `GET /sessions`. Called on each request; runs fast
        /// because the list is read from in-memory AppState (no git work).
        public let sessionsProvider: @Sendable () async -> [SessionInfo]
        /// Resolves a WebSocket session name to the worktree directory the
        /// attach process should start in. Nil preserves the previous
        /// process-cwd behavior for unknown or legacy sessions.
        public let sessionWorktreeProvider: @Sendable (String) async -> String?
        /// Source for `GET /repos`. Same fast-snapshot contract as
        /// `sessionsProvider`: read from in-memory AppState, no git.
        public let reposProvider: @Sendable () async -> [RepoInfo]
        /// Executes `POST /worktrees`. Nil (default) means the endpoint
        /// is disabled — it responds `503` rather than `404` so the web
        /// client can tell "server doesn't support this yet" apart from
        /// "wrong URL". In production `GrafttyApp` always injects a real
        /// creator; the default exists for tests and early-boot states
        /// where `AppState` isn't wired yet.
        public let worktreeCreator: (@Sendable (CreateWorktreeRequest) async -> CreateWorktreeOutcome)?
        /// Executes `POST /worktrees/delete`. Nil disables the endpoint
        /// (503), same contract as `worktreeCreator`. Production wires
        /// this to `DeleteWorktreeFlow.delete` via `GrafttyApp.startup()`.
        public let worktreeRemover: (@Sendable (DeleteWorktreeRequest) async -> DeleteWorktreeOutcome)?
        /// Source for `GET /ghostty-config`. Returns the Mac-resolved
        /// Ghostty config so a remote client (GrafttyMobile) can render
        /// terminals with the same fonts, theme, and colors as the
        /// native Mac app. Default is empty — clients see an empty body
        /// and fall back to libghostty-spm's defaults.
        public let ghosttyConfigProvider: @Sendable () async -> String
        /// Source for `GET /worktrees/panes`. Returns one entry per
        /// running worktree with the full pane split-tree + titles, so
        /// a mobile client can render a worktree picker and the
        /// faithful pane layout inside each. Default returns an empty
        /// list.
        public let worktreePanesProvider: @Sendable () async -> [WorktreePanes]
        /// Drives `POST /v1/rtc/offer`. Receives the client's
        /// `SignalingOffer` and returns a `SignalingHandlerOutcome`. Nil
        /// disables the endpoint with a 503 response — matching the
        /// existing `worktreeCreator` shape so a client can distinguish
        /// "not supported yet" from "wrong URL".
        public let signalingHandler: (@Sendable (SignalingOffer) async -> SignalingHandlerOutcome)?
        /// TERM-11.5: when set, each WebSocket bridge's WebSession
        /// registers its zmx attach so Mac panes know a remote client
        /// is present. Nil (tests, early boot) disables tracking.
        public let remoteAttachmentRegistry: RemoteAttachmentRegistry?
        /// Shared owner gate for web/iOS display control. Production
        /// injects the process-wide store so WebSocket bridges do not
        /// split ownership state from native panes once those are wired.
        public let displayOwnershipStore: SessionDisplayOwnershipStore
        internal let ownershipBroadcaster: WebDisplayOwnershipBroadcaster

        public init(
            port: Int,
            zmxExecutable: URL,
            zmxDir: URL,
            sessionsProvider: @escaping @Sendable () async -> [SessionInfo] = { [] },
            sessionWorktreeProvider: @escaping @Sendable (String) async -> String? = { _ in nil },
            reposProvider: @escaping @Sendable () async -> [RepoInfo] = { [] },
            worktreeCreator: (@Sendable (CreateWorktreeRequest) async -> CreateWorktreeOutcome)? = nil,
            worktreeRemover: (@Sendable (DeleteWorktreeRequest) async -> DeleteWorktreeOutcome)? = nil,
            ghosttyConfigProvider: @escaping @Sendable () async -> String = { "" },
            worktreePanesProvider: @escaping @Sendable () async -> [WorktreePanes] = { [] },
            signalingHandler: (@Sendable (SignalingOffer) async -> SignalingHandlerOutcome)? = nil,
            remoteAttachmentRegistry: RemoteAttachmentRegistry? = nil,
            displayOwnershipStore: SessionDisplayOwnershipStore = SessionDisplayOwnershipStore()
        ) {
            self.port = port
            self.zmxExecutable = zmxExecutable
            self.zmxDir = zmxDir
            self.sessionsProvider = sessionsProvider
            self.sessionWorktreeProvider = sessionWorktreeProvider
            self.reposProvider = reposProvider
            self.worktreeCreator = worktreeCreator
            self.worktreeRemover = worktreeRemover
            self.ghosttyConfigProvider = ghosttyConfigProvider
            self.worktreePanesProvider = worktreePanesProvider
            self.signalingHandler = signalingHandler
            self.remoteAttachmentRegistry = remoteAttachmentRegistry
            self.displayOwnershipStore = displayOwnershipStore
            self.ownershipBroadcaster = WebDisplayOwnershipBroadcaster(store: displayOwnershipStore)
        }

        /// Accepts the range NIO's `bootstrap.bind(host:port:)` will accept
        /// without throwing: 0 (kernel-assigned ephemeral — integration
        /// tests rely on this) through 65535 (`UInt16.max`). Negative
        /// values and values ≥ 65536 are rejected.
        ///
        /// `WebServerController` runs `WebAccessSettings.port` through this
        /// gate before constructing the `Config` — without it, user input
        /// like "99999" would surface as an opaque `NIOBindError` in the
        /// Settings pane status row (`WEB-1.5`).
        public static func isValidListenablePort(_ port: Int) -> Bool {
            (0...65535).contains(port)
        }
    }

    /// Decides whether a given peer IP is allowed. Pluggable so tests
    /// can inject a permissive stub without real Tailscale.
    public struct AuthPolicy {
        public let isAllowed: @Sendable (String) async -> Bool
        public init(isAllowed: @escaping @Sendable (String) async -> Bool) { self.isAllowed = isAllowed }
    }

    public private(set) var status: Status = .stopped
    public let config: Config
    public let auth: AuthPolicy
    public let bindAddresses: [String]
    public let tlsProvider: WebTLSContextProvider

    /// Test-only hook: when non-nil, applied as `SO_SNDBUF` on every child
    /// (accepted) channel. Exists to simulate buffer-constrained network
    /// paths like the Tailscale `utun` interface where
    /// `ERR_CONTENT_LENGTH_MISMATCH` was first observed — on loopback the
    /// kernel's huge auto-sized send buffers always swallow the full
    /// response in one go, so the bug is invisible without shrinking the
    /// socket buffer. Unused in production.
    internal static var testingChildSndBuf: Int?

    private var group: EventLoopGroup?
    private var channels: [Channel] = []

    public init(
        config: Config,
        auth: AuthPolicy,
        bindAddresses: [String],
        tlsProvider: WebTLSContextProvider
    ) {
        self.config = config
        self.auth = auth
        self.bindAddresses = bindAddresses
        self.tlsProvider = tlsProvider
    }

    public func start() throws {
        precondition(group == nil, "WebServer already started")
        guard !bindAddresses.isEmpty else {
            status = .tailscaleUnavailable
            throw Status.tailscaleUnavailable.asError
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        self.group = group

        let capturedConfig = config
        let capturedAuth = auth
        let capturedTLS = tlsProvider

        var bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        if let sndBuf = Self.testingChildSndBuf {
            bootstrap = bootstrap.childChannelOption(
                ChannelOptions.socketOption(.so_sndbuf), value: .init(sndBuf)
            )
        }
        bootstrap = bootstrap
            .childChannelInitializer { channel in
                let handler = HTTPHandler(config: capturedConfig, auth: capturedAuth)
                let upgrader = Self.makeWSUpgrader(config: capturedConfig, auth: capturedAuth)
                // After a successful WebSocket upgrade, the HTTP encoder/decoder
                // are removed by NIO, but our `HTTPHandler` (added below) stays
                // in the pipeline and would receive raw WebSocketFrames — which
                // it can't decode, crashing with a "tried to decode as type
                // HTTPPart" fatalError. Remove it in the completion handler so
                // the WebSocketBridgeHandler is the only inbound handler after
                // upgrade.
                let upgradeConfig: NIOHTTPServerUpgradeConfiguration = (
                    upgraders: [upgrader],
                    completionHandler: { context in
                        context.channel.pipeline.removeHandler(handler, promise: nil)
                    }
                )
                // Snapshot the current TLS context at channel-accept time. Any
                // in-flight handshake uses this exact context even if a renewal
                // swaps the provider mid-handshake; that's fine — new connections
                // accepted after the swap pick up the fresh context on their
                // next initializer call. WEB-8.3.
                //
                // `NIOSSLServerHandler` is explicitly not `Sendable`, so we
                // add it via `pipeline.syncOperations` (which doesn't require
                // Sendable) rather than the async `pipeline.addHandler`. The
                // child-channel initializer runs on the accepting channel's
                // event loop (see `ServerBootstrap.AcceptHandler.channelRead`
                // in NIOPosix), so `syncOperations` is safe here.
                do {
                    let sslHandler = NIOSSLServerHandler(context: capturedTLS.current())
                    try channel.pipeline.syncOperations.addHandler(sslHandler)
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
                return channel.pipeline.configureHTTPServerPipeline(
                    withServerUpgrade: upgradeConfig
                ).flatMap {
                    channel.pipeline.addHandler(handler)
                }
            }

        do {
            channels = try bindAddresses.map { try bootstrap.bind(host: $0, port: config.port).wait() }
        } catch {
            try? group.syncShutdownGracefully()
            self.group = nil
            if Self.isAddressInUse(error) {
                status = .portUnavailable
            } else {
                status = .error("\(error)")
            }
            throw error
        }
        // When config.port == 0, the kernel assigns an ephemeral port; read it
        // back from the first bound channel so callers can discover the actual
        // listening port. If multiple binds produce different ports (not
        // expected with a fixed non-zero port, but defensible), the first one
        // wins.
        let actualPort = channels.first?.localAddress?.port ?? config.port
        status = .listening(addresses: bindAddresses, port: actualPort)
    }

    public func stop() {
        for c in channels { try? c.close().wait() }
        channels.removeAll()
        try? group?.syncShutdownGracefully()
        group = nil
        status = .stopped
    }

    /// Recognise an "address already in use" bind failure across the
    /// shapes NIO surfaces it as. Bridged NSError POSIX errno is the
    /// locale-stable check; the string match is a fallback.
    public static func isAddressInUse(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain && ns.code == Int(EADDRINUSE) { return true }
        let s = "\(error)"
        return s.contains("EADDRINUSE") || s.contains("Address already in use")
    }

    // MARK: - WS upgrader factory

    private static func makeWSUpgrader(config: Config, auth: AuthPolicy) -> NIOWebSocketServerUpgrader {
        return NIOWebSocketServerUpgrader(
            shouldUpgrade: { channel, head in
                guard head.uri.hasPrefix("/ws") else {
                    return channel.eventLoop.makeSucceededFuture(nil)
                }
                let peer = channel.remoteAddress?.ipAddress ?? "unknown"
                let promise = channel.eventLoop.makePromise(of: HTTPHeaders?.self)
                channel.eventLoop.execute {
                    Task {
                        let allowed = await auth.isAllowed(peer)
                        promise.succeed(allowed ? HTTPHeaders() : nil)
                    }
                }
                return promise.futureResult
            },
            upgradePipelineHandler: { channel, head in
                let session = Self.parseSession(from: head.uri)
                let promise = channel.eventLoop.makePromise(of: String?.self)
                channel.eventLoop.execute {
                    Task {
                        let worktreePath = await config.sessionWorktreeProvider(session)
                        promise.succeed(worktreePath)
                    }
                }
                return promise.futureResult.flatMap { worktreePath in
                    let wsHandler = WebSocketBridgeHandler(
                        sessionName: session,
                        zmxExecutable: config.zmxExecutable,
                        zmxDir: config.zmxDir,
                        workingDirectory: worktreePath.map { URL(fileURLWithPath: $0, isDirectory: true) },
                        remoteAttachmentRegistry: config.remoteAttachmentRegistry,
                        ownershipStore: config.displayOwnershipStore,
                        ownershipBroadcaster: config.ownershipBroadcaster,
                        defaultKind: Self.declaredDisplayClientKind(from: head)
                    )
                    return channel.pipeline.addHandler(wsHandler)
                }
            }
        )
    }

    private static func parseSession(from uri: String) -> String {
        guard let q = uri.split(separator: "?").dropFirst().first else { return "" }
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if kv.count == 2, kv[0] == "session" {
                return String(kv[1]).removingPercentEncoding ?? String(kv[1])
            }
        }
        return ""
    }

    private static func declaredDisplayClientKind(from head: HTTPRequestHead) -> DisplayClientKind {
        if head.headers.first(name: "X-Graftty-Client-Kind")?.lowercased() == "ios" {
            return .ios
        }
        if head.headers.first(name: "User-Agent")?.localizedCaseInsensitiveContains("GrafttyMobile") == true {
            return .ios
        }
        guard let q = head.uri.split(separator: "?").dropFirst().first else { return .web }
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2 else { continue }
            let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
            let value = (String(kv[1]).removingPercentEncoding ?? String(kv[1])).lowercased()
            if (key == "client" || key == "kind" || key == "clientKind"), value == "ios" {
                return .ios
            }
        }
        return .web
    }

    // MARK: - HTTP handler

    // @unchecked Sendable: NIO serializes handler callbacks onto a single
    // event loop, so `currentRequestHead` is thread-confined in practice.
    // The upgrade completionHandler closure requires Sendable capture.
    private final class HTTPHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        /// Cap accumulated request body before we give up. `POST /worktrees`
        /// accepts a tiny JSON object (~150 bytes); 64 KiB is ~400× larger
        /// than anything legitimate and a hard stop against a malicious
        /// loopback client streaming an endless body to pin server memory.
        /// Since every other route is a GET (no body), this cap never
        /// bites a real request.
        private static let maxBodyBytes = 64 * 1024

        let config: Config
        let auth: AuthPolicy
        var currentRequestHead: HTTPRequestHead?
        /// Accumulated request body for the current in-flight request.
        /// Cleared on `.end`. Short-circuited to "body too large" once
        /// we cross `maxBodyBytes`.
        var currentRequestBody: Data = Data()
        var bodyTooLarge: Bool = false

        init(config: Config, auth: AuthPolicy) {
            self.config = config
            self.auth = auth
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let part = unwrapInboundIn(data)
            switch part {
            case .head(let head):
                currentRequestHead = head
                currentRequestBody.removeAll(keepingCapacity: true)
                bodyTooLarge = false
            case .body(var buf):
                guard !bodyTooLarge else { return }
                if let bytes = buf.readBytes(length: buf.readableBytes) {
                    if currentRequestBody.count + bytes.count > Self.maxBodyBytes {
                        bodyTooLarge = true
                        currentRequestBody.removeAll(keepingCapacity: false)
                    } else {
                        currentRequestBody.append(contentsOf: bytes)
                    }
                }
            case .end:
                guard let head = currentRequestHead else { return }
                currentRequestHead = nil
                let body = currentRequestBody
                let wasTooLarge = bodyTooLarge
                currentRequestBody = Data()
                bodyTooLarge = false

                let peer = context.channel.remoteAddress?.ipAddress ?? "unknown"
                let loop = context.eventLoop
                let promise = loop.makePromise(of: Bool.self)
                let auth = self.auth
                // Register `whenComplete` *before* launching the Task so
                // a very-fast auth check can't succeed the promise before
                // the completion handler is hooked. Launch the Task
                // directly — `promise.succeed` hops to the event loop
                // internally, so wrapping the Task in
                // `eventLoop.execute` is redundant and turned out to
                // wedge on CI (macos-26) when nested bridges ran
                // back-to-back (auth → endpoint handler → respond).
                promise.futureResult.whenComplete { [weak self] result in
                    guard let self else { return }
                    let allowed = (try? result.get()) ?? false
                    if !allowed {
                        Self.respond(context: context, status: .forbidden, body: Data("forbidden\n".utf8), contentType: "text/plain; charset=utf-8")
                        return
                    }
                    if wasTooLarge {
                        Self.respondJSON(
                            context: context,
                            status: .payloadTooLarge,
                            error: "request body exceeds \(Self.maxBodyBytes) bytes"
                        )
                        return
                    }
                    self.serveStatic(context: context, head: head, body: body)
                }
                Task {
                    let allowed = await auth.isAllowed(peer)
                    promise.succeed(allowed)
                }
            }
        }

        func serveStatic(context: ChannelHandlerContext, head: HTTPRequestHead, body: Data) {
            let path = head.uri.split(separator: "?").first.map(String.init) ?? "/"
            // /ws paths are reserved for WebSocket upgrade; never fall through to
            // the SPA index for plain HTTP requests on those paths.
            if path == "/ws" || path.hasPrefix("/ws/") {
                Self.respond(context: context, status: .notFound, body: Data("not found\n".utf8), contentType: "text/plain; charset=utf-8")
                return
            }
            // WEB-5.4: session list endpoint for the client's minimal picker.
            if path == "/sessions" {
                let provider = config.sessionsProvider
                let promise = context.eventLoop.makePromise(of: [SessionInfo].self)
                promise.futureResult.whenComplete { result in
                    let sessions = (try? result.get()) ?? []
                    Self.respondEncodable(context: context, items: sessions)
                }
                Task {
                    promise.succeed(await provider())
                }
                return
            }
            // WEB-7.1: repo list for the "Add Worktree" picker.
            if path == "/repos" {
                let provider = config.reposProvider
                let promise = context.eventLoop.makePromise(of: [RepoInfo].self)
                promise.futureResult.whenComplete { result in
                    let repos = (try? result.get()) ?? []
                    Self.respondEncodable(context: context, items: repos)
                }
                Task {
                    promise.succeed(await provider())
                }
                return
            }
            // IOS-4.10: worktrees + split-faithful pane trees for the
            // mobile client's worktree → pane drilldown.
            if path == "/worktrees/panes" {
                let provider = config.worktreePanesProvider
                let promise = context.eventLoop.makePromise(of: [WorktreePanes].self)
                promise.futureResult.whenComplete { result in
                    let list = (try? result.get()) ?? []
                    Self.respondEncodable(context: context, items: list)
                }
                Task { promise.succeed(await provider()) }
                return
            }
            // IOS-4.7: the Mac's resolved Ghostty config, so a remote
            // client can render terminals identically to the desktop.
            if path == "/ghostty-config" {
                let provider = config.ghosttyConfigProvider
                let promise = context.eventLoop.makePromise(of: String.self)
                promise.futureResult.whenComplete { result in
                    let text = (try? result.get()) ?? ""
                    Self.respond(
                        context: context,
                        status: .ok,
                        body: Data(text.utf8),
                        contentType: "text/plain; charset=utf-8"
                    )
                }
                Task { promise.succeed(await provider()) }
                return
            }
            // WEB-7.2: create a new worktree. POST-only; other verbs get
            // 405 to keep caching proxies from surprising the client.
            if path == "/worktrees" {
                guard head.method == .POST else {
                    Self.respondJSON(
                        context: context,
                        status: .methodNotAllowed,
                        error: "only POST is supported"
                    )
                    return
                }
                handleCreateWorktree(context: context, body: body)
                return
            }
            // POST /v1/rtc/offer — WebRTC signaling exchange (M1.2).
            // POST-only; other verbs get 405 so caching proxies and curl
            // probes don't surprise the client.
            if path == "/v1/rtc/offer" {
                guard head.method == .POST else {
                    Self.respondJSON(
                        context: context,
                        status: .methodNotAllowed,
                        error: "only POST is supported"
                    )
                    return
                }
                handleSignalingOffer(context: context, body: body)
                return
            }
            // WEB-7.8 / WEB-7.9 / WEB-7.10: delete or dismiss a worktree.
            // POST-only; body is the same JSON envelope the iOS client
            // sends. Other verbs get 405 so caching proxies and curl
            // probes don't surprise the client.
            if path == "/worktrees/delete" {
                guard head.method == .POST else {
                    Self.respondJSON(
                        context: context,
                        status: .methodNotAllowed,
                        error: "only POST is supported"
                    )
                    return
                }
                handleDeleteWorktree(context: context, body: body)
                return
            }
            do {
                let asset = try WebStaticResources.asset(for: path)
                Self.respond(context: context, status: .ok, body: asset.data, contentType: asset.contentType)
            } catch WebStaticResources.Error.missingResource {
                // SPA fallback: any non-asset path returns index.html so
                // TanStack Router can resolve client-side routes like
                // /session/<name> when loaded directly by the browser.
                do {
                    let index = try WebStaticResources.indexHTML()
                    Self.respond(context: context, status: .ok, body: index.data, contentType: index.contentType)
                } catch {
                    Self.respond(context: context, status: .notFound, body: Data("not found\n".utf8), contentType: "text/plain; charset=utf-8")
                }
            } catch {
                Self.respond(context: context, status: .notFound, body: Data("not found\n".utf8), contentType: "text/plain; charset=utf-8")
            }
        }

        /// Decode the JSON body, invoke the injected `worktreeCreator`,
        /// and map its `CreateWorktreeOutcome` to an HTTP status +
        /// `{error|sessionName+worktreePath}` JSON envelope. The handler
        /// is synchronous-style (no `Task` escaping the handler's scope
        /// beyond the awaited creator) and schedules the async work on
        /// the event loop so NIO's handler lifecycle stays predictable.
        private func handleCreateWorktree(context: ChannelHandlerContext, body: Data) {
            guard let creator = config.worktreeCreator else {
                Self.respondJSON(
                    context: context,
                    status: .serviceUnavailable,
                    error: "worktree creation not available"
                )
                return
            }
            let decoded: CreateWorktreeRequest
            do {
                decoded = try JSONDecoder().decode(CreateWorktreeRequest.self, from: body)
            } catch {
                Self.respondJSON(
                    context: context,
                    status: .badRequest,
                    error: "invalid JSON body: \(error)"
                )
                return
            }
            // Reject empty inputs here rather than letting git produce a
            // cryptic error. The name sanitizer runs client-side, but a
            // hand-crafted request could still arrive with whitespace
            // that trims to empty.
            let wtTrim = decoded.worktreeName.trimmingCharacters(in: .whitespaces)
            let brTrim = decoded.branchName.trimmingCharacters(in: .whitespaces)
            if decoded.repoPath.isEmpty || wtTrim.isEmpty || brTrim.isEmpty {
                Self.respondJSON(
                    context: context,
                    status: .badRequest,
                    error: "repoPath, worktreeName, and branchName are required"
                )
                return
            }

            let promise = context.eventLoop.makePromise(of: CreateWorktreeOutcome.self)
            promise.futureResult.whenComplete { result in
                let outcome = (try? result.get()) ?? .internalFailure("creator dispatch failed")
                switch outcome {
                case .success(let resp):
                    do {
                        let data = try JSONEncoder().encode(resp)
                        Self.respond(
                            context: context,
                            status: .ok,
                            body: data,
                            contentType: "application/json; charset=utf-8"
                        )
                    } catch {
                        Self.respondJSON(
                            context: context,
                            status: .internalServerError,
                            error: "encoding error"
                        )
                    }
                case .invalid(let msg):
                    Self.respondJSON(context: context, status: .badRequest, error: msg)
                case .gitFailed(let msg):
                    Self.respondJSON(context: context, status: .conflict, error: msg)
                case .conflict(let msg):
                    Self.respondJSON(context: context, status: .conflict, error: msg)
                case .internalFailure(let msg):
                    Self.respondJSON(context: context, status: .internalServerError, error: msg)
                }
            }
            Task {
                promise.succeed(await creator(decoded))
            }
        }

        /// Decode the JSON body, invoke the injected `worktreeRemover`,
        /// and map its `DeleteWorktreeOutcome` to an HTTP status + JSON
        /// envelope. Same scheduling shape as `handleCreateWorktree`.
        private func handleDeleteWorktree(context: ChannelHandlerContext, body: Data) {
            guard let remover = config.worktreeRemover else {
                Self.respondJSON(
                    context: context,
                    status: .serviceUnavailable,
                    error: "worktree deletion not available"
                )
                return
            }
            let decoded: WebServer.DeleteWorktreeRequest
            do {
                decoded = try JSONDecoder().decode(WebServer.DeleteWorktreeRequest.self, from: body)
            } catch {
                Self.respondJSON(
                    context: context,
                    status: .badRequest,
                    error: "invalid JSON body: \(error)"
                )
                return
            }
            let trimmedPath = decoded.worktreePath.trimmingCharacters(in: .whitespaces)
            if trimmedPath.isEmpty {
                Self.respondJSON(
                    context: context,
                    status: .badRequest,
                    error: "worktreePath is required"
                )
                return
            }

            let promise = context.eventLoop.makePromise(of: WebServer.DeleteWorktreeOutcome.self)
            promise.futureResult.whenComplete { result in
                let outcome = (try? result.get()) ?? .internalFailure("remover dispatch failed")
                switch outcome {
                case .success(let resp):
                    do {
                        let data = try JSONEncoder().encode(resp)
                        Self.respond(
                            context: context,
                            status: .ok,
                            body: data,
                            contentType: "application/json; charset=utf-8"
                        )
                    } catch {
                        Self.respondJSON(
                            context: context,
                            status: .internalServerError,
                            error: "encoding error"
                        )
                    }
                case .invalid(let msg):
                    Self.respondJSON(context: context, status: .badRequest, error: msg)
                case .notFound(let msg):
                    Self.respondJSON(context: context, status: .notFound, error: msg)
                case .gitFailedForceable(let stderr, let shortStatus):
                    struct ForceableBody: Codable {
                        let error: String
                        let forceAllowed: Bool
                        let shortStatus: String
                    }
                    let body = (try? JSONEncoder().encode(ForceableBody(
                        error: stderr, forceAllowed: true, shortStatus: shortStatus
                    ))) ?? Data(#"{"error":"unknown","forceAllowed":true}"#.utf8)
                    Self.respond(
                        context: context,
                        status: .conflict,
                        body: body,
                        contentType: "application/json; charset=utf-8"
                    )
                case .gitFailedFinal(let stderr):
                    struct FinalBody: Codable { let error: String; let forceAllowed: Bool }
                    let body = (try? JSONEncoder().encode(FinalBody(
                        error: stderr, forceAllowed: false
                    ))) ?? Data(#"{"error":"unknown","forceAllowed":false}"#.utf8)
                    Self.respond(
                        context: context,
                        status: .conflict,
                        body: body,
                        contentType: "application/json; charset=utf-8"
                    )
                case .internalFailure(let msg):
                    Self.respondJSON(context: context, status: .internalServerError, error: msg)
                }
            }
            Task {
                promise.succeed(await remover(decoded))
            }
        }

        /// Decode the JSON body as a `SignalingOffer`, invoke the
        /// injected `signalingHandler`, and map the outcome to an HTTP
        /// status + JSON envelope. Mirrors `handleCreateWorktree`.
        private func handleSignalingOffer(context: ChannelHandlerContext, body: Data) {
            guard let handler = config.signalingHandler else {
                Self.respondJSON(
                    context: context,
                    status: .serviceUnavailable,
                    error: "signaling endpoint not available"
                )
                return
            }
            let offer: SignalingOffer
            do {
                offer = try JSONDecoder().decode(SignalingOffer.self, from: body)
            } catch {
                Self.respondJSON(
                    context: context,
                    status: .badRequest,
                    error: "malformed signaling offer: \(error.localizedDescription)"
                )
                return
            }
            let promise = context.eventLoop.makePromise(of: WebServer.SignalingHandlerOutcome.self)
            promise.futureResult.whenComplete { result in
                let outcome = (try? result.get()) ?? .internalFailure("handler dispatch failed")
                switch outcome {
                case .success(let answer):
                    do {
                        let data = try JSONEncoder().encode(answer)
                        Self.respond(
                            context: context,
                            status: .ok,
                            body: data,
                            contentType: "application/json; charset=utf-8"
                        )
                    } catch {
                        Self.respondJSON(
                            context: context,
                            status: .internalServerError,
                            error: "encoding error"
                        )
                    }
                case .invalid(let msg):
                    Self.respondJSON(context: context, status: .badRequest, error: msg)
                case .unavailable(let msg):
                    Self.respondJSON(context: context, status: .serviceUnavailable, error: msg)
                case .internalFailure(let msg):
                    Self.respondJSON(context: context, status: .internalServerError, error: msg)
                }
            }
            Task {
                promise.succeed(await handler(offer))
            }
        }

        /// Encode a concrete array and respond 200 (or 500 on encoding
        /// failure). Called from the `/sessions` and `/repos` handlers
        /// once they've resolved their respective providers — kept
        /// non-generic so there's no runtime-generic dispatch on NIO's
        /// event loop, which surfaced as an unreachable-test hang on
        /// CI when the first call site was generic.
        private static func respondEncodable<T: Encodable>(
            context: ChannelHandlerContext,
            items: [T]
        ) {
            do {
                let data = try JSONEncoder().encode(items)
                Self.respond(
                    context: context,
                    status: .ok,
                    body: data,
                    contentType: "application/json; charset=utf-8"
                )
            } catch {
                Self.respondJSON(
                    context: context,
                    status: .internalServerError,
                    error: "encoding error"
                )
            }
        }

        /// Respond with `{"error": "<msg>"}`. The client always gets
        /// JSON even for 4xx/5xx so it can render the error inline next
        /// to the form field without special-casing content type.
        static func respondJSON(
            context: ChannelHandlerContext,
            status: HTTPResponseStatus,
            error: String
        ) {
            struct ErrorBody: Codable { let error: String }
            let body = (try? JSONEncoder().encode(ErrorBody(error: error)))
                ?? Data(#"{"error":"unknown"}"#.utf8)
            Self.respond(
                context: context,
                status: status,
                body: body,
                contentType: "application/json; charset=utf-8"
            )
        }

        static func respond(context: ChannelHandlerContext, status: HTTPResponseStatus, body: Data, contentType: String) {
            writeHTTPResponse(context: context, status: status, body: body, contentType: contentType)
        }
    }

    // MARK: - WebSocket bridge handler

    private final class WebSocketBridgeHandler: ChannelInboundHandler {
        typealias InboundIn = WebSocketFrame
        typealias OutboundOut = WebSocketFrame

        let sessionName: String
        let zmxExecutable: URL
        let zmxDir: URL
        let workingDirectory: URL?
        /// TERM-11.5: handed to each WebSession before `start()` so the
        /// session registers its zmx attach (and deregisters on close).
        let remoteAttachmentRegistry: RemoteAttachmentRegistry?
        let ownershipStore: SessionDisplayOwnershipStore
        let ownershipBroadcaster: WebDisplayOwnershipBroadcaster
        let defaultKind: DisplayClientKind
        let clientID: DisplayClientID
        private var session: WebSession?
        private weak var channel: Channel?
        private var coordinator: WebSocketBridgeCoordinator?

        init(
            sessionName: String,
            zmxExecutable: URL,
            zmxDir: URL,
            workingDirectory: URL?,
            remoteAttachmentRegistry: RemoteAttachmentRegistry?,
            ownershipStore: SessionDisplayOwnershipStore,
            ownershipBroadcaster: WebDisplayOwnershipBroadcaster,
            defaultKind: DisplayClientKind
        ) {
            self.sessionName = sessionName
            self.zmxExecutable = zmxExecutable
            self.zmxDir = zmxDir
            self.workingDirectory = workingDirectory
            self.remoteAttachmentRegistry = remoteAttachmentRegistry
            self.ownershipStore = ownershipStore
            self.ownershipBroadcaster = ownershipBroadcaster
            self.defaultKind = defaultKind
            self.clientID = DisplayClientID("websocket-\(UUID().uuidString)")
        }

        func handlerAdded(context: ChannelHandlerContext) {
            channel = context.channel
            let bridge = WebSocketBridgeCoordinator(
                sessionName: sessionName,
                clientID: clientID,
                defaultKind: defaultKind,
                ownershipStore: ownershipStore,
                broadcaster: ownershipBroadcaster,
                sendText: { [weak channel = context.channel] payload in
                    guard let channel else { return }
                    channel.eventLoop.execute {
                        var buf = channel.allocator.buffer(capacity: payload.utf8.count)
                        buf.writeString(payload)
                        let frame = WebSocketFrame(fin: true, opcode: .text, data: buf)
                        channel.writeAndFlush(frame, promise: nil)
                    }
                },
                resize: { [weak self] cols, rows in
                    self?.session?.resize(cols: cols, rows: rows)
                },
                write: { [weak self] data in
                    self?.session?.write(data)
                }
            )
            coordinator = bridge
            let sess = WebSession(config: WebSession.Config(
                zmxExecutable: zmxExecutable,
                zmxDir: zmxDir,
                sessionName: sessionName,
                workingDirectory: workingDirectory
            ))
            sess.onPTYData = { [weak self] data in
                guard let self, let channel = self.channel else { return }
                channel.eventLoop.execute {
                    var buffer = channel.allocator.buffer(capacity: data.count)
                    buffer.writeBytes(data)
                    let frame = WebSocketFrame(fin: true, opcode: .binary, data: buffer)
                    channel.writeAndFlush(frame, promise: nil)
                }
            }
            sess.onExit = { [weak self] in
                guard let self, let channel = self.channel else { return }
                channel.eventLoop.execute {
                    let close = WebSocketFrame(
                        fin: true,
                        opcode: .connectionClose,
                        data: channel.allocator.buffer(capacity: 0)
                    )
                    channel.writeAndFlush(close, promise: nil)
                    channel.close(promise: nil)
                }
            }
            sess.onPTYSize = { [weak self] cols, rows in
                self?.coordinator?.handlePTYSize(cols: cols, rows: rows)
            }
            sess.attachmentRegistry = remoteAttachmentRegistry
            do {
                try sess.start()
                session = sess
            } catch {
                let errMsg = #"{"type":"error","message":"session unavailable"}"#
                var buf = context.channel.allocator.buffer(capacity: errMsg.utf8.count)
                buf.writeString(errMsg)
                let frame = WebSocketFrame(fin: true, opcode: .text, data: buf)
                context.writeAndFlush(NIOAny(frame), promise: nil)
                context.close(promise: nil)
            }
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let frame = unwrapInboundIn(data)
            switch frame.opcode {
            case .binary:
                var buf = frame.unmaskedData
                if let bytes = buf.readBytes(length: buf.readableBytes) {
                    coordinator?.handleBinary(Data(bytes))
                }
            case .text:
                var buf = frame.unmaskedData
                if let bytes = buf.readBytes(length: buf.readableBytes) {
                    let payload = Data(bytes)
                    if let env = try? WebControlEnvelope.parse(payload) {
                        coordinator?.handleControl(env)
                    }
                }
            case .connectionClose:
                coordinator?.detach()
                session?.close()
                context.close(promise: nil)
            case .ping:
                let pong = WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)
                context.writeAndFlush(NIOAny(pong), promise: nil)
            default:
                break
            }
        }

        func channelInactive(context: ChannelHandlerContext) {
            coordinator?.detach()
            session?.close()
        }
    }
}

private extension WebServer.Status {
    var asError: Swift.Error {
        NSError(domain: "WebServer", code: 0, userInfo: [NSLocalizedDescriptionKey: "\(self)"])
    }
}
