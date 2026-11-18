#if os(macOS)
import CryptoKit
import Foundation
import GrafttyHostAgent
import GrafttyKit
import GrafttyProtocol
import GrafttyRemoteClient
import Testing

@Suite("Tailcat with the production Graftty SSH host", .serialized)
struct TailcatHostIntegrationTests {
    @Test("@spec SSH-1.19: When Tailcat carries a paired SSH session, the application shall dispatch the production host's control, team, and terminal channels without a TCP listener.", .timeLimit(.minutes(2)))
    func dispatchesProductionChannels() async throws {
        try await withProductionHost { fixture in
            let connection = try await fixture.connect()
            do {
                if ProcessInfo.processInfo.environment["GRAFTTY_TAILCAT_REQUIRE_RELAY"] == "1" {
                    #expect(try await connection.routeKind() == "relay")
                }
                let control = try await connection.ssh.makePaneControlClient()
                try await control.open()
                #expect(try await control.send(.equalize(target: "tailcat-host")) == .ok)
                control.close()
                let team = try await connection.ssh.makeTeamClient(handler: { $0 }, onClose: {})
                try await team.open()
                #expect(try await team.send(Data("tailcat-team".utf8)) == Data("tailcat-team".utf8))
                team.close()
                let terminal = try await connection.ssh.openTerminalSession(sessionName: "tailcat-terminal")
                let deadline = Task {
                    try? await Task.sleep(for: .seconds(10))
                    if !Task.isCancelled { terminal.close() }
                }
                defer { deadline.cancel(); terminal.close() }
                let payload = Data((0..<(1024 * 1024)).map { UInt8(truncatingIfNeeded: $0) })
                let received = Task { () throws -> Data in
                    var bytes = Data()
                    while bytes.count < payload.count {
                        if case .binary(let chunk) = try await terminal.receive() { bytes.append(chunk) }
                    }
                    return bytes
                }
                do {
                    try await terminal.send(.binary(payload))
                    #expect(try await received.value == payload)
                } catch { terminal.close(); _ = try? await received.value; throw error }
                // A successful terminal round trip also proves registration can complete.
                try await fixture.waitForRegistration()
            } catch { await connection.close(); throw error }
            await connection.close()
        }
    }

    @Test("@spec SSH-1.20: If a Tailcat client lacks the pinned host key or a paired client key, then the application shall reject the SSH session before exposing Graftty channels.", .timeLimit(.minutes(2)), arguments: [true, false])
    func rejectsUntrustedIdentities(hostMismatch: Bool) async throws {
        try await withProductionHost { fixture in
            do {
                let connection = try await fixture.connect(hostMismatch: hostMismatch, clientMismatch: !hostMismatch)
                await connection.close()
                Issue.record("An untrusted SSH identity was accepted")
            } catch PinnedHostKeyError.hostKeyMismatch(_, _) where hostMismatch {
                _ = try await fixture.accepted.value
            } catch DirectSSHHostConnection.ConnectionError.authenticationRejected where !hostMismatch {
                // Transport setup must succeed for a negative SSH test to pass.
                _ = try await fixture.accepted.value
            } catch {
                Issue.record("Expected an SSH identity rejection, received \(type(of: error))")
            }
        }
    }

    @Test("@spec SSH-1.21: While a paired client connects through Tailcat, the application shall enforce channel capabilities and disconnect the client when its pairing is revoked.", .timeLimit(.minutes(2)))
    func retainsCapabilitiesAndRevocation() async throws {
        try await withProductionHost(managementAllowed: false) { fixture in
            let connection = try await fixture.connect()
            do {
                let management = try await connection.ssh.makeWorktreeManagementClient()
                await #expect(throws: (any Error).self) { try await management.open() }
                management.close()
                let control = try await connection.ssh.makePaneControlClient()
                try await control.open()
                #expect(try await control.send(.equalize(target: "still-authorized")) == .ok)
                control.close()
                try await fixture.waitForRegistration()
                try fixture.store.remove(id: fixture.peer.id)
                await fixture.registry.revoke(deviceID: fixture.peer.id)
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                while !(await connection.ssh.state).isTerminal && ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(await connection.ssh.state.isTerminal)
                #expect(await fixture.registry.count == 0)
            } catch { await connection.close(); throw error }
            await connection.close()
        }
    }
}

