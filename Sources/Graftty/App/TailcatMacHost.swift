import Foundation
import GrafttyHostAgent
import GrafttyProtocol
import GrafttyTailcat

@MainActor
final class TailcatMacHost {
    /// Same account and JSON shape as the listener entry saved before the
    /// listener moved into GrafttyTailcat, so a Mac keeps its address.
    private struct KeychainListenerStore: TailcatListenerStateStore {
        let account: String
        func load() throws -> TailcatListenerState? { try TailcatCredentials.load(TailcatListenerState.self, account: account) }
        func save(_ state: TailcatListenerState) throws { try TailcatCredentials.save(state, account: account) }
    }

    private var task: Task<Void, Never>?
    private var observer: NSObjectProtocol?
    private var configuration: (pool: WebRTCHostAgentPool, account: String)?
    private var generation = UUID()
    private(set) var endpoint: TailcatEndpoint?

    func start(pool: WebRTCHostAgentPool, fingerprint: RemoteIdentityFingerprint) {
        stop()
        configuration = (pool, "listener-" + fingerprint.display)
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
        update()
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        configuration = nil
        update()
    }

    private func update() {
        guard let configuration, TailcatPreference.isEnabled() else {
            generation = UUID()
            endpoint = nil
            task?.cancel()
            task = nil
            return
        }
        guard task == nil else { return }
        let generation = UUID()
        self.generation = generation
        task = Task {
            let ssh = await configuration.pool.makeStreamServer()
            let listener = TailcatSSHListener(store: KeychainListenerStore(account: configuration.account),
                                              port: UInt16(DirectSSHHostServer.defaultPort)) { file in
                let closed = try await ssh.accept(input: file, output: file)
                return { _ = try? await closed.get() }
            }
            do {
                try await listener.run { endpoint in
                    await MainActor.run { if self.generation == generation { self.endpoint = endpoint } }
                }
            } catch {
                if !Task.isCancelled { NSLog("[Graftty] Tailcat listener unavailable") }
            }
            await ssh.close()
            if self.generation == generation {
                endpoint = nil
                self.task = nil
            }
        }
    }
}
