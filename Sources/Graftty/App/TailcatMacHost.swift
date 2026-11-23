import Foundation
import GrafttyHostAgent
import GrafttyProtocol
import GrafttyTailcat

@MainActor
final class TailcatMacHost {
    private struct SavedHost: Codable {
        let identity: TailcatServerIdentity
        let address: String
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
            do {
                try Task.checkCancellation()
                let saved = try TailcatCredentials.load(SavedHost.self, account: configuration.account)
                let identity = try saved?.identity ?? TailcatServerIdentity.generate()
                let peer = try TailcatPeer.server(identity: identity, previousAddress: saved?.address)
                do {
                    let port = UInt16(DirectSSHHostServer.defaultPort)
                    let listener = try await peer.listen(port: port)
                    let address = try await peer.address()
                    try Task.checkCancellation()
                    try TailcatCredentials.save(SavedHost(identity: identity, address: address), account: configuration.account)
                    endpoint = TailcatEndpoint(address: address, port: port)
                    while !Task.isCancelled {
                        let pipe = try await listener.accept()
                        do {
                            let closed = try await ssh.accept(input: pipe.file, output: pipe.file)
                            try pipe.file.close()
                            Task {
                                _ = try? await closed.get()
                                await pipe.close()
                            }
                        } catch { await pipe.close() }
                    }
                } catch {
                    await peer.close()
                    throw error
                }
                await peer.close()
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
