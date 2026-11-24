#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import GrafttyKit
import GrafttyProtocol
import GrafttyRemoteClient
import Testing
@testable import GrafttyRunner

@Suite(.serialized) @MainActor
struct InviteEnrollmentTests {
    private final class Clock: @unchecked Sendable { var now = Date() }

    private struct Fixture {
        let root = URL(fileURLWithPath: "/tmp/gi-" + UUID().uuidString, isDirectory: true)
        let configuration: HostConfiguration

        init() throws {
            configuration = HostConfiguration(httpPort: 0, sshPort: 0,
                stateDirectory: root.appendingPathComponent("state"),
                runtimeDirectory: root.appendingPathComponent("run"),
                zmxExecutable: URL(fileURLWithPath: "/bin/true"))
            try configuration.prepareDirectories()
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }

        var trusted: TrustedPeerStore { TrustedPeerStore(directory: configuration.identityDirectory) }

        func invite() async throws -> RunnerInvite {
            for _ in 0..<300 {
                switch try await HostAdministrationServer.request(.createInvite, configuration: configuration) {
                case .invite(let invite): return invite
                default: try await Task.sleep(for: .milliseconds(100))
                }
            }
            throw HostRuntimeError.invalid("the runner never issued an invite")
        }

        /// Connects over the loopback listener, presenting `token` when given.
        func connect(port: Int, invite: RunnerInvite, key: Curve25519.Signing.PrivateKey,
                     token: RunnerEnrollmentToken?) async throws {
            let hostKey = try RemoteIdentityPublicKey(rawRepresentation: #require(Data(base64Encoded: invite.identity.publicKey)))
            let client = DirectSSHHostConnection(clientKey: key, expectedHostFingerprint: RemoteIdentityFingerprint(of: hostKey),
                                                 username: token?.username ?? DirectSSHHostConnection.defaultUsername)
            do { try await client.connect(host: "127.0.0.1", port: port) } catch { await client.close(); throw error }
            await client.close()
        }
    }

    private static func token(_ invite: RunnerInvite, deviceID: String = "mac-id") -> RunnerEnrollmentToken {
        RunnerEnrollmentToken(secret: invite.secret, deviceID: deviceID, displayName: "My Mac")
    }

    @Test("@spec REMOTE-33.8: When a Mac presents an unexpired invite secret while signing with its key, the runner shall trust that key and accept the session.",
          .timeLimit(.minutes(2)))
    func enrollsTheSigningKey() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let service = try HostService(configuration: fixture.configuration, enablePairing: false)
        do {
            let port = try await service.start()
            let invite = try await fixture.invite()
            let key = Curve25519.Signing.PrivateKey()
            try await fixture.connect(port: port, invite: invite, key: key, token: Self.token(invite))
            let peer = try #require(try fixture.trusted.get(id: RemoteDeviceID(value: "mac-id")))
            #expect(peer.publicKey.rawRepresentation == key.publicKey.rawRepresentation)
            #expect(peer.displayName == "My Mac")
            try await fixture.connect(port: port, invite: invite, key: key, token: nil)
        } catch { await service.stop(); throw error }
        await service.stop()
    }