private final class ProductionTailcatFixture: @unchecked Sendable {
    let server: TailcatPeer
    let host: DirectSSHHostServer
    let registry: SSHConnectionRegistry
    let store: TrustedPeerStore
    let peer: TrustedPeer
    let accepted: Task<TailcatPipe, Error>
    let hostKey: Curve25519.Signing.PrivateKey
    let clientKey: Curve25519.Signing.PrivateKey
    let directory: URL

    init(server: TailcatPeer, listener: TailcatListener, host: DirectSSHHostServer,
         registry: SSHConnectionRegistry, store: TrustedPeerStore, peer: TrustedPeer,
         hostKey: Curve25519.Signing.PrivateKey, clientKey: Curve25519.Signing.PrivateKey, directory: URL) {
        self.server = server; self.host = host; self.registry = registry; self.store = store; self.peer = peer
        self.hostKey = hostKey; self.clientKey = clientKey; self.directory = directory
        accepted = Task {
            let pipe = try await listener.accept()
            do {
                try await host.accept(input: pipe.file, output: pipe.file)
                try pipe.file.close()
                return pipe
            } catch { await pipe.close(); throw error }
        }
    }

    func connect(hostMismatch: Bool = false, clientMismatch: Bool = false) async throws -> TailcatSSHConnection {
        let key = hostMismatch ? Curve25519.Signing.PrivateKey() : hostKey
        let fingerprint = RemoteIdentityFingerprint(of: try RemoteIdentityPublicKey(rawRepresentation: key.publicKey.rawRepresentation))
        return try await TailcatSSHConnection.connect(address: server.address(), port: 8801,
            key: clientMismatch ? Curve25519.Signing.PrivateKey() : clientKey, fingerprint: fingerprint)
    }

    func waitForRegistration() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await registry.count != 1 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await registry.count == 1)
    }

    func close() async {
        accepted.cancel()
        await host.close()
        await server.close()
        if let pipe = try? await accepted.value { await pipe.close() }
        try? FileManager.default.removeItem(at: directory)
    }
}

private func withProductionHost(managementAllowed: Bool = true,
                                _ body: (ProductionTailcatFixture) async throws -> Void) async throws {
    let directory = URL.temporaryDirectory.appendingPathComponent("tailcat-host-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TrustedPeerStore(directory: directory)
    let hostKey = Curve25519.Signing.PrivateKey(), clientKey = Curve25519.Signing.PrivateKey()
    let peer = TrustedPeer(id: .init(value: "tailcat-client"), kind: .mac,
        publicKey: try .init(rawRepresentation: clientKey.publicKey.rawRepresentation), displayName: "Tailcat test",
        capabilities: .init(terminalControl: .allowed, portTunnel: .disabled, screenView: .disabled,
            screenControl: .disabled, worktreeManagement: managementAllowed ? .allowed : .disabled),
        pairedAt: Date(), lastSeenAt: nil)
    try store.add(peer)
    let registry = SSHConnectionRegistry()
    let host = DirectSSHHostServer(hostKey: hostKey, trustedPeerStore: store, streamFactory: { _, _ in ProductionEchoStream() },
        panesStateSubscribe: { onChange in await onChange(.snapshot([])); return .init {} },
        paneControlMutator: { _ in .ok }, displayOwnershipStore: SessionDisplayOwnershipStore(), sshConnectionRegistry: registry)
    await host.setTeamMessaging(handler: { _, bytes in bytes }, onConnect: { _, _ in }, onDisconnect: { _, _ in })
    let server = try TailcatPeer.server()
    let fixture: ProductionTailcatFixture
    do {
        fixture = ProductionTailcatFixture(server: server, listener: try await server.listen(port: 8801),
            host: host, registry: registry, store: store, peer: peer,
            hostKey: hostKey, clientKey: clientKey, directory: directory)
    } catch { await host.close(); await server.close(); throw error }
    do { try await body(fixture) }
    catch { await fixture.close(); throw error }
    await fixture.close()
}

private final class ProductionEchoStream: GrafttyKit.TerminalByteStream, Sendable {
    let inboundBytes: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    init() {
        let stream = AsyncStream<Data>.makeStream()
        inboundBytes = stream.stream; continuation = stream.continuation
    }
    func send(_ bytes: Data) async throws { continuation.yield(bytes) }
    func close() async { continuation.finish() }
}
#endif
