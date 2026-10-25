import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyKit
import MCP

@Suite struct MCPProxyTests {
    private func fixture() throws -> (MCPProxyPolicy, MCPProxyScope, RemoteMacConnectionSummary.ID) {
        let peer = RemoteMacConnectionSummary.ID(deviceID: .init(value: "worker"),
            fingerprint: RemoteIdentityFingerprint(of: try RemoteIdentityPublicKey(rawRepresentation: Data(repeating: 7, count: 32))))
        let scope = MCPProxyScope(grantID: UUID(), generation: 1, repositoryID: UUID(), worktreePath: "/work/project", serverID: "fixture")
        let policy = MCPProxyPolicy(servers: ["fixture": .stdio(executable: "/usr/bin/true", arguments: [], environmentKeys: [])],
            grants: [.init(scope: scope, host: peer, expiresAt: Date().addingTimeInterval(60))])
        return (policy, scope, peer)
    }

    @Test("@spec REMOTE-30.2: When forwarding a worker MCP request, the parent shall require a current grant bound to the authenticated worker, repository, worktree, assignment generation, server ID, and expiry without accepting worker-supplied upstream commands, URLs, or credential configuration.")
    func scopeAuthorization() throws {
        let (policy, scope, peer) = try fixture()
        #expect(throws: Never.self) { try policy.authorize(scope, peer: peer) }
        var changed = scope
        changed.generation += 1
        #expect(throws: MCPProxyError.unauthorized) { try policy.authorize(changed, peer: peer) }
        changed = scope; changed.serverID = "ungranted"
        #expect(throws: MCPProxyError.unauthorized) { try policy.authorize(changed, peer: peer) }
        changed = scope; changed.worktreePath = "/work/other"
        #expect(throws: MCPProxyError.unauthorized) { try policy.authorize(changed, peer: peer) }
        changed = scope; changed.repositoryID = UUID()
        #expect(throws: MCPProxyError.unauthorized) { try policy.authorize(changed, peer: peer) }
        let other = RemoteMacConnectionSummary.ID(deviceID: .init(value: "other"), fingerprint: peer.fingerprint)
        #expect(throws: MCPProxyError.unauthorized) { try policy.authorize(scope, peer: other) }
        #expect(throws: MCPProxyError.unauthorized) { try policy.authorize(scope, peer: peer, now: Date().addingTimeInterval(120)) }
    }

