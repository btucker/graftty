#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import GrafttyHostAgent
import GrafttyKit
import GrafttyProtocol
import GrafttyRemoteClient
import Testing
#if canImport(Network)
import Network
#endif

@Suite(.serialized)
struct DirectSSHLoopbackTests {
    private struct Fixture {
        let directory = URL.temporaryDirectory.appendingPathComponent("direct-ssh-\(UUID())")
        let hostKey = Curve25519.Signing.PrivateKey()
        let clientKey = Curve25519.Signing.PrivateKey()
        let registry = SSHConnectionRegistry()
        var store: TrustedPeerStore { TrustedPeerStore(directory: directory) }
        var fingerprint: RemoteIdentityFingerprint {
            get throws { RemoteIdentityFingerprint(of: try RemoteIdentityPublicKey(rawRepresentation: hostKey.publicKey.rawRepresentation)) }
        }
        func peer(key: Curve25519.Signing.PrivateKey, id: String = "client", allowed: Bool = true, managementAllowed: Bool = true, tunnelAllowed: Bool = false) throws -> TrustedPeer {
            TrustedPeer(id: RemoteDeviceID(value: id), kind: .mac,
                        publicKey: try RemoteIdentityPublicKey(rawRepresentation: key.publicKey.rawRepresentation),
                        displayName: id,
                        capabilities: PairedDeviceCapabilities(terminalControl: allowed ? .allowed : .disabled,
                            portTunnel: tunnelAllowed ? .allowedLoopback : .disabled, screenView: .disabled, screenControl: .disabled,
                            worktreeManagement: managementAllowed ? .allowed : .disabled),
                        pairedAt: Date(), lastSeenAt: nil)
        }
        func server() -> DirectSSHHostServer {
            DirectSSHHostServer(hostKey: hostKey, trustedPeerStore: store,
                streamFactory: { _ in DirectEchoTerminalStream() },
                panesStateSubscribe: { onChange in
                    await onChange(.snapshot([]))
                    return .init(cancel: {})
                }, paneControlMutator: { _ in .ok },
                displayOwnershipStore: SessionDisplayOwnershipStore(), sshConnectionRegistry: registry)
        }
        func client(key: Curve25519.Signing.PrivateKey? = nil, fingerprint: RemoteIdentityFingerprint? = nil) throws -> DirectSSHHostConnection {
            try DirectSSHHostConnection(clientKey: key ?? clientKey, expectedHostFingerprint: fingerprint ?? self.fingerprint)
        }
        func cleanup() { try? FileManager.default.removeItem(at: directory) }
    }

