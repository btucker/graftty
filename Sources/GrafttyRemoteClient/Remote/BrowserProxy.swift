import Foundation
import Network

/// A loopback-only, authenticated SOCKS5 listener for one mobile browser sheet.
/// DNS names are passed unchanged to the paired host.
public final class BrowserProxy: @unchecked Sendable {
    public let username = UUID().uuidString
    public let password = UUID().uuidString
    private let queue = DispatchQueue(label: "graftty.browser.proxy")
    private let listener: NWListener
    private let connect: @Sendable (NWConnection, String, Int) async throws -> Void
    private var ready: CheckedContinuation<UInt16, Error>?
    private var connections: [UUID: NWConnection] = [:]
    private var stopped = false

    public init(connect: @escaping @Sendable (NWConnection, String, Int) async throws -> Void) throws {
        self.connect = connect
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    public func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard !self.stopped else { continuation.resume(throwing: CancellationError()); return }
                self.ready = continuation
                self.listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        if let port = self.listener.port {
                            self.ready?.resume(returning: port.rawValue)
                            self.ready = nil
                        }
                    case .failed(let error):
                        self.ready?.resume(throwing: error)
                        self.ready = nil
                        self.stopOnQueue()
                    default: break
                    }
                }
                self.listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                self.listener.start(queue: self.queue)
            }
        }
    }

    public func stop() { queue.async { self.stopOnQueue() } }

    private func stopOnQueue() {
        guard !stopped else { return }
        stopped = true
        ready?.resume(throwing: CancellationError())
        ready = nil
        listener.cancel()
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped, connections.count < 32 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.connections.removeValue(forKey: id)
            default: break
            }
        }
        connection.start(queue: queue)
        // Unauthenticated local clients cannot hold all handshake slots forever.
        let deadline = DispatchWorkItem { connection.cancel() }
        queue.asyncAfter(deadline: .now() + 15, execute: deadline)
        Task {
            var connectRequestReceived = false
            do {
                let greeting = try await Self.read(2, from: connection)
                guard greeting[0] == 5, greeting[1] > 0 else { throw ProxyError.invalidHandshake }
                let methods = try await Self.read(Int(greeting[1]), from: connection)
                guard methods.contains(2) else { throw ProxyError.invalidHandshake }
                try await Self.send(Data([5, 2]), to: connection)
                let auth = try await Self.read(2, from: connection)
                guard auth[0] == 1 else { throw ProxyError.invalidHandshake }
                let user = try await Self.read(Int(auth[1]), from: connection)
                let passwordLength = try await Self.read(1, from: connection)
                let password = try await Self.read(Int(passwordLength[0]), from: connection)
                guard user == Data(self.username.utf8), password == Data(self.password.utf8) else {
                    throw ProxyError.invalidHandshake
                }
                try await Self.send(Data([1, 0]), to: connection)
                let header = try await Self.read(4, from: connection)
                guard header[0] == 5, header[1] == 1, header[2] == 0 else { throw ProxyError.invalidHandshake }
                let host: String
                switch header[3] {
                case 1:
                    host = try await Self.read(4, from: connection).map(String.init).joined(separator: ".")
                case 3:
                    let length = try await Self.read(1, from: connection)
                    let bytes = try await Self.read(Int(length[0]), from: connection)
                    guard let name = String(data: bytes, encoding: .utf8), !name.isEmpty else { throw ProxyError.invalidHandshake }
                    host = name
                case 4:
                    let bytes = try await Self.read(16, from: connection)
                    guard let address = IPv6Address(bytes) else { throw ProxyError.invalidHandshake }
                    host = address.debugDescription
                default: throw ProxyError.invalidHandshake
                }
                let bytes = try await Self.read(2, from: connection)
                let port = Int(bytes[0]) * 256 + Int(bytes[1])
                guard port > 0 else { throw ProxyError.invalidHandshake }
                connectRequestReceived = true
                try await self.connect(connection, host, port)
                deadline.cancel()
            } catch {
                deadline.cancel()
                if connectRequestReceived {
                    // RFC 1928 REP=1: general SOCKS server failure. The
                    // upstream API intentionally hides transport-specific
                    // errors, so this is the most accurate portable reply.
                    try? await Self.send(Data([5, 1, 0, 1, 0, 0, 0, 0, 0, 0]), to: connection)
                }
                connection.cancel()
            }
        }
    }

    public static func send(_ data: Data, to connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    private static func read(_ count: Int, from connection: NWConnection) async throws -> Data {
        guard count > 0 else { throw ProxyError.invalidHandshake }
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, data.count == count { continuation.resume(returning: data) }
                else { continuation.resume(throwing: ProxyError.invalidHandshake) }
            }
        }
    }

    enum ProxyError: Error { case invalidHandshake }
}
