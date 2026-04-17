import Foundation
import EspalierKit
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

    private func reconcile() {
        let desired = (enabled: settings.isEnabled, port: settings.port)
        if let last = lastApplied, last == desired { return }
        lastApplied = desired

        server?.stop()
        server = nil
        status = .stopped
        currentURL = nil
        guard desired.enabled else { return }
        do {
            let api = try TailscaleLocalAPI.autoDetected()
            let tailscaleStatus = try runBlocking { try await api.status() }
            var bind = tailscaleStatus.tailscaleIPs
            bind.append("127.0.0.1")
            let ownerLogin = tailscaleStatus.loginName
            let auth = WebServer.AuthPolicy { peerIP in
                guard let api = try? TailscaleLocalAPI.autoDetected() else { return false }
                guard let whois = try? await api.whois(peerIP: peerIP) else { return false }
                return whois.loginName == ownerLogin
            }
            let s = WebServer(
                config: .init(port: desired.port, zmxExecutable: zmxExecutable, zmxDir: zmxDir),
                auth: auth,
                bindAddresses: bind
            )
            try s.start()
            server = s
            status = s.status
            if let host = WebURLComposer.chooseHost(from: tailscaleStatus.tailscaleIPs) {
                currentURL = "http://\(host):\(desired.port)/"
            }
        } catch TailscaleLocalAPI.Error.socketUnreachable {
            status = .disabledNoTailscale
        } catch {
            status = .error("\(error)")
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
