import Foundation
import GrafttyKit
import Combine

/// Owns the `WebServer` lifetime at app scope. Subscribes to
/// `WebAccessSettings` and starts/stops the server accordingly.
@MainActor
final class WebServerController: ObservableObject {

    @Published private(set) var status: WebServer.Status = .stopped
    @Published private(set) var currentURL: String? = nil

    private var server: WebServer?
    private let settings: WebAccessSettings
    private let zmxExecutable: URL
    private let zmxDir: URL
    private var cancellables = Set<AnyCancellable>()

    /// Supplies `GET /sessions` with the current running sessions
    /// (`WEB-5.4`). Injected by `GrafttyApp` after `appState` + the
    /// `terminalManager`'s session-name function exist. Nil before
    /// injection (default-empty provider is baked into `WebServer.Config`).
    private var sessionsProvider: (@Sendable () async -> [WebServer.SessionInfo])?
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
        server?.stop()
        server = nil
        status = .stopped
        currentURL = nil
        lastApplied = nil
    }

    /// Install (or replace) the provider used for `GET /sessions`. Called
    /// from `GrafttyApp.startup()` once `appState` is available. Forces
    /// a reconcile so a running server picks up the new provider.
    func setSessionsProvider(
        _ provider: @escaping @Sendable () async -> [WebServer.SessionInfo]
    ) {
        sessionsProvider = provider
        lastApplied = nil  // force reconcile to rebuild the Config
        reconcile()
    }

    /// Install the provider used for `GET /repos`. Same contract as
    /// `setSessionsProvider`; see there for the force-reconcile
    /// rationale.
    func setReposProvider(
        _ provider: @escaping @Sendable () async -> [WebServer.RepoInfo]
    ) {
        reposProvider = provider
        lastApplied = nil
        reconcile()
    }

    /// Install the creator used for `POST /worktrees`. Must be wired
    /// before the endpoint is useful; prior to injection requests get
    /// `503 service unavailable`.
    func setWorktreeCreator(
        _ creator: @escaping @Sendable (WebServer.CreateWorktreeRequest) async -> WebServer.CreateWorktreeOutcome
    ) {
        worktreeCreator = creator
        lastApplied = nil
        reconcile()
    }

    private func reconcile() {
        let desired = (enabled: settings.isEnabled, port: settings.port)
        if let last = lastApplied, last == desired { return }
        lastApplied = desired

        server?.stop()
        server = nil
        status = .stopped
        currentURL = nil
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
        do {
            let api = try TailscaleLocalAPI.autoDetected()
            let tailscaleStatus = try runBlocking { try await api.status() }
            var bind = tailscaleStatus.tailscaleIPs
            bind.append("127.0.0.1")
            let ownerLogin = tailscaleStatus.loginName
            let auth = WebServer.AuthPolicy { [api] peerIP in
                guard let whois = try? await api.whois(peerIP: peerIP) else { return false }
                return whois.loginName == ownerLogin
            }.allowingLoopback()
            let provider = sessionsProvider ?? { [] }
            let repos = reposProvider ?? { [] }
            let creator = worktreeCreator
            let s = WebServer(
                config: .init(
                    port: desired.port,
                    zmxExecutable: zmxExecutable,
                    zmxDir: zmxDir,
                    sessionsProvider: provider,
                    reposProvider: repos,
                    worktreeCreator: creator
                ),
                auth: auth,
                bindAddresses: bind
            )
            try s.start()
            server = s
            status = s.status
            if let host = WebURLComposer.chooseHost(from: tailscaleStatus.tailscaleIPs) {
                currentURL = WebURLComposer.baseURL(host: host, port: desired.port)
            }
        } catch TailscaleLocalAPI.Error.socketUnreachable {
            status = .disabledNoTailscale
        } catch {
            // `WEB-1.11`: classify via the shared helper so the
            // Settings pane renders "Port in use" instead of the raw
            // NIO bind error.
            if WebServer.isAddressInUse(error) {
                status = .portUnavailable
            } else {
                status = .error("\(error)")
            }
        }
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
