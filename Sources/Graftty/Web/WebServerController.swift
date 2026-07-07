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
    /// In-flight task running `certPair` + server bring-up off the
    /// MainActor. Cancelled on stop()/re-reconcile, with each post-await
    /// step gated on `Task.isCancelled` so a stale completion can't
    /// race a fresh status onto the pane. WEB-8.6.
    private var reconcileTask: Task<Void, Never>?
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

    /// Supplies `GET /sessions` with the current running sessions
    /// (`WEB-5.4`). Injected by `GrafttyApp` after `appState` + the
    /// `terminalManager`'s session-name function exist. Nil before
    /// injection (default-empty provider is baked into `WebServer.Config`).
    private var sessionsProvider: (@Sendable () async -> [SessionInfo])?
    private var sessionWorktreeProvider: (@Sendable (String) async -> String?)?
    private var worktreePanesProvider: (@Sendable () async -> [WorktreePanes])?
    /// Supplies `GET /repos` (`WEB-7.1`). Same injection timing as
    /// `sessionsProvider` — both read from `AppState`.
    private var reposProvider: (@Sendable () async -> [WebServer.RepoInfo])?
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
    /// Drives `POST /v1/rtc/offer`. Nil (default) causes the endpoint
    /// to respond `503 service unavailable`. Injected by `GrafttyApp`
    /// once `WebRTCHostAgent` is constructed.
    private var signalingHandler: (@Sendable (SignalingOffer) async -> WebServer.SignalingHandlerOutcome)?
    /// TERM-11.5: counts remote clients per zmx session so Mac panes
    /// know a remote viewer is attached. Nil before injection — the
    /// `WebServer.Config` default disables tracking. Injected by
    /// `GrafttyApp.startup()` alongside the other providers.
    private var remoteAttachmentRegistry: RemoteAttachmentRegistry?
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
        displayOwnershipStore: SessionDisplayOwnershipStore = SessionDisplayOwnershipStore()
    ) {
        self.settings = settings
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
        reconcileTask?.cancel()
        reconcileTask = nil
        retryTask?.cancel()
        retryTask = nil
        retryAttempt = 0
        renewer?.stop()
        renewer = nil
        server?.stop()
        server = nil
        status = .stopped
        serverHostname = nil
        lastApplied = nil
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

    /// Install the provider used for `GET /repos`. Same contract as
    /// `setSessionsProvider`.
    func setReposProvider(
        _ provider: @escaping @Sendable () async -> [WebServer.RepoInfo]
    ) {
        reposProvider = provider
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

    /// Install the signaling handler for `POST /v1/rtc/offer`. Pre-injection
    /// requests get `503 service unavailable`. Wired in `GrafttyApp.startup()`
    /// once `WebRTCHostAgent` is constructed with its production params.
    func setSignalingHandler(
        _ handler: @escaping @Sendable (SignalingOffer) async -> WebServer.SignalingHandlerOutcome
    ) {
        signalingHandler = handler
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

    /// Force-rebuild the running server so a new provider closure is
    /// captured into a fresh `WebServer.Config`. No-ops when the server
    /// isn't running yet — an in-flight `reconcileTask` reads providers
    /// off `self` at WebServer-build time and will pick up the latest
    /// closure on completion. Cancelling the in-flight task instead
    /// would stack a parallel cert mint, since `Darwin.recv` doesn't
    /// honor Task cancellation and the original cooperator-thread
    /// `recv` finishes anyway.
    private func rebuildIfRunning() {
        guard server != nil else { return }
        lastApplied = nil
        reconcile()
    }

    /// Record a terminal state for this reconcile attempt. Gated on
    /// `Task.isCancelled` so a slow `certPair` that throws on a fd
    /// closed by a re-reconcile doesn't overwrite the freshly-set
    /// status from the new attempt.
    private func failReconcile(_ s: WebServer.Status) {
        guard !Task.isCancelled else { return }
        status = s
        lastApplied = nil
        scheduleRetry(after: s)
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
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            // Detach our own handle BEFORE reconcile(): its top-of-function
            // `retryTask?.cancel()` would otherwise cancel *this* running Task,
            // and that self-cancel poisons `Task.isCancelled` for the rest of
            // the synchronous reconcile — so a `failReconcile(.magicDNSDisabled)`
            // would hit its `guard !Task.isCancelled` and no-op, silently killing
            // the magicDNS retry chain and wedging `lastApplied`. WEB-1.14.
            self.retryTask = nil
            // The desired (enabled, port) tuple is unchanged from the failed
            // attempt, so clear `lastApplied` too or reconcile()'s no-op guard
            // would early-return and the retry would do nothing.
            self.lastApplied = nil
            self.reconcile()
        }
    }

    private func reconcile() {
        let desired = (enabled: settings.isEnabled, port: settings.port)
        if let last = lastApplied, last == desired { return }
        lastApplied = desired

        // A fresh attempt supersedes any pending retry; scheduleRetry will
        // re-arm one (with the incremented backoff) if this attempt also
        // fails transiently. WEB-1.14.
        retryTask?.cancel()
        retryTask = nil
        reconcileTask?.cancel()
        reconcileTask = nil
        renewer?.stop()
        renewer = nil
        server?.stop()
        server = nil
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
        let api: TailscaleLocalAPI
        let tailscaleStatus: TailscaleLocalAPI.Status
        do {
            api = try TailscaleLocalAPI.autoDetected()
            tailscaleStatus = try runBlocking { try await api.status() }
        } catch TailscaleLocalAPI.Error.socketUnreachable {
            // Cold-boot race: `tailscaled` hasn't published its LocalAPI socket
            // yet. failReconcile clears lastApplied + arms a backoff retry so we
            // self-heal without waiting for the user to toggle Web Access —
            // routed through the same helper as the MagicDNS branch below so both
            // transient failures recover identically. WEB-1.14.
            failReconcile(.tailscaleUnavailable)
            return
        } catch {
            status = .error("\(error)")
            retryAttempt = 0  // terminal status ends the retry campaign. WEB-1.14
            return
        }
        guard let fqdn = tailscaleStatus.dnsName else {
            // MagicDNS name not yet published — transient at cold boot, or the
            // user just enabled MagicDNS in the admin console. failReconcile
            // clears lastApplied and arms a backoff retry (WEB-1.14), so the
            // server self-heals without a manual Web Access toggle.
            failReconcile(.magicDNSDisabled)
            return
        }

        status = .provisioningCert
        let bind = tailscaleStatus.tailscaleIPs
        let ownerLogin = tailscaleStatus.loginName
        let port = desired.port
        reconcileTask = Task { [weak self] in
            await self?.completeReconcile(
                api: api,
                fqdn: fqdn,
                bindAddresses: bind,
                ownerLogin: ownerLogin,
                port: port
            )
        }
    }

    private func completeReconcile(
        api: TailscaleLocalAPI,
        fqdn: String,
        bindAddresses: [String],
        ownerLogin: String,
        port: Int
    ) async {
        let pair: (cert: Data, key: Data)
        do {
            pair = try await api.certPair(for: fqdn)
        } catch is CancellationError {
            return
        } catch TailscaleLocalAPI.Error.httpsCertsDisabled {
            failReconcile(.httpsCertsNotEnabled)
            return
        } catch {
            failReconcile(.certFetchFailed("\(error)"))
            return
        }
        if Task.isCancelled { return }

        let provider: WebTLSContextProvider
        do {
            provider = WebTLSContextProvider(
                initial: try WebTLSCertFetcher.buildContext(
                    certPEM: pair.cert, keyPEM: pair.key
                )
            )
        } catch {
            failReconcile(.certFetchFailed("\(error)"))
            return
        }

        let auth = WebServer.AuthPolicy { [api] peerIP in
            guard let whois = try? await api.whois(peerIP: peerIP) else { return false }
            return whois.loginName == ownerLogin
        }
        let sessionsProvider = self.sessionsProvider ?? { [] }
        let sessionWorktreeProvider = self.sessionWorktreeProvider ?? { _ in nil }
        let repos = reposProvider ?? { [] }
        let creator = worktreeCreator
        let puller = defaultBranchPuller
        let remover = worktreeRemover
        let signalingHandler = self.signalingHandler
        let s = WebServer(
            config: .init(
                port: port,
                zmxExecutable: zmxExecutable,
                zmxDir: zmxDir,
                sessionsProvider: sessionsProvider,
                sessionWorktreeProvider: sessionWorktreeProvider,
                reposProvider: repos,
                worktreeCreator: creator,
                defaultBranchPuller: puller,
                worktreeRemover: remover,
                ghosttyConfigProvider: { GhosttyConfigReader.resolvedConfig() },
                worktreePanesProvider: worktreePanesProvider ?? { [] },
                signalingHandler: signalingHandler,
                remoteAttachmentRegistry: remoteAttachmentRegistry,
                displayOwnershipStore: displayOwnershipStore
            ),
            auth: auth,
            bindAddresses: bindAddresses,
            tlsProvider: provider
        )
        do {
            try s.start()
        } catch {
            // `WEB-1.11`: classify via the shared helper so the
            // Settings pane renders "Port in use" instead of the raw
            // NIO bind error.
            failReconcile(WebServer.isAddressInUse(error) ? .portUnavailable : .error("\(error)"))
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
                let api = try TailscaleLocalAPI.autoDetected()
                let pair = try await api.certPair(for: fqdn)
                return try WebTLSCertFetcher.buildContext(
                    certPEM: pair.cert, keyPEM: pair.key
                )
            }
        )
        r.start()
        renewer = r
    }

    /// Bridge async to sync for the one-shot Tailscale `status()` at reconcile
    /// time. Runs on a detached Task so we don't deadlock the MainActor.
    private func runBlocking<T>(_ op: @escaping @Sendable () async throws -> T) throws -> T where T: Sendable {
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<T, Swift.Error> = .failure(CancellationError())
        Task.detached {
            do { result = .success(try await op()) }
            catch { result = .failure(error) }
            sem.signal()
        }
        sem.wait()
        return try result.get()
    }
}