    @Test("@spec REMOTE-30.12: While proxying MCP, the application shall bound outstanding requests in each direction and expire each unanswered call even if other messages continue arriving.")
    func unansweredRequestsAreBounded() async throws {
        let (policy, scope, peer) = try fixture()
        let upstream = MCPFixtureTransport()
        let broker = MCPProxyBroker(peer: peer, authorize: { try policy.authorize($0, peer: $1) },
            makeTransport: { _ in MCPProxyEndpoint(transport: upstream) })
        let id = UUID()
        #expect(await broker.handle(.open(sessionID: id, scope: scope)) == .opened)
        for number in 0..<64 {
            let message = Data("{\"jsonrpc\":\"2.0\",\"id\":\(number),\"method\":\"ping\"}".utf8)
            #expect(await broker.handle(.send(sessionID: id, message: message)) == .accepted)
            #expect(try await upstream.nextSent() == message)
        }
        let overflow = Data(#"{"jsonrpc":"2.0","id":64,"method":"ping"}"#.utf8)
        #expect(await broker.handle(.send(sessionID: id, message: overflow)) == .error(.overloaded))
        await broker.close()
        var budget = MCPMessageBudget()
        let started = ContinuousClock.now
        try budget.record(Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8), from: .worker, now: started)
        try budget.record(Data(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#.utf8), from: .worker, now: started.advanced(by: .seconds(119)))
        #expect(budget.hasExpired(at: started.advanced(by: .seconds(120))))
        try budget.record(Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8), from: .parent)
        #expect(!budget.hasExpired(at: started.advanced(by: .seconds(120))))
    }

    @Test("@spec REMOTE-30.3: When an MCP grant expires, is revoked, or is superseded by reassignment, the application shall reject new calls and close its sessions without transferring that authority through copied session data.")
    func revocationClosesIdleSessions() async throws {
        let (policy, scope, peer) = try fixture()
        let current = MutableMCPPolicy(policy)
        let upstream = MCPFixtureTransport()
        let broker = MCPProxyBroker(peer: peer, authorize: { try current.get().authorize($0, peer: $1) },
            makeTransport: { _ in MCPProxyEndpoint(transport: upstream) })
        let id = UUID()
        #expect(await broker.handle(.open(sessionID: id, scope: scope)) == .opened)
        current.revoke()
        for _ in 0..<100 {
            if await upstream.disconnected { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await upstream.disconnected)
        #expect(await broker.handle(.receive(sessionID: id)) == .error(.unauthorized))
        #expect(await broker.handle(.open(sessionID: UUID(), scope: scope)) == .error(.unauthorized))
        await broker.close()
    }

    @Test("@spec REMOTE-30.9: When configuring granted MCP servers for a remote agent, the application shall preserve their logical server names and upstream tool definitions through separate Graftty bridge entries without requiring an agent-facing forwarding tool.")
    func nativeConfigurationsContainOnlyGrantAddresses() throws {
        let (_, scope, peer) = try fixture()
        var second = scope; second.serverID = "other-server"; second.grantID = UUID()
        let files = try MCPBridgeFiles.generate([.init(parent: peer, scope: scope), .init(parent: peer, scope: second)],
            executable: "/opt/graftty", configurationDirectory: "/profile/mcp", socketPath: "/profile/mcp.sock")
        let claudeData = try #require(files["claude-mcp.json"])
        let json = try #require(JSONSerialization.jsonObject(with: claudeData) as? [String: Any])
        let servers = try #require(json["mcpServers"] as? [String: [String: Any]])
        #expect(Set(servers.keys) == ["fixture", "other-server"])
        #expect(servers["fixture"]?["command"] as? String == "/opt/graftty")
        let toml = String(decoding: try #require(files["codex-mcp.toml"]), as: UTF8.self)
        #expect(toml.contains("[mcp_servers.fixture]"))
        #expect(toml.contains("[mcp_servers.other-server]"))
        #expect(!toml.contains("token"))
        for value in files.values { #expect(!String(decoding: value, as: UTF8.self).contains("/usr/bin/true")) }
        #expect(throws: MCPProxyError.invalidRequest) {
            try MCPBridgeFiles.generate([.init(parent: peer, scope: scope), .init(parent: peer, scope: scope)],
                executable: "/opt/graftty", configurationDirectory: "/profile", socketPath: "/sock")
        }
    }

    @Test("@spec REMOTE-30.10: When an MCP bridge forwards protocol messages, the application shall preserve request IDs, notifications and callbacks within one authorized session without replaying a call after a transport failure.")
    func transparentMessages() async throws {
        let (policy, scope, peer) = try fixture()
        let upstream = MCPFixtureTransport()
        let broker = MCPProxyBroker(peer: peer, authorize: { try policy.authorize($0, peer: $1) },
            makeTransport: { _ in MCPProxyEndpoint(transport: upstream) })
        let id = UUID()
        #expect(await broker.handle(.open(sessionID: id, scope: scope)) == .opened)
        let request = Data(#"{"jsonrpc":"2.0","id":"a","method":"tools/call","params":{"name":"edit"}}"#.utf8)
        #expect(await broker.handle(.send(sessionID: id, message: request)) == .accepted)
        let received = try await upstream.nextSent()
        #expect(received == request)
        let callback = Data(#"{"jsonrpc":"2.0","id":13,"method":"roots/list"}"#.utf8)
        await upstream.emit(callback)
        var result: MCPProxyResponse = .messages([])
        for _ in 0..<100 {
            result = await broker.handle(.receive(sessionID: id))
            if result != .messages([]) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(result == .messages([callback]))
        await upstream.fail()
        try await Task.sleep(for: .milliseconds(30))
        #expect(await broker.handle(.send(sessionID: id, message: request)) == .error(.outcomeUnknown))
        #expect(await upstream.sendCount == 1)
        await broker.close()
    }

    @Test("@spec REMOTE-30.24: When an upstream MCP transport ends after delivering complete messages, the application shall reject further sends, allow still-authorized receives to drain those messages once before reporting the terminal error, and discard them immediately on authority changes, teardown, or protocol-limit failures.",
          .timeLimit(.minutes(1)), arguments: [false, true], [false, true])
    func drainsCompleteMessagesAfterUpstreamEnds(throwing: Bool, blockedSend: Bool) async throws {
        let (policy, scope, peer) = try fixture()
        let upstream = MCPFixtureTransport(blockedSend: blockedSend)
        let broker = MCPProxyBroker(peer: peer, authorize: { try policy.authorize($0, peer: $1) },
            makeTransport: { _ in MCPProxyEndpoint(transport: upstream) })
        let id = UUID()
        #expect(await broker.handle(.open(sessionID: id, scope: scope)) == .opened)
        let request = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"edit"}}"#.utf8)
        #expect(await broker.handle(.send(sessionID: id, message: request)) == .accepted)
        #expect(try await upstream.nextSent() == request)
        let reply = Data(#"{"jsonrpc":"2.0","id":1,"result":{"content":[]}}"#.utf8)
        let notification = Data(#"{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}"#.utf8)
        await upstream.finish(after: [reply, notification], throwing: throwing)
        try await upstream.waitForDisconnect()
        #expect(await broker.handle(.send(sessionID: id, message: request)) == .error(.outcomeUnknown))
        #expect(await upstream.sendCount == 1)
        #expect(await broker.handle(.receive(sessionID: id)) == .messages([reply, notification]))
        #expect(await broker.handle(.receive(sessionID: id)) == .error(.outcomeUnknown))
        #expect(await broker.handle(.receive(sessionID: id)) == .error(.outcomeUnknown))
        await broker.close()
        #expect(await upstream.disconnectCount == 1)
    }

    enum HardInvalidation: CaseIterable, Sendable { case revoke, policyChange, sessionClose, brokerClose }

    @Test(.timeLimit(.minutes(1)), arguments: HardInvalidation.allCases)
    func hardInvalidationDiscardsRepliesAfterUpstreamEnds(invalidation: HardInvalidation) async throws {
        let (policy, scope, peer) = try fixture()
        let current = MutableMCPPolicy(policy)
        let upstream = MCPFixtureTransport()
        let broker = MCPProxyBroker(peer: peer, authorize: { try current.get().authorize($0, peer: $1) },
            makeTransport: { _ in MCPProxyEndpoint(transport: upstream) })
        let id = UUID()
        #expect(await broker.handle(.open(sessionID: id, scope: scope)) == .opened)
        let reply = Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)
        await upstream.finish(after: [reply])
        try await upstream.waitForDisconnect()
        let expected: MCPProxyError
        switch invalidation {
        case .revoke: current.revoke(); expected = .unauthorized
        case .policyChange: current.changeServer(); expected = .unauthorized
        case .sessionClose:
            #expect(await broker.handle(.close(sessionID: id)) == .closed)
            expected = .unavailable
        case .brokerClose: await broker.close(); expected = .unavailable
        }
        #expect(await broker.handle(.receive(sessionID: id)) == .error(expected))
        #expect(await broker.handle(.receive(sessionID: id)) == .error(expected))
        await broker.close()
        #expect(await upstream.disconnectCount == 1)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func protocolFailureDiscardsRepliesBeforeUpstreamEnds(overflow: Bool) async throws {
        let (policy, scope, peer) = try fixture()
        let upstream = MCPFixtureTransport()
        let broker = MCPProxyBroker(peer: peer, authorize: { try policy.authorize($0, peer: $1) },
            makeTransport: { _ in MCPProxyEndpoint(transport: upstream) })
        let id = UUID()
        #expect(await broker.handle(.open(sessionID: id, scope: scope)) == .opened)
        let notification = Data(#"{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}"#.utf8)
        let messages = overflow ? Array(repeating: notification, count: 33) : [notification, Data("malformed".utf8)]
        await upstream.finish(after: messages)
        try await upstream.waitForDisconnect()
        #expect(await broker.handle(.receive(sessionID: id)) == .error(overflow ? .overloaded : .invalidRequest))
        await broker.close()
        #expect(await upstream.disconnectCount == 1)
    }
}

private actor MCPFixtureTransport: Transport {
    nonisolated let logger = StdioTransport().logger
    private let incoming = AsyncThrowingStream<Data, Error>.makeStream()
    private let sent = AsyncThrowingStream<Data, Error>.makeStream()
    private let disconnectedEvents = AsyncStream<Void>.makeStream()
    private let blockedSend: Bool
    private(set) var sendCount = 0
    private(set) var disconnected = false
    private(set) var disconnectCount = 0
    init(blockedSend: Bool = false) { self.blockedSend = blockedSend }
    func connect() {}
    func disconnect() {
        disconnected = true; disconnectCount += 1
        incoming.continuation.finish(); sent.continuation.finish()
        disconnectedEvents.continuation.yield(())
        disconnectedEvents.continuation.finish()
    }
    func send(_ data: Data) async throws {
        sendCount += 1; sent.continuation.yield(data)
        if blockedSend { try await Task.sleep(for: .seconds(300)) }
    }
    func receive() -> AsyncThrowingStream<Data, Error> { incoming.stream }
    func emit(_ data: Data) { incoming.continuation.yield(data) }
    func fail() { incoming.continuation.finish(throwing: MCPProxyError.unavailable) }
    func finish(after messages: [Data], throwing: Bool = false) {
        for message in messages { incoming.continuation.yield(message) }
        incoming.continuation.finish(throwing: throwing ? MCPProxyError.unavailable : nil)
    }
    func waitForDisconnect() async throws {
        for await _ in disconnectedEvents.stream { return }
        throw MCPProxyError.unavailable
    }
    func nextSent() async throws -> Data {
        for try await message in sent.stream { return message }
        throw MCPProxyError.unavailable
    }
}

private final class MutableMCPPolicy: @unchecked Sendable {
    private let lock = NSLock()
    private var policy: MCPProxyPolicy
    init(_ policy: MCPProxyPolicy) { self.policy = policy }
    func get() -> MCPProxyPolicy { lock.withLock { policy } }
    func revoke() { lock.withLock { policy.grants[0].revoked = true } }
    func changeServer() {
        lock.withLock { policy.servers["fixture"] = .stdio(executable: "/usr/bin/true", arguments: ["changed"], environmentKeys: []) }
    }
}