    #if canImport(Network)
    @Test("@spec PORTS-5.6: When a paired host allows port tunneling, a local port forward shall relay raw TCP bytes and close sockets when stopped or its parent disconnects.", .timeLimit(.minutes(1)), arguments: [false, true])
    func localPortForwardEchoAndDisconnect(closeParent: Bool) async throws {
        let f = Fixture(); defer { f.cleanup() }
        try f.store.add(f.peer(key: f.clientKey, tunnelAllowed: true))
        let server = f.server()
        let port = try await server.start(host: "127.0.0.1", port: 0)
        let client = try f.client()
        let echo = try ForwardEchoServer()
        let echoPort = try await echo.start()
        defer { echo.stop() }
        do {
            try await client.connect(host: "127.0.0.1", port: port)
            let forward = try await client.forwardLocalPort(host: "127.0.0.1", port: Int(echoPort))
            defer { forward.stop() }
            let socket = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: forward.localPort)!, using: .tcp)
            socket.start(queue: DispatchQueue(label: "forward-test-client"))
            defer { socket.cancel() }
            let deadline = Task { try? await Task.sleep(for: .seconds(5)); if !Task.isCancelled { socket.cancel() } }
            defer { deadline.cancel() }
            let payload = Data("GET / HTTP/1.0\r\n\r\n".utf8)
            try await BrowserProxy.send(payload, to: socket)
            let echoed = try await forwardReceive(socket, count: payload.count)
            #expect(echoed == payload) // A SOCKS greeting must never prefix raw data.
            let closing = ContinuousClock.now
            if closeParent { await client.close() } else { forward.stop() }
            #expect((try? await forwardReceive(socket, count: 1))?.isEmpty != false)
            #expect(closing.duration(to: .now) < .seconds(3))
        } catch { await client.close(); await server.close(); throw error }
        await client.close(); await server.close()
    }

    @Test("@spec PORTS-5.8: When a forwarded TCP destination finishes a finite response, the application shall deliver all queued bytes before reporting EOF to the local client.", .timeLimit(.minutes(1)))
    func localPortForwardDrainsFiniteResponse() async throws {
        let f = Fixture(); defer { f.cleanup() }
        try f.store.add(f.peer(key: f.clientKey, tunnelAllowed: true))
        let server = f.server()
        let port = try await server.start(host: "127.0.0.1", port: 0)
        let client = try f.client()
        let payload = Data(repeating: 0x5a, count: 8 * 1024 * 1024)
        let echo = try ForwardEchoServer(response: payload)
        let echoPort = try await echo.start()
        defer { echo.stop() }
        do {
            try await client.connect(host: "127.0.0.1", port: port)
            let forward = try await client.forwardLocalPort(host: "127.0.0.1", port: Int(echoPort))
            defer { forward.stop() }
            let socket = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: forward.localPort)!, using: .tcp)
            socket.start(queue: DispatchQueue(label: "forward-test-finite"))
            defer { socket.cancel() }
            let deadline = Task { try? await Task.sleep(for: .seconds(15)); if !Task.isCancelled { socket.cancel() } }
            defer { deadline.cancel() }
            try await BrowserProxy.send(Data("GET / HTTP/1.0\r\n\r\n".utf8), to: socket)
            var response = Data()
            while true {
                let (bytes, complete) = await withCheckedContinuation { (continuation: CheckedContinuation<(Data, Bool), Never>) in
                    socket.receive(minimumIncompleteLength: 1, maximumLength: 32768) { data, _, complete, error in
                        continuation.resume(returning: (data ?? Data(), complete || error != nil))
                    }
                }
                response.append(bytes)
                if complete { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(response == payload)
        } catch { await client.close(); await server.close(); throw error }
        await client.close(); await server.close()
    }

    @Test("@spec PORTS-5.7: If a host denies tunneling, local port forwarding shall fail before exposing a listener without bypassing host authorization.", .timeLimit(.minutes(1)))
    func localPortForwardRejectsDisabledCapability() async throws {
        let f = Fixture(); defer { f.cleanup() }
        try f.store.add(f.peer(key: f.clientKey))
        let server = f.server()
        let port = try await server.start(host: "127.0.0.1", port: 0)
        let client = try f.client()
        do {
            try await client.connect(host: "127.0.0.1", port: port)
            do {
                let forward = try await client.forwardLocalPort(host: "127.0.0.1", port: 1)
                forward.stop()
                Issue.record("Denied capability must reject the forward before browser launch")
            } catch { }
        } catch { await client.close(); await server.close(); throw error }
        await client.close(); await server.close()
    }
    #endif

    @Test("@spec REMOTE-20.3: When a paired peer connects over direct SSH, the application shall authenticate and dispatch existing Graftty subsystem channels over TCP.", .timeLimit(.minutes(1)))
    func subsystemRoundTrip() async throws {
        let f = Fixture(); defer { f.cleanup() }
        try f.store.add(f.peer(key: f.clientKey))
        let server = f.server()
        await server.setTeamMessaging(handler: { _, payload in payload }, onConnect: { _, _ in }, onDisconnect: { _, _ in })
        let port = try await server.start(host: "127.0.0.1", port: 0)
        let client = try f.client()
        do {
            try await client.connect(host: "127.0.0.1", port: port)
            let control = try await client.makePaneControlClient()
            try await control.open()
            #expect(try await control.send(.equalize(target: "test-pane")) == .ok)
            control.close()
            let panes = try await client.makePanesStateClient(onSnapshot: { _ in }, onClosed: { _ in }, originAware: true, requestReply: true)
            try await panes.open()
            panes.close()
            let team = try await client.makeTeamClient(handler: { $0 }, onClose: {})
            try await team.open()
            #expect(try await team.send(Data("team-loopback".utf8)) == Data("team-loopback".utf8))
            team.close()
            let terminal = try await client.openTerminalSession(sessionName: "echo", preferPaged: true)
            let deadline = Task { try? await Task.sleep(for: .seconds(5)); if !Task.isCancelled { terminal.close() } }
            defer { deadline.cancel(); terminal.close() }
            let payload = Data("direct-terminal".utf8)
            try await terminal.send(.binary(payload))
            #expect(try await terminal.receive() == .binary(payload))
        } catch { await client.close(); await server.close(); throw error }
        await client.close(); await server.close()
    }

    @Test("@spec REMOTE-20.12: When a direct SSH hostname resolves to IPv4 and IPv6, the application shall authenticate the successful connection without failed address attempts closing its authentication waiter.", .timeLimit(.minutes(1)))
    func hostnameFallbackKeepsWinningAuthentication() async throws {
        let f = Fixture(); defer { f.cleanup() }
        try f.store.add(f.peer(key: f.clientKey))
        let server = f.server()
        let port = try await server.start(host: "127.0.0.1", port: 0)
        let client = try f.client()
        do {
            try await client.connect(host: "localhost", port: port)
            let control = try await client.makePaneControlClient()
            try await control.open()
            #expect(try await control.send(.equalize(target: "test-pane")) == .ok)
            control.close()
        } catch { await client.close(); await server.close(); throw error }
        await client.close(); await server.close()
    }

    @Test("@spec REMOTE-20.4: If a direct SSH host key is unpinned or a peer lacks trust or terminal control, then the application shall reject the connection.", .timeLimit(.minutes(1)))
    func rejectsWrongHostAndUnauthorizedPeers() async throws {
        let f = Fixture(); defer { f.cleanup() }
        let server = f.server()
        let port = try await server.start(host: "127.0.0.1", port: 0)
        for mode in 0..<3 {
            let key = Curve25519.Signing.PrivateKey()
            if mode != 1 { try f.store.add(f.peer(key: key, id: "peer-\(mode)", allowed: mode != 2)) }
            let fingerprint = mode == 0 ? try RemoteIdentityFingerprint(rawBytes: Data(repeating: 0, count: 32)) : try f.fingerprint
            let client = try f.client(key: key, fingerprint: fingerprint)
            await #expect(throws: (any Error).self) { try await client.connect(host: "127.0.0.1", port: port) }
            await client.close()
        }
        await server.close()
    }

    @Test("@spec REMOTE-20.11: If direct SSH negotiation fails, then the application shall report the original connection error and retain a failed state until teardown is requested.", .timeLimit(.minutes(1)))
    func negotiationFailureRemainsFailed() async throws {
        let f = Fixture(); defer { f.cleanup() }
        try f.store.add(f.peer(key: f.clientKey))
        let server = f.server()
        let port = try await server.start(host: "127.0.0.1", port: 0)
        let client = try f.client(fingerprint: RemoteIdentityFingerprint(rawBytes: Data(repeating: 0, count: 32)))
        await #expect(throws: PinnedHostKeyError.self) { try await client.connect(host: "127.0.0.1", port: port) }
        if case .failed = await client.state {} else { Issue.record("Negotiation failure became a graceful close") }
        await client.close(); await server.close()
    }

    @Test("@spec REMOTE-20.7: When a paired peer reconnects over direct SSH, the application shall authenticate a fresh session and prevent stale teardown from closing the replacement.", .timeLimit(.minutes(1)))
    func reconnectReplacesOnlySamePeer() async throws {
        let f = Fixture(); defer { f.cleanup() }
        try f.store.add(f.peer(key: f.clientKey))
        let server = f.server()
        let port = try await server.start(host: "127.0.0.1", port: 0)
        let old = try f.client(); let fresh = try f.client()
        do {
            try await old.connect(host: "127.0.0.1", port: port)
            for _ in 0..<100 where await f.registry.count != 1 { try await Task.sleep(for: .milliseconds(10)) }
            try await fresh.connect(host: "127.0.0.1", port: port)
            for _ in 0..<100 where await old.state != .closed { try await Task.sleep(for: .milliseconds(10)) }
            #expect(await old.state == .closed)
            await old.close()
            let control = try await fresh.makePaneControlClient()
            try await control.open()
            #expect(try await control.send(.equalize(target: "fresh")) == .ok)
            control.close()
            #expect(await f.registry.count == 1)
        } catch { await old.close(); await fresh.close(); await server.close(); throw error }
        await old.close(); await fresh.close(); await server.close()
    }

    @Test("@spec REMOTE-20.10: While a peer is authenticated over direct SSH, the application shall enforce its worktree management and port tunnel capabilities for each channel.", .timeLimit(.minutes(1)))
    func channelCapabilitiesAreEnforced() async throws {
        let f = Fixture(); defer { f.cleanup() }
        try f.store.add(f.peer(key: f.clientKey, managementAllowed: false))
        let server = f.server()
        let port = try await server.start(host: "127.0.0.1", port: 0)
        let client = try f.client()
        do {
            try await client.connect(host: "127.0.0.1", port: port)
            let management = try await client.makeWorktreeManagementClient()
            await #expect(throws: (any Error).self) { try await management.open() }
            management.close()
            await #expect(throws: (any Error).self) {
                _ = try await client.openTCPChannel(host: "127.0.0.1", port: port) { child in child.eventLoop.makeSucceededVoidFuture() }
            }
            let control = try await client.makePaneControlClient()
            try await control.open(); control.close()
        } catch { await client.close(); await server.close(); throw error }
        await client.close(); await server.close()
    }

    @Test("@spec REMOTE-20.5: While distinct paired peers use direct SSH, the application shall keep their connections independent and close revoked peers before rejecting fresh authentication.", .timeLimit(.minutes(1)))
    func concurrentPeersAndRevocation() async throws {
        let f = Fixture(); defer { f.cleanup() }
        let otherKey = Curve25519.Signing.PrivateKey()
        try f.store.add(f.peer(key: f.clientKey))
        try f.store.add(f.peer(key: otherKey, id: "other"))
        let server = f.server()
        let port = try await server.start(host: "127.0.0.1", port: 0)
        let first = try f.client(); let other = try f.client(key: otherKey)
        do {
            try await first.connect(host: "127.0.0.1", port: port)
            try await other.connect(host: "127.0.0.1", port: port)
            // Auth registration is asynchronous; wait for both registry entries.
            for _ in 0..<100 where await f.registry.count != 2 { try await Task.sleep(for: .milliseconds(10)) }
            #expect(await f.registry.count == 2)
            try f.store.remove(id: .init(value: "client"))
            await f.registry.revoke(deviceID: .init(value: "client"))
            let control = try await other.makePaneControlClient()
            try await control.open(); control.close()
            let retry = try f.client()
            await #expect(throws: (any Error).self) { try await retry.connect(host: "127.0.0.1", port: port) }
            await retry.close()
        } catch { await first.close(); await other.close(); await server.close(); throw error }
        await first.close(); await other.close(); await server.close()
    }
}

