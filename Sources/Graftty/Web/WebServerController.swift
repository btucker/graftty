import Foundation
import GrafttyKit
import GrafttyProtocol
import Combine

/// Owns the `WebServer` lifetime at app scope. Subscribes to
/// `WebAccessSettings` and starts/stops the server accordingly.
@MainActor
final class WebServerController: ObservableObject {

    @Published private(set) var status: WebServer.Status = .stopped
    @Published private(set) var serverHostname: String? = nil

    private var server: WebServer?
    private var renewer: WebCertRenewer?
    /// In-flight task running the Tailscale `status` query, `certPair` and
    /// server bring-up off the MainActor (WEB-1.15). Cancelled on
    /// stop()/re-reconcile, with each post-await step gated on
    /// `Task.isCancelled` so a stale completion can't race a fresh status
    /// onto the pane. WEB-8.6.
    private var reconcileTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var bindingServer = false
    private var shuttingDown = false
    /// Pending automatic retry after a transient cold-boot failure. A Mac
    /// restart relaunches Graftty during session-restore *before* `tailscaled`
    /// has finished coming up, so the first bring-up commonly fails with a
    /// transient dependency error and — without this — the server never comes
    /// online until the user manually toggles Web Access. Cancelled by stop(),
    /// a fresh reconcile, or a successful bring-up. WEB-1.14.
    private var retryTask: Task<Void, Never>?
    /// Consecutive transient-failure count; drives the backoff schedule and
    /// resets to 0 on a successful bring-up or stop(). WEB-1.14.
    private var retryAttempt = 0
    private let settings: WebAccessSettings
    private let zmxExecutable: URL
    private let zmxDir: URL
    private var cancellables = Set<AnyCancellable>()
    /// Resolves the LocalAPI endpoint and reads its status. Injected by tests
    /// so WEB-1.15 can hold the daemon "pending" without a real tailscaled.
    private let fetchTailscaleStatus: TailscaleStatusFetch
    private let startServer: @MainActor (WebServer) async throws -> Void
    private let stopServer: @MainActor (WebServer) async -> Void
    private let retrySleep: @Sendable (Duration) async throws -> Void
    private let fetchCertificate: @Sendable (TailscaleLocalAPI, String) async throws -> (cert: Data, key: Data)

    /// `@concurrent` so the daemon round-trip runs off the main actor even
    /// if nonisolated async functions start inheriting their caller's actor
    /// (NonisolatedNonsendingByDefault). WEB-1.15.
    typealias TailscaleStatusFetch = @concurrent @Sendable () async throws -> (api: TailscaleLocalAPI, status: TailscaleLocalAPI.Status)

    /// Supplies `GET /sessions` with the current running sessions
    /// (`WEB-5.4`). Injected by `GrafttyApp` after `appState` + the
    /// `terminalManager`'s session-name function exist. Nil before
    /// injection (default-empty provider is baked into `WebServer.Config`).
    private var sessionsProvider: (@Sendable () async -> [SessionInfo])?
    private var sessionWorktreeProvider: (@Sendable (String) async -> String?)?
    private var sessionSpawnProvider: (@Sendable (String) async -> ZmxSpawnConfiguration?)?
    private var worktreePanesProvider: (@Sendable () async -> [WorktreePanes])?
    private var relayedWorktreePanesProvider:
        (@Sendable () async -> [WorktreePanes])?
    /// Supplies `GET /repos` (`WEB-7.1`). Same injection timing as
    /// `sessionsProvider` — both read from `AppState`.
    private var reposProvider: (@Sendable () async -> [WebServer.RepoInfo])?
    private var agentCompletionsProvider: (@Sendable (String?) async -> [AgentCompletionCandidate])?
    private var relayedReposProvider:
        (@Sendable () async -> [WebServer.RepoInfo])?
    /// Executes `POST /worktrees` (`WEB-7.2`). Routes into
    /// `AddWorktreeFlow.add` on the main actor. Nil before injection
    /// causes the endpoint to respond `503 service unavailable`.
    private var worktreeCreator: (@Sendable (WebServer.CreateWorktreeRequest) async -> WebServer.CreateWorktreeOutcome)?
    /// Executes `POST /repos/default-branch/pull` (`WEB-7.12`).
    /// Routes into `GitDefaultBranchPull` from `GrafttyApp`.
    private var defaultBranchPuller: (@Sendable (WebServer.PullDefaultBranchRequest) async -> WebServer.PullDefaultBranchOutcome)?
    /// Executes `POST /worktrees/delete` (`WEB-7.8` / `WEB-7.9` /
    /// `WEB-7.10`). Routes into `DeleteWorktreeFlow.delete` on the
    /// main actor. Nil before injection causes the endpoint to respond
    /// `503 service unavailable`.
    private var worktreeRemover: (@Sendable (WebServer.DeleteWorktreeRequest) async -> WebServer.DeleteWorktreeOutcome)?
    /// TERM-11.5: counts remote clients per zmx session so Mac panes
    /// know a remote viewer is attached. Nil before injection — the
    /// `WebServer.Config` default disables tracking. Injected by
    /// `GrafttyApp.startup()` alongside the other providers.
    private var remoteAttachmentRegistry: RemoteAttachmentRegistry?
    /// Supplies `GET /ghostty-keybindings` with the Mac-resolved
    /// Ghostty action-to-shortcut map.
    private var ghosttyKeybindingsProvider: (@Sendable () async -> [GhosttyAction: ShortcutChord])?
    /// Shared display-ownership gate for web/iOS sockets. Production
    /// injects the process-wide store from `GrafttyApp`; tests and
    /// early construction fall back to a controller-owned store.
    private var displayOwnershipStore: SessionDisplayOwnershipStore

