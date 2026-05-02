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

    /// Last `(isEnabled, port)` tuple we reconciled against. Used to suppress
    /// no-op reconciles — `objectWillChange` on `@AppStorage` fires on every
    /// property write, including ones that don't affect our server.
    private var lastApplied: (enabled: Bool, port: Int)?

    init(settings: WebAccessSettings, zmxExecutable: URL, zmxDir: URL) {
        self.settings = settings
        self.zmxExecutable = zmxExecutable
        self.zmxDir = zmxDir
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
    }

    private func reconcile() {
        let desired = (enabled: settings.isEnabled, port: settings.port)
        if let last = lastApplied, last == desired { return }
        lastApplied = desired

        reconcileTask?.cancel()
        reconcileTask = nil
        renewer?.stop()
        renewer = nil
        server?.stop()
        server = nil
        status = .stopped
        serverHostname = nil
        guard desired.enabled else { return }
        // Validate port BEFORE reaching into Tailscale / NIO. An
        // out-of-range `WebAccessSettings.port` (e.g. the user typed
        // "99999" into the Settings TextField, which has no clamp of
        // its own) otherwise surfaces as `NIOBindError(port: 99999, …)`
        // in the status row — opaque to the user. `WEB-1.5`.
        guard WebServer.Config.isValidListenablePort(desired.port) else {
            status = .error("Port must be 0–65535 (got \(desired.port))")
            return
        }
        let api: TailscaleLocalAPI
        let tailscaleStatus: TailscaleLocalAPI.Status
        do {
            api = try TailscaleLocalAPI.autoDetected()
            tailscaleStatus = try runBlocking { try await api.status() }
        } catch TailscaleLocalAPI.Error.socketUnreachable {
            status = .tailscaleUnavailable
            return
        } catch {
            status = .error("\(error)")
            return
        }
        guard let fqdn = tailscaleStatus.dnsName else {
            // Clear lastApplied so the next settings pulse re-probes;
            // otherwise the user has to toggle web access off + on to
            // recover after enabling MagicDNS in the admin console.
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
        let s = WebServer(
            config: .init(
                port: port,
                zmxExecutable: zmxExecutable,
                zmxDir: zmxDir,
                sessionsProvider: sessionsProvider,
                sessionWorktreeProvider: sessionWorktreeProvider,
                reposProvider: repos,
                worktreeCreator: creator,
                ghosttyConfigProvider: { GhosttyConfigReader.resolvedConfig() },
                worktreePanesProvider: worktreePanesProvider ?? { [] }
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
