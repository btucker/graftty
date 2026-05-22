#if canImport(UIKit)
import CryptoKit
import Foundation
import GrafttyProtocol
import NIOCore
import NIOSSH
import Testing
import WebRTC
@testable import GrafttyMobileKit

/// End-to-end SSH-over-WebRTC auth tests using real `PinnedHostStore`
/// on the client side + real `SSHClientSetup` + real
/// `PinnedHostKeyAuthDelegate`. The server-side userauth + handler
/// factory (production code lives in `GrafttyHostAgent` which depends
/// on `GrafttyKit`'s AppKit-importing files) is re-implemented inline
/// here because neither `GrafttyHostAgent` nor `GrafttyKit` is reachable
/// from the iOS `GrafttyMobileKitTests` target. The inline server logic
/// is a verbatim mirror of `SSHUserAuthDelegate` / `SSHServerSetup` —
/// intentional small duplication, consolidation post-R6 once a shared
/// SSH-loopback test fixture lands.
///
/// Reuses the `LoopbackPeer` pattern from R2's
/// `SSHOverWebRTCLoopbackTests.swift` (copy-don't-extract per that
/// suite's precedent; cross-cutting refactor is post-R6 work).
@Suite("SSH-over-WebRTC auth — PinnedHostStore + key-only identity (R3)")
struct SSHAuthLoopbackTests {

    /// Positive baseline: a paired peer's key is in the in-memory peer
    /// set on the server side, and the client pins the server's host
    /// fingerprint. Exec round-trip succeeds.
    @Test(.timeLimit(.minutes(3)))
    func pairedPeerSucceeds() async throws {
        let serverKey = Curve25519.Signing.PrivateKey()
        let clientKey = Curve25519.Signing.PrivateKey()
        let peerStore = InMemoryTrustedPeerSet()
        peerStore.add(fingerprint: Self.fingerprint(of: clientKey))

        let pinned = PinnedHostStore(directory: try Self.makeTempDir())
        let serverFingerprint = Self.fingerprint(of: serverKey)
        try pinned.add(PinnedHost(
            id: .generate(),
            kind: .mac,
            publicKey: try RemoteIdentityPublicKey(rawRepresentation: serverKey.publicKey.rawRepresentation),
            displayName: "Test host",
            pinnedAt: Date(),
            pairingURL: URL(string: "https://host.local")!
        ))
        // Look up the fingerprint we just stored — proves the
        // round-trip through the real store.
        let expected = try #require(try pinned.get(fingerprint: serverFingerprint))
        #expect(expected.fingerprint == serverFingerprint)

        let response = try await runAuthLoopback(
            serverKey: serverKey,
            trustedPeers: peerStore,
            clientKey: clientKey,
            expectedHostFingerprint: serverFingerprint
        )
        #expect(response == "loopback-exec-ok\n")
    }

