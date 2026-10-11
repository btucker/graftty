#if canImport(UIKit)
import Foundation
import GrafttyRemoteClient
import Network
import WebKit

@MainActor
final class HostBrowserNetwork {
    typealias Connector = @Sendable (NWConnection, String, Int, Data) async throws -> Void

    struct LoopbackEndpoint: Hashable {
        let host: String
        let port: UInt16

        init?(url: URL) {
            guard let host = url.host, BrowserProxy.isLoopbackHost(host),
                  let port = UInt16(exactly: url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)),
                  port > 0 else { return nil }
            self.host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            self.port = port
        }
    }

    private var operation: UUID?
    private var proxyLease: HostBrowserListeners.Lease?
    private var forwarderLease: HostBrowserListeners.Lease?

    func start(url: URL, dataStoreIdentifier: UUID, connect: @escaping Connector) async throws -> WKWebViewConfiguration {
        stop()
        let operation = UUID()
        self.operation = operation
        var ownedLease: HostBrowserListeners.Lease?
        var ownedProxyLease: HostBrowserListeners.Lease?
        do {
            if let endpoint = LoopbackEndpoint(url: url) {
                ownedLease = try await HostBrowserListeners.shared.acquire(.loopback(endpoint), hostID: dataStoreIdentifier, connect: connect)
                try checkCurrent(operation)
                forwarderLease = ownedLease
            }
            let lease = try await HostBrowserListeners.shared.acquire(.socks(dataStoreIdentifier), hostID: dataStoreIdentifier, connect: connect)
            ownedProxyLease = lease
            try checkCurrent(operation)
            proxyLease = lease
            return HostBrowserProxyConfiguration.make(proxy: lease.proxy, port: lease.port, dataStoreIdentifier: dataStoreIdentifier)
        } catch {
            // An older start may resume after a replacement has acquired its listeners.
            // Only release the resources owned by this invocation.
            ownedLease?.release()
            ownedProxyLease?.release()
            if self.operation == operation {
                self.operation = nil
                forwarderLease = nil
                proxyLease = nil
            }
            throw error
        }
    }

    func stop() {
        operation = nil
        forwarderLease?.release()
        forwarderLease = nil
        proxyLease?.release()
        proxyLease = nil
    }

    private func checkCurrent(_ operation: UUID) throws {
        try Task.checkCancellation()
        guard self.operation == operation else { throw CancellationError() }
    }
}

/// Windows viewing the same Mac can share its fixed phone endpoint. A different
/// Mac cannot take over that endpoint while any window is still using it.
@MainActor
private final class HostBrowserListeners {
    static let shared = HostBrowserListeners()

    enum Key: Hashable {
        case loopback(HostBrowserNetwork.LoopbackEndpoint)
        case socks(UUID)
    }

    final class Lease {
        let id = UUID()
        let proxy: BrowserProxy
        var port: UInt16 = 0
        private let releaseAction: (UUID) -> Void
        private var released = false

        init(proxy: BrowserProxy, release: @escaping (UUID) -> Void) {
            self.proxy = proxy
            releaseAction = release
        }
        func release() {
            guard !released else { return }
            released = true
            releaseAction(id)
        }
    }

    private final class Entry {
        let id: UUID
        let hostID: UUID
        let proxy: BrowserProxy
        let start: Task<UInt16, Error>
        var connectors: [(id: UUID, connect: HostBrowserNetwork.Connector)] = []
        var closing: Task<Void, Never>?

        init(id: UUID, hostID: UUID, proxy: BrowserProxy) {
            self.id = id
            self.hostID = hostID
            self.proxy = proxy
            start = Task { try await proxy.start() }
        }
    }

    private var entries: [Key: Entry] = [:]

    func acquire(_ key: Key, hostID: UUID,
                 connect: @escaping HostBrowserNetwork.Connector) async throws -> Lease {
        while let closing = entries[key]?.closing {
            await closing.value
            try Task.checkCancellation()
        }
        let entry: Entry
        if let existing = entries[key] {
            guard existing.hostID == hostID else {
                if case .loopback(let endpoint) = key { throw EndpointInUse(port: endpoint.port) }
                throw CancellationError()
            }
            entry = existing
        } else {
            let id = UUID()
            let proxy: BrowserProxy
            switch key {
            case .loopback(let endpoint):
                proxy = try BrowserProxy(forwardingTo: endpoint.host, port: endpoint.port) { [self] socket, host, port in
                    try await forward(socket, host: host, port: port, reply: Data(), key: key, entryID: id)
                }
            case .socks:
                proxy = try BrowserProxy { [self] socket, host, port in
                    try await forward(socket, host: host, port: port, reply: BrowserProxy.socksSuccessReply, key: key, entryID: id)
                }
            }
            entry = Entry(id: id, hostID: hostID, proxy: proxy)
            entries[key] = entry
        }
        let lease = Lease(proxy: entry.proxy) { [self] id in release(id, key: key, entry: entry) }
        entry.connectors.append((lease.id, connect))
        do {
            lease.port = try await entry.start.value
            try Task.checkCancellation()
            return lease
        } catch {
            lease.release()
            throw error
        }
    }

    private func forward(_ socket: NWConnection, host: String, port: Int, reply: Data, key: Key, entryID: UUID) async throws {
        guard let entry = entries[key], entry.id == entryID else { throw CancellationError() }
        for connector in entry.connectors.reversed() {
            do {
                try await connector.connect(socket, host, port, reply)
                return
            } catch RemoteHostConnection.ConnectionError.notConnected {
                // A background scene can retain its browser lease after its
                // coordinator closes. This error precedes any socket writes.
                continue
            } catch DirectSSHHostConnection.ConnectionError.notConnected {
                continue
            }
        }
        throw RemoteHostConnection.ConnectionError.notConnected
    }

    private func release(_ id: UUID, key: Key, entry: Entry) {
        guard let index = entry.connectors.firstIndex(where: { $0.id == id }) else { return }
        entry.connectors.remove(at: index)
        guard entry.connectors.isEmpty else { return }
        entry.closing = Task {
            await entry.proxy.stopAndWait()
            if entries[key] === entry { entries.removeValue(forKey: key) }
        }
    }

    private struct EndpointInUse: LocalizedError {
        let port: UInt16
        var errorDescription: String? {
            "Port \(port) is already open through another Mac. Close that browser and try again."
        }
    }
}
#endif
