import Foundation
import GrafttyProtocol
import MCP

public struct MCPProxyEndpoint: Sendable {
    public let transport: any Transport
    public let stop: @Sendable () async -> Void
    public init(transport: any Transport, stop: @escaping @Sendable () async -> Void = {}) {
        self.transport = transport; self.stop = stop
    }
    public func close() async { await transport.disconnect(); await stop() }
}

/// One broker belongs to one authenticated SSH channel. Session IDs cannot be
/// reopened or moved to a new connection. A failed send is never retried here.
public actor MCPProxyBroker {
    public typealias Authorize = @Sendable (MCPProxyScope, RemoteMacConnectionSummary.ID) throws -> MCPProxyPolicy.Server
    public typealias Factory = @Sendable (MCPProxyPolicy.Server) async throws -> MCPProxyEndpoint
    public static let maximumMessageBytes = 256 * 1024
    public static let maximumSessions = 32
    private struct Session {
        let scope: MCPProxyScope
        let definition: MCPProxyPolicy.Server
        var endpoint: MCPProxyEndpoint?
        var reader: Task<Void, Never>?
        var monitor: Task<Void, Never>?
        var sends: [UUID: Task<Void, Never>] = [:]
        var lastSend: Task<Void, Never>?
        var sendingBytes = 0
        var budget = MCPMessageBudget()
        var queued: [Data] = []
        var queueBytes = 0
        var error: MCPProxyError?
        var lastActivity = ContinuousClock.now
    }
    private let peer: RemoteMacConnectionSummary.ID
    private let authorize: Authorize
    private let makeTransport: Factory
    private var sessions: [UUID: Session] = [:]
    private var closed = false
    public var isClosed: Bool { closed }

    public init(peer: RemoteMacConnectionSummary.ID, authorize: @escaping Authorize,
                makeTransport: @escaping Factory = { try await MCPProxyUpstream.open($0) }) {
        // The caller binds authorize to this authenticated peer, never to a
        // worker-supplied identity. This broker is discarded on disconnect.
        self.peer = peer; self.authorize = authorize; self.makeTransport = makeTransport
    }

    public func handle(_ bytes: Data) async -> Data {
        let response: MCPProxyResponse
        if bytes.count <= 2 * Self.maximumMessageBytes,
           let request = try? JSONDecoder().decode(MCPProxyRequest.self, from: bytes) {
            response = await handle(request)
        } else { response = .error(.invalidRequest) }
        return (try? JSONEncoder().encode(response)) ?? Data()
    }

    public func handle(_ request: MCPProxyRequest) async -> MCPProxyResponse {
        guard !closed, !Task.isCancelled else { return .error(.unavailable) }
        switch request {
        case .open(let id, let scope):
            guard sessions[id] == nil else { return .error(.invalidRequest) }
            guard sessions.count < 1024, sessions.values.filter({ $0.error == nil }).count < Self.maximumSessions else { return .error(.overloaded) }
            let definition: MCPProxyPolicy.Server
            do { definition = try authorize(scope, peer) } catch { return .error(.unauthorized) }
            sessions[id] = Session(scope: scope, definition: definition)
            do {
                let endpoint = try await makeTransport(definition)
                guard !closed, sessions[id]?.error == nil, !Task.isCancelled,
                      (try? authorize(scope, peer)) == definition else {
                    await endpoint.close(); await fail(id, .unauthorized); return .error(.unauthorized)
                }
                sessions[id]?.endpoint = endpoint
                try await endpoint.transport.connect()
                guard !closed, sessions[id]?.error == nil, !Task.isCancelled,
                      (try? authorize(scope, peer)) == definition else {
                    await fail(id, .unauthorized); return .error(.unauthorized)
                }
                sessions[id]?.reader = Task { [weak self] in
                    do {
                        for try await message in await endpoint.transport.receive() {
                            guard !Task.isCancelled else { return }
                            await self?.enqueue(message, id: id)
                        }
                    } catch { }
                    await self?.fail(id, .outcomeUnknown)
                }
                sessions[id]?.monitor = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                        guard await self?.check(id) == true else { return }
                    }
                }
                return .opened
            } catch { await fail(id, .unavailable); return .error(.unavailable) }
        case .close(let id):
            await fail(id, .unavailable)
            return .closed
        case .send(let id, let message):
            guard await check(id), let session = sessions[id], let endpoint = session.endpoint else { return failure(id) }
            guard Self.validMessage(message) else { await fail(id, .invalidRequest); return .error(.invalidRequest) }
            guard session.sends.count < 16, session.sendingBytes + message.count <= 2 * Self.maximumMessageBytes else {
                await fail(id, .overloaded); return .error(.overloaded)
            }
            do { try sessions[id]?.budget.record(message, from: .worker) }
            catch let error as MCPProxyError { await fail(id, error); return .error(error) }
            catch { await fail(id, .invalidRequest); return .error(.invalidRequest) }
            sessions[id]?.lastActivity = .now
            let sendID = UUID()
            sessions[id]?.sendingBytes += message.count
            let previous = session.lastSend
            let task = Task { [weak self] in
                await previous?.value
                guard !Task.isCancelled, await self?.check(id) == true else {
                    await self?.sent(id, sendID: sendID, bytes: message.count); return
                }
                do { try await endpoint.transport.send(message) }
                catch { await self?.fail(id, .outcomeUnknown) }
                await self?.sent(id, sendID: sendID, bytes: message.count)
            }
            sessions[id]?.sends[sendID] = task
            sessions[id]?.lastSend = task
            return .accepted
        case .receive(let id):
            guard await check(id), let session = sessions[id] else { return failure(id) }
            sessions[id]?.queued = []; sessions[id]?.queueBytes = 0
            return .messages(session.queued)
        }
    }

    public func close() async {
        closed = true
        for id in sessions.keys { await fail(id, .outcomeUnknown) }
    }

    private func failure(_ id: UUID) -> MCPProxyResponse { .error(sessions[id]?.error ?? .unavailable) }
    private func check(_ id: UUID) async -> Bool {
        guard !closed, let session = sessions[id], session.error == nil else { return false }
        guard (try? authorize(session.scope, peer)) == session.definition else { await fail(id, .unauthorized); return false }
        guard !session.budget.hasExpired(), session.lastActivity.duration(to: .now) < .seconds(3600) else { await fail(id, .outcomeUnknown); return false }
        return true
    }
    private func enqueue(_ message: Data, id: UUID) async {
        guard await check(id) else { return }
        guard Self.validMessage(message) else { await fail(id, .invalidRequest); return }
        guard let session = sessions[id], session.queued.count < 32,
              session.queueBytes + message.count <= Self.maximumMessageBytes else { await fail(id, .overloaded); return }
        do { try sessions[id]?.budget.record(message, from: .parent) }
        catch let error as MCPProxyError { await fail(id, error); return }
        catch { await fail(id, .invalidRequest); return }
        sessions[id]?.queued.append(message); sessions[id]?.queueBytes += message.count
    }
    private func sent(_ id: UUID, sendID: UUID, bytes: Int) {
        guard sessions[id]?.sends.removeValue(forKey: sendID) != nil else { return }
        sessions[id]?.sendingBytes -= bytes
    }
    private func fail(_ id: UUID, _ error: MCPProxyError) async {
        guard let session = sessions[id], session.error == nil else { return }
        sessions[id]?.error = error
        sessions[id]?.reader = nil; sessions[id]?.monitor = nil; sessions[id]?.endpoint = nil
        sessions[id]?.sends = [:]; sessions[id]?.lastSend = nil; sessions[id]?.sendingBytes = 0; sessions[id]?.queued = []; sessions[id]?.queueBytes = 0
        session.reader?.cancel(); session.monitor?.cancel()
        session.sends.values.forEach { $0.cancel() }
        await session.endpoint?.close()
    }
    static func validMessage(_ data: Data) -> Bool {
        guard data.count <= maximumMessageBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["jsonrpc"] as? String == "2.0" else { return false }
        return object["method"] is String || object["result"] != nil || object["error"] != nil
    }
}