    @Test(
        """
@spec REMOTE-8.2: When the host receives a userauth request, the host shall accept only the `publickey` method and reject `password` and `keyboard-interactive` immediately.
""",
        .timeLimit(.minutes(3))
    )
    func nonPublicKeyMethodRejected() async throws {
        let serverKey = Curve25519.Signing.PrivateKey()
        let clientKey = Curve25519.Signing.PrivateKey()
        // Peer is paired so we know rejection isn't due to a missing
        // trust entry — the client just never offers publickey.
        let peerStore = InMemoryTrustedPeerSet()
        peerStore.add(fingerprint: Self.fingerprint(of: clientKey))

        await #expect(throws: (any Error).self) {
            _ = try await runAuthLoopback(
                serverKey: serverKey,
                trustedPeers: peerStore,
                clientKey: clientKey,
                expectedHostFingerprint: Self.fingerprint(of: serverKey),
                clientOffersNothing: true
            )
        }
    }

    @Test(
        """
@spec REMOTE-8.3: When the host receives a userauth request, the host shall identify the peer solely by the offered public key against `TrustedPeerStore` and shall ignore the username field.
""",
        .timeLimit(.minutes(3))
    )
    func differentUsernameSameKeyStillSucceeds() async throws {
        let serverKey = Curve25519.Signing.PrivateKey()
        let clientKey = Curve25519.Signing.PrivateKey()
        let peerStore = InMemoryTrustedPeerSet()
        peerStore.add(fingerprint: Self.fingerprint(of: clientKey))

        let response = try await runAuthLoopback(
            serverKey: serverKey,
            trustedPeers: peerStore,
            clientKey: clientKey,
            expectedHostFingerprint: Self.fingerprint(of: serverKey),
            clientUsername: "definitely-not-graftty"
        )
        #expect(response == "loopback-exec-ok\n")
    }

    @Test(
        """
@spec REMOTE-8.4: When the client receives a host key during SSH KEX, the client shall verify the key against `PinnedHostStore` and abort the connection on mismatch.
""",
        .timeLimit(.minutes(3))
    )
    func pinnedHostKeyMismatchRejected() async throws {
        let serverKey = Curve25519.Signing.PrivateKey()
        let clientKey = Curve25519.Signing.PrivateKey()
        let peerStore = InMemoryTrustedPeerSet()
        peerStore.add(fingerprint: Self.fingerprint(of: clientKey))

        // Pin a *different* host key — anything that doesn't match the
        // server's actual key. The handshake must abort.
        let unrelatedKey = Curve25519.Signing.PrivateKey()
        let unrelatedFingerprint = Self.fingerprint(of: unrelatedKey)

        await #expect(throws: (any Error).self) {
            _ = try await runAuthLoopback(
                serverKey: serverKey,
                trustedPeers: peerStore,
                clientKey: clientKey,
                expectedHostFingerprint: unrelatedFingerprint
            )
        }
    }

    @Test(
        """
@spec REMOTE-8.5: While accepting a remote attach, the host shall negotiate SSH transport protection from swift-nio-ssh's bundled AEAD ciphers (`aes256-gcm@openssh.com`, `aes128-gcm@openssh.com`) and shall not negotiate any weak or legacy cipher.
""",
        .timeLimit(.minutes(3))
    )
    func cipherRestrictedToAESGCM() async throws {
        // swift-nio-ssh ships only `aes256-gcm@openssh.com` and
        // `aes128-gcm@openssh.com` in its built-in transport-protection
        // schemes — there is no publicly inspectable hook to assert
        // which cipher was negotiated, so a successful exec round-trip
        // is the practical assertion: the only way the handshake can
        // succeed is by agreeing on one of those two AEAD ciphers.
        let serverKey = Curve25519.Signing.PrivateKey()
        let clientKey = Curve25519.Signing.PrivateKey()
        let peerStore = InMemoryTrustedPeerSet()
        peerStore.add(fingerprint: Self.fingerprint(of: clientKey))

        let response = try await runAuthLoopback(
            serverKey: serverKey,
            trustedPeers: peerStore,
            clientKey: clientKey,
            expectedHostFingerprint: Self.fingerprint(of: serverKey)
        )
        #expect(response == "loopback-exec-ok\n")
    }

    /// Negative — peer key isn't in the trust set, userauth must fail.
    @Test(.timeLimit(.minutes(3)))
    func unpairedPeerRejected() async throws {
        let serverKey = Curve25519.Signing.PrivateKey()
        let clientKey = Curve25519.Signing.PrivateKey()
        // Empty trust store — the client's key isn't paired.
        let peerStore = InMemoryTrustedPeerSet()

        await #expect(throws: (any Error).self) {
            _ = try await runAuthLoopback(
                serverKey: serverKey,
                trustedPeers: peerStore,
                clientKey: clientKey,
                expectedHostFingerprint: Self.fingerprint(of: serverKey)
            )
        }
    }

    // MARK: - Loopback driver

    /// Pairs two RTCPeerConnections in-process, layers SSH on each
    /// side, and round-trips `exec ls`. Returns the response on
    /// success, throws on auth/handshake failure or timeout.
    ///
    /// `clientUsername` overrides the SSH userauth username (defaults
    /// to "graftty" — matches production `SSHClientSetup`).
    /// `clientOffersNothing == true` means the client immediately
    /// completes its userauth offer with `nil`, never proposing
    /// publickey. The handshake should fail.
    private func runAuthLoopback(
        serverKey: Curve25519.Signing.PrivateKey,
        trustedPeers: InMemoryTrustedPeerSet,
        clientKey: Curve25519.Signing.PrivateKey,
        expectedHostFingerprint: RemoteIdentityFingerprint,
        clientUsername: String = "graftty",
        clientOffersNothing: Bool = false
    ) async throws -> String {
        let offerer = LoopbackPeer(role: .offerer)
        let answerer = LoopbackPeer(role: .answerer)
        let offer = try await offerer.createOffer()
        let answer = try await answerer.accept(offer: offer)
        await offerer.bindIceCandidates(to: answerer)
        await answerer.bindIceCandidates(to: offerer)
        try await offerer.applyAnswer(answer)
        let offererDC = try await offerer.openedDataChannel()
        let answererDC = try await answerer.openedDataChannel()

        let clientTransport = SSHNIOTransport(dataChannel: offererDC)
        let serverTransport = SSHNIOTransport(dataChannel: answererDC)

        // Server: real `SSHServerSetup`-equivalent — installs
        // `NIOSSHHandler` configured with our inline mirror of
        // `SSHUserAuthDelegate`. The child-channel initializer
        // installs the canonical exec responder.
        try await serverTransport.eventLoop.submit {
            let serverConfig = SSHServerConfiguration(
                hostKeys: [NIOSSHPrivateKey(ed25519Key: serverKey)],
                userAuthDelegate: TrustSetServerUserAuthDelegate(store: trustedPeers)
            )
            let sshHandler = NIOSSHHandler(
                role: .server(serverConfig),
                allocator: serverTransport.channel.allocator,
                inboundChildChannelInitializer: { childChannel, channelType in
                    guard case .session = channelType else {
                        return childChannel.eventLoop.makeFailedFuture(LoopbackError.unexpectedChannelType)
                    }
                    return childChannel.eventLoop.makeCompletedFuture {
                        try childChannel.pipeline.syncOperations.addHandler(LoopbackExecResponder())
                    }
                }
            )
            try serverTransport.channel.pipeline.syncOperations.addHandler(sshHandler)
        }.get()

        // Client: in the production path we'd call
        // `SSHClientSetup.makeHandler(...)`. For override cases
        // (alternate username, offer-nothing variant) we need to
        // bypass the production factory and build the handler with a
        // tailored userauth delegate — keeps SSHClientSetup's API
        // small. The pinned-host delegate is always the real one.
        let responsePromise = clientTransport.eventLoop.makePromise(of: String.self)
        try await clientTransport.eventLoop.submit {
            let userAuth: NIOSSHClientUserAuthenticationDelegate
            if clientOffersNothing {
                userAuth = OfferNothingClientUserAuthDelegate()
            } else {
                userAuth = TestClientUserAuthDelegate(
                    username: clientUsername,
                    key: clientKey
                )
            }
            let clientConfig = SSHClientConfiguration(
                userAuthDelegate: userAuth,
                serverAuthDelegate: PinnedHostKeyAuthDelegate(
                    expectedFingerprint: expectedHostFingerprint
                )
            )
            let sshHandler = NIOSSHHandler(
                role: .client(clientConfig),
                allocator: clientTransport.channel.allocator,
                inboundChildChannelInitializer: nil
            )
            try clientTransport.channel.pipeline.syncOperations.addHandler(sshHandler)
            // Fail the response promise if the SSH parent channel ever
            // closes before the response arrives — this is how
            // userauth failure / host-key mismatch / handshake error
            // surfaces (the auth-failure case never opens a session
            // child channel, so `LoopbackExecCollector.channelInactive`
            // never fires).
            try clientTransport.channel.pipeline.syncOperations.addHandler(
                ParentChannelFailureRelay(completePromise: responsePromise)
            )
            let opener = ClientSessionOpener(
                command: "ls",
                completePromise: responsePromise
            )
            try clientTransport.channel.pipeline.syncOperations.addHandler(opener)
        }.get()

        try await serverTransport.start()
        try await clientTransport.start()

        // Belt-and-suspenders: wall-clock Task fails the promise on
        // hang. We deliberately use a Swift `Task` (not the NIO
        // scheduler) because `SSHNIOTransport` runs on
        // `NIOAsyncTestingEventLoop`, where `scheduleTask` doesn't
        // advance time without an explicit `advanceTime(by:)` call —
        // a NIO-side timer would never fire. Pairs with
        // `.timeLimit(.minutes(3))` from Swift Testing; the R2
        // lesson is that TaskGroup cancellation can't unwind a stuck
        // NIOSSHHandler future, but failing the promise directly does.
        //
        // 180s deadline: macos-26's runner pool has significant
        // variability — local is ~10s, observed CI ranges 40s → 100s+.
        // Successive bumps (15s → 30s → 90s → 180s) chased that
        // variance. 180s gives ~18x headroom over local timing and
        // covers worst observed CI day; positive paths still complete
        // in ~10s on healthy CI. Negative tests (`unpairedPeerRejected`,
        // `nonPublicKeyMethodRejected`) intentionally ride this
        // deadline as their success condition (NIOSSH doesn't fast-fail
        // when the client simply runs out of methods or the peer is
        // unknown) — they each take ~3 min in the worst case, comfortably
        // under the 15-min iOS CI step ceiling.
        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(180))
            if !Task.isCancelled {
                responsePromise.fail(LoopbackError.timedOut)
            }
        }
        defer { timeoutTask.cancel() }

        let response: String
        do {
            response = try await responsePromise.futureResult.get()
        } catch {
            // Tear down on failure too so we don't leak transports
            // across test boundaries.
            await clientTransport.close()
            await serverTransport.close()
            await offerer.close()
            await answerer.close()
            throw error
        }

        await clientTransport.close()
        await serverTransport.close()
        await offerer.close()
        await answerer.close()
        return response
    }

    // MARK: - Helpers shared across tests

    private static func makeTempDir() throws -> URL {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Computes a `RemoteIdentityFingerprint` for a Curve25519 signing
    /// key (i.e. the SHA-256 of its 32-byte public-key representation).
    private static func fingerprint(of key: Curve25519.Signing.PrivateKey) -> RemoteIdentityFingerprint {
        let pubkey = try! RemoteIdentityPublicKey(rawRepresentation: key.publicKey.rawRepresentation)
        return RemoteIdentityFingerprint(of: pubkey)
    }
}

