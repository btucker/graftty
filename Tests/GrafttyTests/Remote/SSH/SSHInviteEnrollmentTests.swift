import CryptoKit
import Foundation
@testable import GrafttyHostAgent
import GrafttyKit
import GrafttyProtocol
import NIOCore
import NIOEmbedded
import NIOSSH
import Testing

/// NIOSSH verifies a public-key signature, which covers the username, before
/// it calls the delegate, and answers unsigned key queries itself
/// (UserAuthenticationStateMachine). These tests pin the delegate's side:
/// only a signed public-key request from an unknown key reaches enrollment.
@Suite("@spec REMOTE-33.10: If an enrollment request is not a signed public-key request, then the runner shall not enroll its key.")
struct SSHInviteEnrollmentTests {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [RunnerEnrollmentToken] = []
        var tokens: [RunnerEnrollmentToken] { lock.withLock { stored } }
        func record(_ token: RunnerEnrollmentToken) { lock.withLock { stored.append(token) } }
    }

    private static let token = RunnerEnrollmentToken(secret: Data(repeating: 5, count: 32), deviceID: "mac", displayName: "Mac")

    private static func outcome(_ method: NIOSSHUserAuthenticationRequest.Request, username: String = token.username,
                                store: TrustedPeerStore = SSHUserAuthTestSupport.makeStore(prefix: "enroll"),
                                calls: Calls, enrolled: TrustedPeer? = nil) throws -> NIOSSHUserAuthenticationOutcome {
        let loop = EmbeddedEventLoop()
        defer { try! loop.syncShutdownGracefully() }
        let delegate = SSHUserAuthDelegate(store: store, enroll: { token, _ in calls.record(token); return enrolled })
        let promise = loop.makePromise(of: NIOSSHUserAuthenticationOutcome.self)
        delegate.requestReceived(request: .init(username: username, serviceName: "ssh-connection", request: method),
                                 responsePromise: promise)
        return try promise.futureResult.wait()
    }

    @Test func passwordAndNoneNeverEnroll() throws {
        let calls = Calls()
        #expect(SSHUserAuthTestSupport.isFailure(try Self.outcome(.password(.init(password: "x")), calls: calls)))
        #expect(SSHUserAuthTestSupport.isFailure(try Self.outcome(.none, calls: calls)))
        #expect(calls.tokens.isEmpty)
    }

    @Test func unknownKeyWithoutATokenNeverEnrolls() throws {
        let calls = Calls()
        let key = NIOSSHPrivateKey(ed25519Key: .init()).publicKey
        #expect(SSHUserAuthTestSupport.isFailure(try Self.outcome(.publicKey(.init(publicKey: key)), username: "graftty", calls: calls)))
        #expect(calls.tokens.isEmpty)
    }

    @Test func refusedEnrollmentFails() throws {
        let calls = Calls()
        let key = NIOSSHPrivateKey(ed25519Key: .init()).publicKey
        #expect(SSHUserAuthTestSupport.isFailure(try Self.outcome(.publicKey(.init(publicKey: key)), calls: calls)))
        #expect(calls.tokens == [Self.token])
    }

    @Test func acceptedEnrollmentSucceeds() throws {
        let calls = Calls()
        let private_ = Curve25519.Signing.PrivateKey()
        let peer = SSHUserAuthTestSupport.makePeer(key: private_, kind: .mac)
        let outcome = try Self.outcome(.publicKey(.init(publicKey: NIOSSHPrivateKey(ed25519Key: private_).publicKey)),
                                       calls: calls, enrolled: peer)
        #expect(SSHUserAuthTestSupport.isSuccess(outcome))
    }

    @Test func knownKeyIgnoresTheToken() throws {
        let calls = Calls()
        let private_ = Curve25519.Signing.PrivateKey()
        let store = SSHUserAuthTestSupport.makeStore(prefix: "enroll-known")
        try store.upsertAfterPairing(SSHUserAuthTestSupport.makePeer(key: private_, kind: .mac))
        let outcome = try Self.outcome(.publicKey(.init(publicKey: NIOSSHPrivateKey(ed25519Key: private_).publicKey)),
                                       store: store, calls: calls)
        #expect(SSHUserAuthTestSupport.isSuccess(outcome))
        #expect(calls.tokens.isEmpty)
    }
}