private final class DirectEchoTerminalStream: GrafttyKit.TerminalByteStream, Sendable {
    let inboundBytes: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    init() {
        let stream = AsyncStream<Data>.makeStream()
        inboundBytes = stream.stream; continuation = stream.continuation
    }
    func send(_ bytes: Data) async throws { continuation.yield(bytes) }
    func close() async { continuation.finish() }
}

#if canImport(Network)
private func forwardReceive(_ socket: NWConnection, count: Int) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
        socket.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume(returning: data ?? Data()) }
        }
    }
}

private final class ForwardEchoServer: @unchecked Sendable {
    let listener: NWListener
    let queue = DispatchQueue(label: "forward-test-echo")
    private var sockets: [NWConnection] = []
    private let response: Data?
    init(response: Data? = nil) throws {
        self.response = response
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                if case .ready = state, let port = listener.port {
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: port.rawValue)
                } else if case .failed(let error) = state {
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                }
            }
            listener.newConnectionHandler = { [self] socket in
                sockets.append(socket)
                socket.start(queue: queue)
                socket.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                    guard let data, !data.isEmpty else { socket.cancel(); return }
                    if let response = self.response {
                        socket.send(content: response, contentContext: .finalMessage, isComplete: true,
                                    completion: .contentProcessed { _ in })
                    } else {
                        socket.send(content: data, completion: .contentProcessed { _ in })
                    }
                }
            }
            listener.start(queue: queue)
        }
    }
    func stop() {
        queue.async { [self] in
            listener.newConnectionHandler = nil
            listener.stateUpdateHandler = nil
            listener.cancel()
            sockets.forEach { $0.cancel() }
            sockets.removeAll()
        }
    }
}
#endif