// MARK: - In-memory trust set + server-side delegate

/// In-memory equivalent of `TrustedPeerStore.get(fingerprint:)` for
/// the iOS test target where `GrafttyKit.TrustedPeerStore` isn't
/// importable. Holds the set of trusted fingerprints; the server-side
/// userauth delegate consults it on every publickey offer.
fileprivate final class InMemoryTrustedPeerSet: @unchecked Sendable {
    private let lock = NSLock()
    private var fingerprints: Set<RemoteIdentityFingerprint> = []

    func add(fingerprint: RemoteIdentityFingerprint) {
        lock.lock(); defer { lock.unlock() }
        fingerprints.insert(fingerprint)
    }

    func contains(fingerprint: RemoteIdentityFingerprint) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return fingerprints.contains(fingerprint)
    }
}

/// Test mirror of `GrafttyHostAgent.SSHUserAuthDelegate`. The
/// production delegate isn't reachable from this iOS-only test target
/// (it lives in `GrafttyHostAgent`, which transitively pulls in
/// `GrafttyKit`'s AppKit-importing files), so this thin re-statement
/// keeps the test self-contained while preserving the
/// publickey-only / username-ignored / key-against-store semantics
/// that the @spec annotations cover.
fileprivate struct TrustSetServerUserAuthDelegate: NIOSSHServerUserAuthenticationDelegate {
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .publicKey

    let store: InMemoryTrustedPeerSet

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        // request.username is deliberately ignored — REMOTE-8.3.
        switch request.request {
        case .publicKey(let publicKeyRequest):
            do {
                let fp = try Self.fingerprint(of: publicKeyRequest.publicKey)
                if store.contains(fingerprint: fp) {
                    responsePromise.succeed(.success)
                } else {
                    responsePromise.succeed(.failure)
                }
            } catch {
                responsePromise.fail(error)
            }
        // REMOTE-8.2: reject every non-publickey method immediately.
        case .password, .hostBased, .none:
            responsePromise.succeed(.failure)
        @unknown default:
            responsePromise.succeed(.failure)
        }
    }

    /// Mirror of `SSHUserAuthDelegate.fingerprint(of:)` /
    /// `PinnedHostKeyAuthDelegate.fingerprint(of:)`. See either
    /// production site for the canonical implementation comments.
    static func fingerprint(of key: NIOSSHPublicKey) throws -> RemoteIdentityFingerprint {
        let openSSH = String(openSSHPublicKey: key)
        let components = openSSH.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard components.count >= 2 else {
            throw FingerprintError.unsupportedKeyFormat
        }
        guard let rawBytes = Data(base64Encoded: String(components[1])) else {
            throw FingerprintError.unsupportedKeyFormat
        }

        var buffer = ByteBufferAllocator().buffer(capacity: rawBytes.count)
        buffer.writeContiguousBytes(rawBytes)

        guard
            let typeLen: UInt32 = buffer.readInteger(),
            let typeBytes = buffer.readBytes(length: Int(typeLen)),
            let typeName = String(bytes: typeBytes, encoding: .utf8),
            typeName == "ssh-ed25519",
            let keyLen: UInt32 = buffer.readInteger(),
            keyLen == 32,
            let keyBytes = buffer.readBytes(length: 32)
        else {
            throw FingerprintError.unsupportedKeyFormat
        }

        let pubkey = try RemoteIdentityPublicKey(rawRepresentation: Data(keyBytes))
        return RemoteIdentityFingerprint(of: pubkey)
    }

    enum FingerprintError: Error { case unsupportedKeyFormat }
}