    /// Last `(isEnabled, port)` tuple we reconciled against. Used to suppress
    /// no-op reconciles — `objectWillChange` on `@AppStorage` fires on every
    /// property write, including ones that don't affect our server.
    private var lastApplied: (enabled: Bool, port: Int)?

    init(
        settings: WebAccessSettings,
        zmxExecutable: URL,
        zmxDir: URL,
        displayOwnershipStore: SessionDisplayOwnershipStore = SessionDisplayOwnershipStore(),
        fetchTailscaleStatus: @escaping TailscaleStatusFetch = { try await WebServerController.autoDetectedTailscaleStatus() },
        retrySleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        fetchCertificate: @escaping @Sendable (TailscaleLocalAPI, String) async throws -> (cert: Data, key: Data) = { try await $0.certPair(for: $1) },
        startServer: @escaping @MainActor (WebServer) async throws -> Void = { try await $0.startAsync() },
        stopServer: @escaping @MainActor (WebServer) async -> Void = { await $0.stopAsync() }
    ) {
        self.settings = settings
        self.fetchTailscaleStatus = fetchTailscaleStatus
        self.startServer = startServer
        self.stopServer = stopServer
        self.retrySleep = retrySleep
        self.fetchCertificate = fetchCertificate
        self.zmxExecutable = zmxExecutable
        self.zmxDir = zmxDir
        self.displayOwnershipStore = displayOwnershipStore
        reconcile()
        settings.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.reconcile() }
            }
            .store(in: &cancellables)
    }

    func stop() {
        retireCurrentAttempt()
        retryAttempt = 0
        status = .stopped
        serverHostname = nil
        lastApplied = nil
    }

    /// Normal quit uses deferred AppKit termination so listener/session
    /// cleanup can finish without blocking the main actor. Suppress late
    /// settings/provider notifications while that final cleanup is pending.
    func shutdown() async {
        shuttingDown = true
        stop()
        await cleanupTask?.value
    }

    /// Cancel immediately, but keep ownership of obsolete attempts/listeners
    /// until their asynchronous cleanup finishes. A replacement waits on this
    /// chain so it cannot race an old listener for the same port.
    @discardableResult
    private func retireCurrentAttempt() -> Task<Void, Never> {
        generation &+= 1
        let oldAttempt = reconcileTask
        oldAttempt?.cancel()
        reconcileTask = nil
        retryTask?.cancel()
        retryTask = nil
        renewer?.stop()
        renewer = nil
        let oldServer = server
        server = nil
        let previousCleanup = cleanupTask
        let stopServer = self.stopServer
        let cleanup = Task {
            await previousCleanup?.value
            await oldAttempt?.value
            if let oldServer { await stopServer(oldServer) }
        }
        cleanupTask = cleanup
        return cleanup
    }

    var cleanupTaskForTests: Task<Void, Never>? { cleanupTask }

    func reconcileForTests() { reconcile() }

    private func isCurrent(generation: UInt64, port: Int) -> Bool {
        !Task.isCancelled && self.generation == generation
            && !shuttingDown && settings.isEnabled && settings.port == port
    }

    /// Install (or replace) the provider used for `GET /sessions`. Called
    /// from `GrafttyApp.startup()` once `appState` is available. Rebuilds
    /// a running server so it picks up the new closure; no-op if the
    /// server isn't up yet (the next reconcile will read the latest one).
    func setSessionsProvider(
        _ provider: @escaping @Sendable () async -> [SessionInfo]
    ) {
        sessionsProvider = provider
        rebuildIfRunning()
    }

    /// Install (or replace) the provider used by `/ws?session=...` to
    /// start web/iOS attach processes in the same worktree directory as
    /// their native pane.
    func setSessionWorktreeProvider(
        _ provider: @escaping @Sendable (String) async -> String?
    ) {
        sessionWorktreeProvider = provider
        rebuildIfRunning()
    }

    func setSessionSpawnProvider(
        _ provider: @escaping @Sendable (String) async -> ZmxSpawnConfiguration?
    ) {
        sessionSpawnProvider = provider
        rebuildIfRunning()
    }

    /// Install the provider used for `GET /repos`. Same contract as
    /// `setSessionsProvider`.
    func setReposProvider(
        _ provider: @escaping @Sendable () async -> [WebServer.RepoInfo]
    ) {
        reposProvider = provider
        rebuildIfRunning()
    }

    func setAgentCompletionsProvider(_ provider: @escaping @Sendable (String?) async -> [AgentCompletionCandidate]) {
        agentCompletionsProvider = provider
        rebuildIfRunning()
    }

    /// Install the one-hop repository provider. Its rows are only exposed
    /// to clients that advertise relay support.
    func setRelayedReposProvider(
        _ provider: @escaping @Sendable () async -> [WebServer.RepoInfo]
    ) {
        relayedReposProvider = provider
        rebuildIfRunning()
    }

    /// Install the provider used for `GET /worktrees/panes`. Same
    /// contract as `setSessionsProvider`.
    func setWorktreePanesProvider(
        _ provider: @escaping @Sendable () async -> [WorktreePanes]
    ) {
        worktreePanesProvider = provider
        rebuildIfRunning()
    }

    /// Install the one-hop worktree provider. Its rows are only exposed
    /// to clients that advertise relay support.
    func setRelayedWorktreePanesProvider(
        _ provider: @escaping @Sendable () async -> [WorktreePanes]
    ) {
        relayedWorktreePanesProvider = provider
        rebuildIfRunning()
    }

    /// Install the provider used for `GET /ghostty-keybindings`. Same
    /// rebuild contract as the other snapshot providers.
    func setGhosttyKeybindingsProvider(
        _ provider: @escaping @Sendable () async -> [GhosttyAction: ShortcutChord]
    ) {
        ghosttyKeybindingsProvider = provider
        rebuildIfRunning()
    }

    /// Install the creator used for `POST /worktrees`. Must be wired
    /// before the endpoint is useful; prior to injection requests get
    /// `503 service unavailable`.
    func setWorktreeCreator(
        _ creator: @escaping @Sendable (WebServer.CreateWorktreeRequest) async -> WebServer.CreateWorktreeOutcome
    ) {
        worktreeCreator = creator
        rebuildIfRunning()
    }

    /// Install the puller used for `POST /repos/default-branch/pull`.
    func setDefaultBranchPuller(
        _ puller: @escaping @Sendable (WebServer.PullDefaultBranchRequest) async -> WebServer.PullDefaultBranchOutcome
    ) {
        defaultBranchPuller = puller
        rebuildIfRunning()
    }

    /// Install the remover used for `POST /worktrees/delete`. Same
    /// contract as `setWorktreeCreator`: pre-injection requests get
    /// `503 service unavailable`.
    func setWorktreeRemover(
        _ remover: @escaping @Sendable (WebServer.DeleteWorktreeRequest) async -> WebServer.DeleteWorktreeOutcome
    ) {
        worktreeRemover = remover
        rebuildIfRunning()
    }

    /// Install the registry that tracks remote attaches per zmx session
    /// (`TERM-11.5`). Same contract as `setSessionsProvider`: rebuilds a
    /// running server so new WebSocket bridges pick it up.
    func setRemoteAttachmentRegistry(_ registry: RemoteAttachmentRegistry) {
        remoteAttachmentRegistry = registry
        rebuildIfRunning()
    }

    /// Install the process-wide display ownership store. Rebuilds a
    /// running server so new WebSocket bridges share ownership state
    /// with any other ownership-aware surfaces.
    func setDisplayOwnershipStore(_ store: SessionDisplayOwnershipStore) {
        displayOwnershipStore = store
        rebuildIfRunning()
    }

    var displayOwnershipStoreForTests: SessionDisplayOwnershipStore {
        displayOwnershipStore
    }

    var retryTaskForTests: Task<Void, Never>? { retryTask }

    var reconcileTaskForTests: Task<Void, Never>? {
        reconcileTask
    }

    /// Rebuild a listener whose configuration was already captured. Status
    /// and certificate fetches still read the latest providers at build time,
    /// so provider injection need not restart those in-flight operations.
    private func rebuildIfRunning() {
        guard server != nil || bindingServer else { return }
        lastApplied = nil
        reconcile()
    }

    /// Record failure only for the current settings generation. Cancellation
    /// or a newer setting must not publish an obsolete error or retry.
    private func failReconcile(_ s: WebServer.Status, generation: UInt64, port: Int) {
        guard isCurrent(generation: generation, port: port) else { return }
        status = s
        lastApplied = nil
        scheduleRetry(after: s)
    }

    /// Only status-query failures use this cold-boot retry policy. A decode
    /// failure in whois still denies access, and certificate errors retain
    /// their provisioning-specific status and retry policy.
    nonisolated static func isTransientStatusError(_ error: any Error) -> Bool {
        // parseStatus exposes JSONDecoder errors for truncated/invalid JSON.
        // This helper is used only by the status query, never cert or whois.
        if error is DecodingError { return true }
        switch error as? TailscaleLocalAPI.Error {
        case .socketUnreachable, .malformedResponse: return true
        case .httpError(let code): return (500...599).contains(code)
        default: return false
        }
    }

    /// Cold-boot dependency failures that warrant an automatic retry: the
    /// Tailscale daemon isn't up yet, MagicDNS hasn't published our name, or
    /// the cert isn't mintable yet. A Mac restart relaunches Graftty during
    /// session-restore *before* `tailscaled` finishes coming up, so the first
    /// bring-up attempt commonly lands here. Terminal statuses
    /// (`portUnavailable`, `httpsCertsNotEnabled`, `.error`) are excluded —
    /// retrying can't fix a misconfiguration or a port owned by another app.
    /// WEB-1.14.
    nonisolated static func isTransientStartupFailure(_ status: WebServer.Status) -> Bool {
        switch status {
        case .tailscaleUnavailable, .magicDNSDisabled, .certFetchFailed:
            return true
        case .stopped, .listening, .httpsCertsNotEnabled, .provisioningCert,
             .portUnavailable, .error:
            return false
        }
    }

    /// Delay before the next automatic reconcile retry, or `nil` when `status`
    /// is a success/terminal status that retrying can't advance. `attempt` is
    /// 1-based. Capped exponential via the shared `ExponentialBackoff`: 2, 4, 8,
    /// 16, 30, 30… seconds — so a tailnet that never recovers re-probes every
    /// 30s rather than backing off to hours. WEB-1.14.
    nonisolated static func retryDelay(
        afterTransientFailure status: WebServer.Status,
        attempt: Int
    ) -> Duration? {
        guard isTransientStartupFailure(status) else { return nil }
        return ExponentialBackoff.scale(
            base: .seconds(2), streak: max(1, attempt) - 1, cap: .seconds(30)
        )
    }

    /// Schedule an automatic reconcile retry when `status` is a transient
    /// cold-boot failure and web access is still enabled. No-ops (and resets
    /// the backoff) for terminal/success statuses. WEB-1.14.
    private func scheduleRetry(after status: WebServer.Status) {
        retryTask?.cancel()
        retryTask = nil
        guard settings.isEnabled,
              let delay = Self.retryDelay(
                afterTransientFailure: status, attempt: retryAttempt + 1
              )
        else {
            retryAttempt = 0
            return
        }
        retryAttempt += 1
        let retrySleep = self.retrySleep
        retryTask = Task { [weak self] in
            do { try await retrySleep(delay) } catch { return }
            guard let self, !Task.isCancelled else { return }
            // Detach our own handle BEFORE reconcile() so its top-of-function
            // `retryTask?.cancel()` doesn't cancel *this* running Task. WEB-1.14.
            self.retryTask = nil
            // The desired (enabled, port) tuple is unchanged from the failed
            // attempt, so clear `lastApplied` too or reconcile()'s no-op guard
            // would early-return and the retry would do nothing.
            self.lastApplied = nil
            self.reconcile()
        }
    }

    private func reconcile() {
        guard !shuttingDown else { return }
        let desired = (enabled: settings.isEnabled, port: settings.port)
        if let last = lastApplied, last == desired { return }
        lastApplied = desired
        let previousStatus = status

        // A fresh attempt supersedes any pending retry; scheduleRetry will
        // re-arm one (with the incremented backoff) if this attempt also
        // fails transiently. WEB-1.14.
        let cleanup = retireCurrentAttempt()
        let generation = self.generation
        status = .stopped
        serverHostname = nil
        guard desired.enabled else {
            // Disabling web access ends the bring-up campaign — reset the
            // backoff so a later re-enable starts fresh at 2s rather than
            // inheriting the elevated attempt count from before. WEB-1.14.
            retryAttempt = 0
            return
        }
        // Validate port BEFORE reaching into Tailscale / NIO. An
        // out-of-range `WebAccessSettings.port` (e.g. the user typed
        // "99999" into the Settings TextField, which has no clamp of
        // its own) otherwise surfaces as `NIOBindError(port: 99999, …)`
        // in the status row — opaque to the user. `WEB-1.5`.
        guard WebServer.Config.isValidListenablePort(desired.port) else {
            status = .error("Port must be 0–65535 (got \(desired.port))")
            retryAttempt = 0  // terminal status ends the retry campaign. WEB-1.14
            return
        }
        // Keep showing the last transient failure while this attempt
        // re-queries Tailscale, rather than flashing "Stopped" on every
        // WEB-1.14 retry until the off-main status query answers. WEB-1.15.
        if Self.isTransientStartupFailure(previousStatus) {
            status = previousStatus
        }
        let port = desired.port
        reconcileTask = Task { [weak self] in
            await cleanup.value
            guard let self, self.isCurrent(generation: generation, port: port) else { return }
            await self.completeReconcile(port: port, generation: generation)
        }
    }

    @concurrent nonisolated static func autoDetectedTailscaleStatus() async throws -> (api: TailscaleLocalAPI, status: TailscaleLocalAPI.Status) {
        let api = try await OffMainIO.run { try TailscaleLocalAPI.autoDetected() }
        return (api, try await api.status())
    }

    private func completeReconcile(port: Int, generation: UInt64) async {
        // Endpoint detection runs off the main actor, and LocalAPI socket
        // I/O runs asynchronously on NIO event loops. WEB-1.15/WEB-1.16.
        let api: TailscaleLocalAPI
        let tailscaleStatus: TailscaleLocalAPI.Status
        do {
            (api, tailscaleStatus) = try await fetchTailscaleStatus()
        } catch {
            guard isCurrent(generation: generation, port: port) else { return }
            // Only status-query framing/timeouts and 5xx mean the daemon
            // may still be booting. Whois remains fail-closed and certificate
            // failures retain their existing endpoint-specific policy.
            if Self.isTransientStatusError(error) {
                failReconcile(.tailscaleUnavailable, generation: generation, port: port)
            } else {
                status = .error("\(error)")
                retryAttempt = 0
            }
            return
        }
        guard isCurrent(generation: generation, port: port) else { return }
        guard let fqdn = tailscaleStatus.dnsName else {
            // MagicDNS name not yet published — transient at cold boot, or the
            // user just enabled MagicDNS in the admin console. failReconcile
            // clears lastApplied and arms a backoff retry (WEB-1.14), so the
            // server self-heals without a manual Web Access toggle.
            failReconcile(.magicDNSDisabled, generation: generation, port: port)
            return
        }

        status = .provisioningCert
        let bindAddresses = tailscaleStatus.tailscaleIPs
        let ownerLogin = tailscaleStatus.loginName
        let pair: (cert: Data, key: Data)
        do {
            pair = try await fetchCertificate(api, fqdn)
        } catch is CancellationError {
            return
        } catch TailscaleLocalAPI.Error.httpsCertsDisabled {
            failReconcile(.httpsCertsNotEnabled, generation: generation, port: port)
            return
        } catch {
            failReconcile(.certFetchFailed("\(error)"), generation: generation, port: port)
            return
        }
        guard isCurrent(generation: generation, port: port) else { return }

        let provider: WebTLSContextProvider
        do {
            provider = WebTLSContextProvider(
                initial: try WebTLSCertFetcher.buildContext(
                    certPEM: pair.cert, keyPEM: pair.key
                )
            )
        } catch {
            failReconcile(.certFetchFailed("\(error)"), generation: generation, port: port)
            return
        }

        let auth = WebServer.AuthPolicy { [api] peerIP in
            guard let whois = try? await api.whois(peerIP: peerIP) else { return false }
            return whois.loginName == ownerLogin
        }
        let sessionsProvider = self.sessionsProvider ?? { [] }
        let sessionWorktreeProvider = self.sessionWorktreeProvider ?? { _ in nil }
        let repos = reposProvider ?? { [] }
        let relayedRepos = relayedReposProvider ?? { [] }
        let creator = worktreeCreator
        let puller = defaultBranchPuller
        let remover = worktreeRemover
        // Deliberately NOT defaulted to an empty map: a nil provider means
        // startup() hasn't wired the keybind bridge yet, and the endpoint
        // answers 503 so clients keep their bundled fallback instead of
        // caching {} as host-resolved (WEB-9.10).
        let ghosttyKeybindingsProvider = self.ghosttyKeybindingsProvider
        let s = WebServer(
            config: .init(
                port: port,
                zmxExecutable: zmxExecutable,
                zmxDir: zmxDir,
                sessionsProvider: sessionsProvider,
                sessionWorktreeProvider: sessionWorktreeProvider,
                sessionSpawnProvider: self.sessionSpawnProvider ?? { _ in nil },
                reposProvider: repos,
                agentCompletionsProvider: agentCompletionsProvider ?? { _ in [] },
                relayedReposProvider: relayedRepos,
                worktreeCreator: creator,
                defaultBranchPuller: puller,
                worktreeRemover: remover,
                ghosttyConfigProvider: { GhosttyConfigReader.resolvedConfig() },
                ghosttyKeybindingsProvider: ghosttyKeybindingsProvider,
                worktreePanesProvider: worktreePanesProvider ?? { [] },
                relayedWorktreePanesProvider:
                    relayedWorktreePanesProvider ?? { [] },
                remoteAttachmentRegistry: remoteAttachmentRegistry,
                displayOwnershipStore: displayOwnershipStore
            ),
            auth: auth,
            bindAddresses: bindAddresses,
            tlsProvider: provider
        )
        bindingServer = true
        defer { bindingServer = false }
        do {
            try await startServer(s)
        } catch {
            // `WEB-1.11`: classify via the shared helper so the
            // Settings pane renders "Port in use" instead of the raw
            // NIO bind error.
            failReconcile(WebServer.isAddressInUse(error) ? .portUnavailable : .error("\(error)"), generation: generation, port: port)
            return
        }
        guard isCurrent(generation: generation, port: port) else {
            await stopServer(s)
            return
        }
        server = s
        status = s.status
        serverHostname = fqdn
        // Bring-up succeeded — clear any armed cold-boot retry and reset the
        // backoff so a future transient failure starts fresh. WEB-1.14.
        retryTask?.cancel()
        retryTask = nil
        retryAttempt = 0

        // Kick off the 24h renewal loop. Fresh bytes were just fetched
        // above — no need for an immediate renewNow here. Re-auto-detect
        // the LocalAPI transport inside the closure so a Tailscale
        // restart that rotates the socket path / TCP port doesn't
        // silently freeze renewal against a stale endpoint.
        let r = WebCertRenewer(
            provider: provider,
            interval: 24 * 60 * 60,
            fetch: {
                let api = try await OffMainIO.run { try TailscaleLocalAPI.autoDetected() }
                let pair = try await api.certPair(for: fqdn)
                return try WebTLSCertFetcher.buildContext(
                    certPEM: pair.cert, keyPEM: pair.key
                )
            }
        )
        r.start()
        renewer = r
    }
}
