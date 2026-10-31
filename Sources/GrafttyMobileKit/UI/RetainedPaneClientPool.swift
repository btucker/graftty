import Foundation
import Observation

/// Mounted panes stay alive; the cache bounds recently hidden connections.
@Observable
@MainActor
final class RetainedPaneClientPool<Client: PanePreviewClienting> {
    struct Key: Hashable {
        let hostID: UUID
        let sessionName: String
    }

    private let capacity: Int
    private var clients: [Key: Client] = [:]
    private var recency: [Key] = []
    private var attachments: [Key: Set<UUID>] = [:]

    init(capacity: Int = 4) { self.capacity = max(1, capacity) }

    func cached(_ key: Key) -> Client? { clients[key] }

    func attach(_ key: Key, owner: UUID) { attachments[key, default: []].insert(owner) }

    func detach(_ key: Key, owner: UUID) {
        attachments[key]?.remove(owner)
        if attachments[key]?.isEmpty == true { attachments[key] = nil }
        trim()
    }

    /// A selected iPad workspace retains hidden tabs as well as mounted panes.
    /// Releasing the scope restores the ordinary recent-pane cache limit.
    func retainWorkspace(_ keys: Set<Key>, owner: UUID) {
        for key in Array(attachments.keys) where !keys.contains(key) {
            attachments[key]?.remove(owner)
            if attachments[key]?.isEmpty == true { attachments[key] = nil }
        }
        for key in keys { attach(key, owner: owner) }
        trim()
    }

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
        trim()
        return client
    }

    private func trim() {
        let protectedCount = clients.keys.filter { attachments[$0] != nil }.count
        while clients.count > max(capacity, protectedCount),
              let oldest = recency.first(where: { attachments[$0] == nil }) {
            remove(oldest)
        }
    }

    func remove(_ key: Key) {
        clients.removeValue(forKey: key)?.stop()
        recency.removeAll { $0 == key }
        attachments[key] = nil
    }

    func stopAll() {
        for client in clients.values { client.stop() }
        clients.removeAll()
        recency.removeAll()
        attachments.removeAll()
    }

    func suspendAll() {
        for client in clients.values { client.suspend() }
    }
}