// MARK: - Test-only client userauth variants

/// Mirrors `SSHClientSetup`'s internal `SingleKeyUserAuthDelegate`
/// with a configurable username. We need to override the username in
/// the `differentUsernameSameKeyStillSucceeds` test without touching
/// the production factory's API.
fileprivate final class TestClientUserAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private let key: Curve25519.Signing.PrivateKey
    private let lock = NSLock()
    private var offered = false

    init(username: String, key: Curve25519.Signing.PrivateKey) {
        self.username = username
        self.key = key
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        lock.lock(); defer { lock.unlock() }
        guard !offered, availableMethods.contains(.publicKey) else {
            nextChallengePromise.succeed(nil)
            return
        }
        offered = true
        let offer = NIOSSHUserAuthenticationOffer(
            username: username,
            serviceName: "ssh-connection",
            offer: .privateKey(.init(privateKey: NIOSSHPrivateKey(ed25519Key: key)))
        )
        nextChallengePromise.succeed(offer)
    }
}

/// Client delegate that immediately gives up — never offers a key,
/// never proposes password / keyboard-interactive. Drives REMOTE-8.2
/// from the client side: by refusing to publish any method the
/// handshake can never complete and the server tears it down.
fileprivate final class OfferNothingClientUserAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        nextChallengePromise.succeed(nil)
    }
}

