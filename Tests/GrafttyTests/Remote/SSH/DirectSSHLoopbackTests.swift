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
        func peer(key: Curve25519.Signing.PrivateKey, id: String = "client", allowed: Bool = true, managementAllowed: Bool = true) throws -> TrustedPeer {
            TrustedPeer(id: RemoteDeviceID(value: id), kind: .mac,
                        publicKey: try RemoteIdentityPublicKey(rawRepresentation: key.publicKey.rawRepresentation),
                        displayName: id,
                        capabilities: PairedDeviceCapabilities(terminalControl: allowed ? .allowed : .disabled,
                            portTunnel: .disabled, screenView: .disabled, screenControl: .disabled,
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
