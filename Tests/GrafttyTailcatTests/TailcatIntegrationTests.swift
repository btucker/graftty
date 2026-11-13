import CryptoKit
import Darwin
import Foundation
import GrafttyProtocol
@testable import GrafttyRemoteClient
import NIOCore
import NIOConcurrencyHelpers
import NIOPosix
import NIOSSH
import Testing

@Suite("Embedded Tailcat with the Graftty SSH client", .serialized)
struct TailcatIntegrationTests {
    @Test("@spec SSH-1.17: If descriptor duplication fails during Tailcat SSH setup, then the application shall release successful duplicates and report an error before NIO bootstrap.")
    func descriptorAllocationFailureIsRecoverable() throws {
        let pipe = Pipe()
        var first: Int32 = -1
        var calls = 0
        var released: [Int32] = []
        defer { if first >= 0 { Darwin.close(first) } }
        #expect(throws: POSIXError.self) {
            _ = try duplicatePipeDescriptors(pipe.fileHandleForReading.fileDescriptor,
                closeDescriptor: { released.append($0) }) { descriptor in
                calls += 1
                if calls == 1 {
                    first = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
                    return first
                }
                errno = EMFILE
                return -1
            }
        }
        #expect(first >= 0)
        #expect(released == [first])
    }

    @Test("@spec SSH-1.18: When a Tailcat SSH connection closes its NIO channel, the application shall close the remote SSH transport without requiring explicit Tailcat peer closure.", .timeLimit(.minutes(2)))
    func sshClosureReleasesBridge() async throws {
        try await withFixture { fixture in
            let connection = try await fixture.connect()
            let (serverChannel, _) = try await fixture.accepted.value
            await connection.ssh.close()
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while serverChannel.isActive && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(!serverChannel.isActive)
            await connection.close()
        }
    }

    @Test("@spec SSH-1.13: When the Tailcat prototype connects a paired SSH client to a pinned host, the application shall preserve terminal byte order and contents.", .timeLimit(.minutes(2)))
    func authenticatedTerminalRoundTrip() async throws {
        try await withFixture { fixture in
            let connection = try await fixture.connect()
            do {
                let route = try await connection.routeKind()
                if ProcessInfo.processInfo.environment["GRAFTTY_TAILCAT_REQUIRE_RELAY"] == "1" {
                    #expect(route == "relay")
                }
                let terminal = try await connection.ssh.openTerminalSession(sessionName: "tailcat-probe")
                defer { terminal.close() }
                var samples: [Double] = []
                for index in 0..<20 {
                    let payload = Data([UInt8(index)])
                    let start = ContinuousClock.now
                    try await terminal.send(.binary(payload))
                    #expect(try await terminal.receive() == .binary(payload))
                    let elapsed = start.duration(to: .now).components
                    samples.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
                }
                let payload = Data((0..<(1024 * 1024)).map { UInt8(truncatingIfNeeded: $0) })
                let drain = Task { () throws -> Data in
                    var received = Data()
                    while received.count < payload.count {
                        if case .binary(let bytes) = try await terminal.receive() { received.append(bytes) }
                    }
                    return received
                }
                try await terminal.send(.binary(payload))
                #expect(try await drain.value == payload)
                samples.sort()
                print("[tailcat-probe] route=\(route) samples=20 p50_ms=\(samples[9]) p95_ms=\(samples[18]) max_ms=\(samples[19]) bulk_bytes=\(payload.count)")
            } catch { await connection.close(); throw error }
            await connection.close()
        }
    }

    @Test("@spec SSH-1.14: If the Tailcat prototype receives a mismatched SSH host key or an unpaired client key, then the application shall reject the SSH connection.", .timeLimit(.minutes(2)), arguments: [true, false])
    func rejectsUntrustedSSH(hostMismatch: Bool) async throws {
        try await withFixture { fixture in
            do {
                let connection = try await fixture.connect(hostMismatch: hostMismatch, clientMismatch: !hostMismatch)
                await connection.close()
                Issue.record("An untrusted SSH identity was accepted")
            } catch {
                // Bootstrap failures must not make negative SSH tests pass.
                #expect(!(error is TailcatFailure))
                if let failure = error as? DirectSSHHostConnection.ConnectionError, case .timedOut = failure {
                    Issue.record("SSH timed out instead of rejecting the identity")
                }
                _ = try await fixture.accepted.value
            }
        }
    }

    @Test("@spec SSH-1.15: When a pending Tailcat accept is cancelled, the application shall interrupt the accept and retain the listener for a subsequent authenticated connection.", .timeLimit(.minutes(2)))
    func cancelledAcceptLeavesListenerUsable() async throws {
        let server = try TailcatPeer.server()
        do {
            let listener = try await server.listen(port: 8801)
            let pending = Task { try await listener.accept() }
            try await Task.sleep(for: .milliseconds(100))
            pending.cancel()
            await #expect(throws: CancellationError.self) { _ = try await pending.value }
            // Reuse this exact server/listener after cancellation.
            try await withFixture(server: server, listener: listener) { fixture in
                let connection = try await fixture.connect()
                #expect(await connection.ssh.state == .connected)
                await connection.close()
            }
        } catch { await server.close(); throw error }
        await server.close()
    }

    @Test("@spec SSH-1.16: When a Tailcat peer closes, the application shall unblock pending SSH terminal receives and permit a fresh connection.", .timeLimit(.minutes(2)))
    func peerClosureEndsReceive() async throws {
        try await withFixture { fixture in
            let connection = try await fixture.connect()
            do {
                let terminal = try await connection.ssh.openTerminalSession(sessionName: "close-probe")
                defer { terminal.close() }
                let receive = Task { try await terminal.receive() }
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                while terminal.pendingReceiverCountForTesting == 0 && ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(1))
                }
                #expect(terminal.pendingReceiverCountForTesting == 1)
                await fixture.server.close()
                await #expect(throws: (any Error).self) { _ = try await receive.value }
            } catch { await connection.close(); throw error }
            await connection.close()
        }
        try await withFixture { fixture in
            let connection = try await fixture.connect()
            #expect(await connection.ssh.state == .connected)
            await connection.close()
        }
    }
}