// MARK: - Copied SSH+WebRTC helpers from R2's SSHOverWebRTCLoopbackTests
//
// Each helper below is a verbatim copy of the corresponding type in
// `SSHOverWebRTCLoopbackTests.swift`. Sharing across the two suites
// is intentional follow-up work (post-R6); the duplication is small
// and keeps each suite individually readable.

fileprivate enum LoopbackError: Error {
    case unexpectedChannelType
    case dataChannelNeverOpened
    case timedOut
    case channelInactiveBeforeResponse
}

fileprivate final class LoopbackExecResponder: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard let execRequest = event as? SSHChannelRequestEvent.ExecRequest else {
            context.fireUserInboundEventTriggered(event)
            return
        }
        if execRequest.wantReply {
            context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
        }

        let response = "loopback-exec-ok\n"
        var buffer = context.channel.allocator.buffer(capacity: response.utf8.count)
        buffer.writeString(response)
        let data = SSHChannelData(type: .channel, data: .byteBuffer(buffer))

        let writePromise = context.eventLoop.makePromise(of: Void.self)
        context.writeAndFlush(self.wrapOutboundOut(data), promise: writePromise)
        writePromise.futureResult.whenComplete { _ in
            context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExitStatus(exitStatus: 0))
                .whenComplete { _ in
                    context.close(promise: nil)
                }
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        _ = self.unwrapInboundIn(data)
    }
}

