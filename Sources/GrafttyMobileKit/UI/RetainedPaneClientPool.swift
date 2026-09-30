import Foundation

/// Keeps recently visited interactive connections alive between compact routes.
@MainActor
final class RetainedPaneClientPool<Client: PanePreviewClienting> {
    struct Key: Hashable {
        let hostID: UUID
        let sessionName: String
    }

    private let capacity: Int
    private var clients: [Key: Client] = [:]
    private var recency: [Key] = []

    init(capacity: Int = 4) { self.capacity = max(1, capacity) }

    func cached(_ key: Key) -> Client? { clients[key] }

    func acquire(_ key: Key, makeClient: () -> Client) -> Client {
        recency.removeAll { $0 == key }
        recency.append(key)
        if let client = clients[key] {
            client.resume()
            return client
        }
        let client = makeClient()
        clients[key] = client
        client.start()
        while clients.count > capacity, let oldest = recency.first { remove(oldest) }
        return client
    }

    func remove(_ key: Key) {
        clients.removeValue(forKey: key)?.stop()
        recency.removeAll { $0 == key }
    }

    func stopAll() {
        for client in clients.values { client.stop() }
        clients.removeAll()
        recency.removeAll()
    }

    func suspendAll() {
        for client in clients.values { client.suspend() }
    }
}
