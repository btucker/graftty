#if canImport(UIKit)
import Foundation
import GrafttyProtocol
import GrafttyRemoteClient
import Network
import WebKit

@MainActor
final class HostBrowserNetwork {
    typealias Connector = @Sendable (NWConnection, String, Int, Data) async throws -> Void

    struct LoopbackEndpoint: Hashable {
        let host: String
        let port: UInt16
        let destinationHost: String

        init?(url: URL, destinationHost: String? = nil) {
            guard let value = url.host, let host = WorktreeAuthenticationURL.canonicalLoopbackHost(value),
                  let port = UInt16(exactly: url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)),
                  port > 0 else { return nil }
            self.host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            self.port = port
            guard let destinationHost = WorktreeAuthenticationURL.canonicalLoopbackHost(destinationHost ?? host) else { return nil }
            self.destinationHost = destinationHost
        }

        private init(host: String, port: UInt16, destinationHost: String) {
            self.host = host
            self.port = port
            self.destinationHost = destinationHost
        }

        var localBindings: [Self] {
            guard host == "localhost" else { return [self] }
            // WebKit may resolve localhost to either address family. A
            // hostname-bound NWListener alone does not cover both reliably.
            return ["127.0.0.1", "::1"].map {
                Self(host: $0, port: port, destinationHost: destinationHost)
            }
        }
    }

    private var operation: UUID?
    private var proxyLease: HostBrowserListeners.Lease?
    private var forwarderLeases: [HostBrowserListeners.Lease] = []

    /// Fixed loopback leases for native Safari. Public pages use the phone's network.
    func startLocalPage(url: URL, hostID: UUID, callbackHost: String? = nil,
                        connect: @escaping Connector) async throws {
        _ = try await startForwarders(url: url, hostID: hostID, callbackHost: callbackHost, connect: connect)
    }

    func start(url: URL, dataStoreIdentifier: UUID, callbackHost: String? = nil,
               connect: @escaping Connector) async throws -> WKWebViewConfiguration {
        let operation = try await startForwarders(url: url, hostID: dataStoreIdentifier, callbackHost: callbackHost, connect: connect)
        if callbackHost != nil {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            return configuration
        }
        var ownedProxyLease: HostBrowserListeners.Lease?
        do {
            let lease = try await HostBrowserListeners.shared.acquire(.socks(dataStoreIdentifier), hostID: dataStoreIdentifier, connect: connect)
            ownedProxyLease = lease
            try checkCurrent(operation)
            proxyLease = lease
            return HostBrowserProxyConfiguration.make(proxy: lease.proxy, port: lease.port, dataStoreIdentifier: dataStoreIdentifier)
        } catch {
            ownedProxyLease?.release()
            if self.operation == operation { stop() }
            throw error
        }
    }

    private func startForwarders(url: URL, hostID: UUID, callbackHost: String?,
                                 connect: @escaping Connector) async throws -> UUID {
        // An obsolete invocation must not release a replacement's live leases.
        try Task.checkCancellation()
        stop()
        let operation = UUID()
        self.operation = operation
        var ownedLeases: [HostBrowserListeners.Lease] = []
        do {
            var endpoints: [LoopbackEndpoint] = []
            if callbackHost == nil, let endpoint = LoopbackEndpoint(url: url) { endpoints += endpoint.localBindings }
            if let authentication = WorktreeAuthenticationURL(url: url),
               let endpoint = LoopbackEndpoint(url: authentication.callbackURL, destinationHost: callbackHost) {
                endpoints += endpoint.localBindings.filter { !endpoints.contains($0) }
            }
            if callbackHost != nil, WorktreeAuthenticationURL(url: url) == nil || endpoints.isEmpty {
                throw InvalidAuthentication()
            }
            for endpoint in endpoints {
                let lease = try await HostBrowserListeners.shared.acquire(.loopback(endpoint), hostID: hostID, connect: connect)
                ownedLeases.append(lease)
                try checkCurrent(operation)
                forwarderLeases = ownedLeases
            }
            try checkCurrent(operation)
            return operation
        } catch {
            // Release only this invocation's leases after an asynchronous replacement.
            ownedLeases.forEach { $0.release() }
            if self.operation == operation { self.operation = nil; forwarderLeases = [] }
            throw error
        }
    }

    func stop() {
        operation = nil
        forwarderLeases.forEach { $0.release() }
        forwarderLeases = []
        proxyLease?.release()
        proxyLease = nil
    }

    private func checkCurrent(_ operation: UUID) throws {
        try Task.checkCancellation()
        guard self.operation == operation else { throw CancellationError() }
    }

    private struct InvalidAuthentication: LocalizedError {
        var errorDescription: String? { "This sign-in callback is invalid." }
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

        // The local socket identifies a lease. The remote destination is a
        // compatibility check, not a second socket that can bind this address.
        static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.loopback(let lhs), .loopback(let rhs)):
                lhs.host == rhs.host && lhs.port == rhs.port
            case (.socks(let lhs), .socks(let rhs)):
                lhs == rhs
            default:
                false
            }
        }

        func hash(into hasher: inout Hasher) {
            switch self {
            case .loopback(let endpoint):
                hasher.combine(0)
                hasher.combine(endpoint.host)
                hasher.combine(endpoint.port)
            case .socks(let id):
                hasher.combine(1)
                hasher.combine(id)
            }
        }

        var destinationHost: String? {
            if case .loopback(let endpoint) = self { return endpoint.destinationHost }
            return nil
        }
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
        let destinationHost: String?
        let proxy: BrowserProxy
        let start: Task<UInt16, Error>
        var connectors: [(id: UUID, connect: HostBrowserNetwork.Connector)] = []
        var closing: Task<Void, Never>?

        init(id: UUID, hostID: UUID, destinationHost: String?, proxy: BrowserProxy) {
            self.id = id
            self.hostID = hostID
            self.destinationHost = destinationHost
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
            guard existing.hostID == hostID, existing.destinationHost == key.destinationHost else {
                if case .loopback(let endpoint) = key { throw EndpointInUse(port: endpoint.port) }
                throw CancellationError()
            }
            entry = existing
        } else {
            let id = UUID()
            let proxy: BrowserProxy
            switch key {
            case .loopback(let endpoint):
                proxy = try BrowserProxy(forwardingTo: endpoint.destinationHost, port: endpoint.port, localHost: endpoint.host) { [self] socket, host, port in
                    try await forward(socket, host: host, port: port, reply: Data(), key: key, entryID: id)
                }
            case .socks:
                proxy = try BrowserProxy { [self] socket, host, port in
                    try await forward(socket, host: host, port: port, reply: BrowserProxy.socksSuccessReply, key: key, entryID: id)
                }
            }
            entry = Entry(id: id, hostID: hostID, destinationHost: key.destinationHost, proxy: proxy)
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
            "Port \(port) is already open through another Mac or destination. Close that browser and try again."
        }
    }
}
#endif