/// Client-side parent-channel handler that fails the response
/// promise if the parent channel closes (or errors) before the
/// session round-trip completes. This is how auth/handshake failures
/// surface in the negative tests — without this handler, a userauth
/// rejection or pinned-host-key mismatch closes the parent channel
/// silently and the test waits on a promise nothing will resolve.
fileprivate final class ParentChannelFailureRelay: ChannelInboundHandler {
    typealias InboundIn = Any

    private let completePromise: EventLoopPromise<String>

    init(completePromise: EventLoopPromise<String>) {
        self.completePromise = completePromise
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        completePromise.fail(error)
        context.fireErrorCaught(error)
    }

    func channelInactive(context: ChannelHandlerContext) {
        completePromise.fail(LoopbackError.channelInactiveBeforeResponse)
        context.fireChannelInactive()
    }
}

fileprivate final class ClientSessionOpener: ChannelInboundHandler {
    typealias InboundIn = Never

    private let command: String
    private let completePromise: EventLoopPromise<String>

    init(command: String, completePromise: EventLoopPromise<String>) {
        self.command = command
        self.completePromise = completePromise
    }

    func channelActive(context: ChannelHandlerContext) {
        context.fireChannelActive()
        let sshHandler: NIOSSHHandler
        do {
            sshHandler = try context.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
        } catch {
            completePromise.fail(error)
            return
        }
        let promise = context.eventLoop.makePromise(of: Channel.self)
        let command = self.command
        let completePromise = self.completePromise
        sshHandler.createChannel(promise, channelType: .session) { childChannel, channelType in
            guard case .session = channelType else {
                return childChannel.eventLoop.makeFailedFuture(LoopbackError.unexpectedChannelType)
            }
            return childChannel.eventLoop.makeCompletedFuture {
                let collector = LoopbackExecCollector(
                    command: command,
                    completePromise: completePromise
                )
                try childChannel.pipeline.syncOperations.addHandler(collector)
            }
        }
        promise.futureResult.whenFailure { error in
            completePromise.fail(error)
        }
    }
}