private func duplicatePipeDescriptors(_ descriptor: Int32,
    closeDescriptor: (Int32) -> Void = { _ = Darwin.close($0) },
    duplicate: (Int32) -> Int32 = { fcntl($0, F_DUPFD_CLOEXEC, 0) }) throws -> (Int32, Int32) {
    let input = duplicate(descriptor)
    guard input >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let output = duplicate(descriptor)
    guard output >= 0 else {
        let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        closeDescriptor(input)
        throw error
    }
    return (input, output)
}

private func fingerprint(_ key: Curve25519.Signing.PrivateKey) throws -> RemoteIdentityFingerprint {
    RemoteIdentityFingerprint(of: try RemoteIdentityPublicKey(rawRepresentation: key.publicKey.rawRepresentation))
}

private final class Fixture: @unchecked Sendable {
    let server: TailcatPeer
    let hostKey = Curve25519.Signing.PrivateKey()
    let clientKey = Curve25519.Signing.PrivateKey()
    let accepted: Task<(Channel, TailcatPipe), Error>

    init(server: TailcatPeer, listener: TailcatListener) {
        self.server = server
        let hostKey = hostKey
        let clientKey = clientKey
        accepted = Task {
            let pipe = try await listener.accept()
            var descriptors: (Int32, Int32)?
            let initialized = NIOLockedValueBox(false)
            do {
                let pair = try duplicatePipeDescriptors(pipe.file.fileDescriptor)
                descriptors = pair
                let channel = try await NIOPipeBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                    .channelInitializer { channel in
                        initialized.withLockedValue { $0 = true }
                        return channel.eventLoop.makeCompletedFuture {
                            let config = SSHServerConfiguration(hostKeys: [NIOSSHPrivateKey(ed25519Key: hostKey)],
                                userAuthDelegate: PairedKey(key: NIOSSHPrivateKey(ed25519Key: clientKey).publicKey))
                            try channel.pipeline.syncOperations.addHandler(NIOSSHHandler(role: .server(config),
                                allocator: channel.allocator, inboundChildChannelInitializer: { child, type in
                                    guard case .session = type else { return child.eventLoop.makeFailedFuture(FixtureFailure.unexpectedChannel) }
                                    return child.pipeline.addHandler(TerminalEcho())
                                }))
                        }
                    }.takingOwnershipOfDescriptors(input: pair.0, output: pair.1).get()
                do { try pipe.file.close() }
                catch { try? await channel.close().get(); throw error }
                return (channel, pipe)
            } catch {
                if !initialized.withLockedValue({ $0 }), let descriptors {
                    Darwin.close(descriptors.0)
                    Darwin.close(descriptors.1)
                }
                await pipe.close()
                throw error
            }
        }
    }

    func connect(hostMismatch: Bool = false, clientMismatch: Bool = false) async throws -> TailcatSSHConnection {
        try await TailcatSSHConnection.connect(address: server.address(), port: 8801,
            key: clientMismatch ? Curve25519.Signing.PrivateKey() : clientKey,
            fingerprint: fingerprint(hostMismatch ? Curve25519.Signing.PrivateKey() : hostKey))
    }

    func close() async {
        await server.close()
        if let (channel, pipe) = try? await accepted.value {
            try? await channel.close().get()
            await pipe.close()
        }
    }
}

private func withFixture(server existing: TailcatPeer? = nil, listener existingListener: TailcatListener? = nil,
                         _ body: (Fixture) async throws -> Void) async throws {
    let server = try existing ?? TailcatPeer.server()
    let listener: TailcatListener
    do {
        if let existingListener { listener = existingListener }
        else { listener = try await server.listen(port: 8801) }
    }
    catch { await server.close(); throw error }
    let fixture = Fixture(server: server, listener: listener)
    do { try await body(fixture) }
    catch { await fixture.close(); throw error }
    await fixture.close()
}

private enum FixtureFailure: Error { case unexpectedChannel }
private final class PairedKey: NIOSSHServerUserAuthenticationDelegate {
    let key: NIOSSHPublicKey
    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { [.publicKey] }
    init(key: NIOSSHPublicKey) { self.key = key }
    func requestReceived(request: NIOSSHUserAuthenticationRequest,
                         responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        if case .publicKey(let offered) = request.request, offered.publicKey == key { responsePromise.succeed(.success) }
        else { responsePromise.succeed(.failure) }
    }
}

// Synthetic PTY, matching the existing iOS SSH loopback strategy. The real
// TerminalSessionClient drives env, pty, shell, and binary SSH channel data.
private final class TerminalEcho: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.writeAndFlush(wrapOutboundOut(unwrapInboundIn(data)), promise: nil)
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        let reply: Bool
        switch event {
        case let request as SSHChannelRequestEvent.SubsystemRequest:
            // Match a legacy host: reject unsupported optional probes at once.
            if request.wantReply { context.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil) }
            context.close(promise: nil)
            return
        case let request as SSHChannelRequestEvent.EnvironmentRequest: reply = request.wantReply
        case let request as SSHChannelRequestEvent.PseudoTerminalRequest: reply = request.wantReply
        case let request as SSHChannelRequestEvent.ShellRequest: reply = request.wantReply
        default: return
        }
        if reply { context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil) }
    }
}