    @Test("@spec REMOTE-33.9: If an invite secret was already redeemed or has expired, then the runner shall refuse enrollment and leave its trusted peers unchanged.",
          .timeLimit(.minutes(2)))
    func refusesReplayAndExpiry() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let clock = Clock()
        let service = try HostService(configuration: fixture.configuration, enablePairing: false,
                                      inviteBook: RunnerInviteBook(now: { clock.now }))
        do {
            let port = try await service.start()
            let used = try await fixture.invite()
            try await fixture.connect(port: port, invite: used, key: .init(), token: Self.token(used, deviceID: "first"))
            await #expect(throws: (any Error).self) {
                try await fixture.connect(port: port, invite: used, key: .init(), token: Self.token(used, deviceID: "replay"))
            }
            let stale = try await fixture.invite()
            clock.now = clock.now.addingTimeInterval(3601)
            await #expect(throws: (any Error).self) {
                try await fixture.connect(port: port, invite: stale, key: .init(), token: Self.token(stale, deviceID: "late"))
            }
            #expect(try fixture.trusted.list().map(\.id.value) == ["first"])
        } catch { await service.stop(); throw error }
        await service.stop()
    }

    @Test("@spec REMOTE-33.21: If an invite redeemer names a device already trusted with a different key, then the runner shall refuse enrollment and leave that peer unchanged.")
    func refusesToReplaceATrustedDevice() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = Curve25519.Signing.PrivateKey()
        try HostService.trust(LinuxHostTrustRequest(deviceID: "mac-id", displayName: "Original Mac",
            publicKey: original.publicKey.rawRepresentation.base64EncodedString()),
            publicKeyData: original.publicKey.rawRepresentation, configuration: fixture.configuration)
        let book = RunnerInviteBook()
        let enroll = HostService.inviteEnrollment(book: book, configuration: fixture.configuration)
        let impostor = try RemoteIdentityPublicKey(rawRepresentation: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        let token = RunnerEnrollmentToken(secret: book.issue().secret, deviceID: "mac-id", displayName: "Impostor")
        #expect(enroll(token, impostor) == nil)
        let peer = try #require(try fixture.trusted.get(id: RemoteDeviceID(value: "mac-id")))
        #expect(peer.publicKey.rawRepresentation == original.publicKey.rawRepresentation)
        #expect(peer.displayName == "Original Mac")
    }

    @Test("@spec REMOTE-33.20: If the runner presents a key other than the invite key, then the application shall abort enrollment without trusting anything.",
          .timeLimit(.minutes(2)))
    func enrollmentPinsTheInviteKey() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let service = try HostService(configuration: fixture.configuration, enablePairing: false)
        do {
            let port = try await service.start()
            let genuine = try await fixture.invite()
            let impostorKey = Data(repeating: 8, count: 32).base64EncodedString()
            let tampered = RunnerInvite(identity: LinuxHostIdentity(deviceID: genuine.identity.deviceID,
                displayName: genuine.identity.displayName, publicKey: impostorKey, port: 8801),
                endpoint: genuine.endpoint, secret: genuine.secret, expiresAt: genuine.expiresAt)
            let key = Curve25519.Signing.PrivateKey()
            func enroll(_ invite: RunnerInvite) async throws {
                try await RunnerInviteEnrollment.enroll(
                    hostPublicKey: RemoteIdentityPublicKey(rawRepresentation: #require(Data(base64Encoded: invite.identity.publicKey))),
                    enrollmentUsername: Self.token(invite).username, clientKey: key) {
                    try await $0.connect(host: "127.0.0.1", port: port)
                }
            }
            await #expect(throws: (any Error).self) { try await enroll(tampered) }
            #expect(try fixture.trusted.list().isEmpty)
            try await enroll(genuine)
            #expect(try fixture.trusted.get(id: RemoteDeviceID(value: "mac-id")) != nil)
        } catch { await service.stop(); throw error }
        await service.stop()
    }

    @Test("@spec REMOTE-33.11: When asked for an invite, the runner shall print one invite line and nothing else.")
    func invitePrintsOneLine() throws {
        let invite = RunnerInvite(identity: LinuxHostIdentity(deviceID: "r", displayName: "Runner",
            publicKey: Data(repeating: 2, count: 32).base64EncodedString(), port: 8801),
            endpoint: TailcatEndpoint(address: "fixture", port: 8801), secret: Data(repeating: 3, count: 32),
            expiresAt: Date(timeIntervalSince1970: 1_900_000_000))
        let line = try Invite.render(.invite(invite))
        #expect(line == invite.encoded())
        #expect(throws: (any Error).self) { try Invite.render(.error("not running")) }
    }

    @Test("@spec REMOTE-33.12: When GRAFTTY_PRINT_INVITE is 1 and no peer is trusted, the runner shall print one invite at start.",
          .timeLimit(.minutes(2)))
    func printsAnInviteAtFirstStart() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let printed = Printed()
        let service = try HostService(configuration: fixture.configuration, enablePairing: false,
                                      environment: ["GRAFTTY_PRINT_INVITE": "1"], printInvite: { printed.append($0) })
        do {
            _ = try await service.start()
            for _ in 0..<300 where printed.lines.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
            #expect(printed.lines.count == 1)
            // The fixture's ephemeral SSH port makes the identity fail full
            // validation, so check the line's shape rather than parsing it.
            let line = try #require(printed.lines.first)
            #expect(line.hasPrefix(RunnerInvite.prefix))
            #expect(!line.contains { $0.isWhitespace })
        } catch { await service.stop(); throw error }
        await service.stop()
    }

    private final class Printed: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        var lines: [String] { lock.withLock { stored } }
        func append(_ line: String) { lock.withLock { stored.append(line) } }
    }
}