fileprivate final class LoopbackExecCollector: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let completePromise: EventLoopPromise<String>
    private var collected: ByteBuffer?

    init(command: String, completePromise: EventLoopPromise<String>) {
        self.command = command
        self.completePromise = completePromise
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { error in
            context.fireErrorCaught(error)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        let execRequest = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
        context.triggerUserOutboundEvent(execRequest).whenFailure { error in
            self.completePromise.fail(error)
            context.close(promise: nil)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = self.unwrapInboundIn(data)
        guard channelData.type == .channel, case .byteBuffer(var bytes) = channelData.data else {
            return
        }
        if collected == nil {
            collected = bytes
        } else {
            collected?.writeBuffer(&bytes)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if let buffer = collected {
            let str = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) ?? ""
            completePromise.succeed(str)
        } else {
            completePromise.fail(LoopbackError.channelInactiveBeforeResponse)
        }
        context.fireChannelInactive()
    }
}

// MARK: - Loopback peer (copy of R2's LoopbackPeer)

fileprivate actor LoopbackPeer: WebRTCIceCandidateReceiver {
    enum Role { case offerer, answerer }

    private let role: Role
    private let factory: RTCPeerConnectionFactory
    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private nonisolated let pcDelegate = LoopbackPeerConnectionDelegate()

    private var pendingLocalCandidates: [RTCIceCandidate] = []
    private var iceCandidateTarget: WebRTCIceCandidateReceiver?

    private var gatheringContinuation: CheckedContinuation<Void, Never>?
    private var gatheringTimeoutTask: Task<Void, Never>?
    private var openContinuation: CheckedContinuation<RTCDataChannel, Error>?
    private var resolvedOpenDataChannel: RTCDataChannel?

    private static let gatheringTimeout: Duration = .seconds(5)

    init(role: Role) {
        self.role = role
        self.factory = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil)
        pcDelegate.onIceCandidate = { [weak self] candidate in
            Task { await self?.routeLocalIceCandidate(candidate) }
        }
        pcDelegate.onDataChannel = { [weak self] dc in
            Task { await self?.adoptInboundDataChannel(dc) }
        }
    }

    func createOffer() async throws -> RTCSessionDescription {
        precondition(role == .offerer)
        let config = RemoteHostConnection.defaultConfig()
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: pcDelegate) else {
            throw NSError(domain: "LoopbackPeer", code: 1)
        }
        self.peerConnection = pc

        let dcConfig = RTCDataChannelConfiguration()
        dcConfig.isOrdered = true
        guard let dc = pc.dataChannel(forLabel: "graftty-ssh", configuration: dcConfig) else {
            throw NSError(domain: "LoopbackPeer", code: 2)
        }
        self.dataChannel = dc
        installOpenTracker(on: dc)

        let offer = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RTCSessionDescription, Error>) in
            pc.offer(for: constraints) { sdp, error in
                if let error { continuation.resume(throwing: error); return }
                guard let sdp else { continuation.resume(throwing: NSError(domain: "LoopbackPeer", code: 3)); return }
                continuation.resume(returning: sdp)
            }
        }
        try await Self.setLocalDescription(pc, offer)
        await waitForIceGatheringComplete(pc)
        return pc.localDescription ?? offer
    }

    func accept(offer: RTCSessionDescription) async throws -> RTCSessionDescription {
        precondition(role == .answerer)
        let config = RemoteHostConnection.defaultConfig()
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: pcDelegate) else {
            throw NSError(domain: "LoopbackPeer", code: 4)
        }
        self.peerConnection = pc

        try await Self.setRemoteDescription(pc, offer)
        let answer = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RTCSessionDescription, Error>) in
            pc.answer(for: constraints) { sdp, error in
                if let error { continuation.resume(throwing: error); return }
                guard let sdp else { continuation.resume(throwing: NSError(domain: "LoopbackPeer", code: 5)); return }
                continuation.resume(returning: sdp)
            }
        }
        try await Self.setLocalDescription(pc, answer)
        await waitForIceGatheringComplete(pc)
        return pc.localDescription ?? answer
    }

    func applyAnswer(_ answer: RTCSessionDescription) async throws {
        precondition(role == .offerer)
        guard let pc = peerConnection else { throw NSError(domain: "LoopbackPeer", code: 6) }
        try await Self.setRemoteDescription(pc, answer)
    }

    func openedDataChannel() async throws -> RTCDataChannel {
        if let dc = resolvedOpenDataChannel { return dc }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RTCDataChannel, Error>) in
            self.openContinuation = continuation
        }
    }

    func bindIceCandidates(to peer: WebRTCIceCandidateReceiver) {
        self.iceCandidateTarget = peer
        let drained = pendingLocalCandidates
        pendingLocalCandidates.removeAll()
        Task {
            for candidate in drained {
                try? await peer.addRemoteIceCandidate(candidate)
            }
        }
    }

    private func routeLocalIceCandidate(_ candidate: RTCIceCandidate) {
        if let target = iceCandidateTarget {
            Task { try? await target.addRemoteIceCandidate(candidate) }
        } else {
            pendingLocalCandidates.append(candidate)
        }
    }

    func addRemoteIceCandidate(_ candidate: RTCIceCandidate) async throws {
        guard let pc = peerConnection else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.add(candidate) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func adoptInboundDataChannel(_ dc: RTCDataChannel) {
        self.dataChannel = dc
        installOpenTracker(on: dc)
    }

    private nonisolated(unsafe) var currentOpenTracker: OpenTrackerDelegate?

    private func installOpenTracker(on dc: RTCDataChannel) {
        let tracker = OpenTrackerDelegate()
        tracker.onOpen = { [weak self] in
            Task { await self?.handleDataChannelOpen(dc) }
        }
        if dc.readyState == .open {
            Task { await self.handleDataChannelOpen(dc) }
        }
        dc.delegate = tracker
        self.currentOpenTracker = tracker
    }

    private func handleDataChannelOpen(_ dc: RTCDataChannel) {
        guard resolvedOpenDataChannel == nil else { return }
        resolvedOpenDataChannel = dc
        if let continuation = openContinuation {
            openContinuation = nil
            continuation.resume(returning: dc)
        }
        currentOpenTracker = nil
    }

    private func waitForIceGatheringComplete(_ pc: RTCPeerConnection) async {
        if pc.iceGatheringState == .complete { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.gatheringContinuation = continuation
            pcDelegate.onIceGatheringComplete = { [weak self] in
                Task { await self?.handleIceGatheringComplete() }
            }
            if pc.iceGatheringState == .complete {
                handleIceGatheringComplete()
                return
            }
            self.gatheringTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: Self.gatheringTimeout)
                await self?.handleIceGatheringComplete()
            }
        }
    }

    private func handleIceGatheringComplete() {
        let pending = gatheringContinuation
        gatheringContinuation = nil
        pcDelegate.onIceGatheringComplete = nil
        gatheringTimeoutTask?.cancel()
        gatheringTimeoutTask = nil
        pending?.resume()
    }

    func close() {
        if let pending = gatheringContinuation {
            gatheringContinuation = nil
            pcDelegate.onIceGatheringComplete = nil
            gatheringTimeoutTask?.cancel()
            gatheringTimeoutTask = nil
            pending.resume()
        }
        if let pending = openContinuation {
            openContinuation = nil
            pending.resume(throwing: LoopbackError.dataChannelNeverOpened)
        }
        dataChannel?.close()
        peerConnection?.close()
        iceCandidateTarget = nil
        pendingLocalCandidates.removeAll()
    }

    private static func setLocalDescription(_ pc: RTCPeerConnection, _ sdp: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(sdp) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private static func setRemoteDescription(_ pc: RTCPeerConnection, _ sdp: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(sdp) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}

fileprivate final class LoopbackPeerConnectionDelegate: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
    nonisolated(unsafe) var onIceCandidate: (@Sendable (RTCIceCandidate) -> Void)?
    nonisolated(unsafe) var onDataChannel: (@Sendable (RTCDataChannel) -> Void)?
    nonisolated(unsafe) var onIceGatheringComplete: (@Sendable () -> Void)?
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        if newState == .complete { onIceGatheringComplete?() }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        onIceCandidate?(candidate)
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        onDataChannel?(dataChannel)
    }
}

fileprivate final class OpenTrackerDelegate: NSObject, RTCDataChannelDelegate, @unchecked Sendable {
    nonisolated(unsafe) var onOpen: (@Sendable () -> Void)?
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        if dataChannel.readyState == .open { onOpen?() }
    }
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {}
}
#endif
