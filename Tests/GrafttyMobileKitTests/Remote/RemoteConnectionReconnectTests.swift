#if canImport(UIKit)
import CryptoKit
import Foundation
import GrafttyProtocol
import NIOCore
import NIOSSH
import Testing
import WebRTC
@testable import GrafttyMobileKit

/// REMOTE-2.1's behavioral substance (W3 Task 4; the spec ID itself
/// lands in W4 — a duplicate spec marker for that ID here would fail
/// `scripts/generate-specs.py`).
///
/// Proves the reconnect loop end-to-end at the `RemoteConnectionCoordinator`
/// layer: connect → invalidate (the same call Task 4 wires into
/// `RootView`'s background scenePhase path) → re-connect, and asserts a
/// SECOND full SSH userauth actually occurred on the host side — not
/// just that `connection(for:)` returned a non-nil value twice. This is
/// what Task-3 finding 1's fix (Task 4, item 1: `SessionClient.live`'s
/// `remoteConnectionProvider` re-consulted per dial) depends on: without
/// a REAL re-negotiation on the far side, re-asking the coordinator
/// would be cosmetic.
///
/// Host-side SSH stack is a fresh `LoopbackPeer` + `SSHNIOTransport` +
/// `NIOSSHHandler` PER negotiation (mirroring what a real
/// `WebRTCHostAgent` does — a completely new `RTCPeerConnection` and SSH
/// handshake for every `POST /v1/rtc/offer`), with a SHARED counting
/// userauth delegate across negotiations so the test can observe how
/// many times the host completed userauth.
@MainActor
@Suite(
    "RemoteConnectionCoordinator — reconnect re-negotiates a SECOND full SSH userauth (REMOTE-2.1 substance, W3 Task 4)",
    .serialized
)
struct RemoteConnectionReconnectTests {

    /// Promoted from the `IpadTodo.swift` inventory entry, whose EARS
    /// text referenced a Noise handshake — this milestone's transport is
    /// SSH-over-WebRTC, not Noise, per REMOTE-2.x, so the wording below
    /// says SSH userauth instead. Also carries REMOTE-2.1's behavioral
    /// substance (that spec ID itself is promoted in W4; asserting it
    /// here too would fail `generate-specs.py`'s duplicate-ID check).
    @Test("""
@spec IPAD-5.2: When the application foregrounds and the biometric gate is satisfied, the application shall rebuild the RemoteHostConnection from signaling onward, completing a fresh SSH userauth before opening any channel.
""", .timeLimit(.minutes(3)))
    func invalidateThenReconnectProducesASecondFullUserauth() async throws {
        let dir = try Self.makeTempDirectory()

        // Pre-generate + persist the client identity BEFORE constructing
        // the coordinator, so its fingerprint is known up front to seed
        // the host-side trust set. `ClientIdentityStore` persists to
        // `directory`; the coordinator's own (separate) instance over
        // the SAME directory reads this identical, already-persisted key
        // back rather than generating a second one.
        let clientKey = try ClientIdentityStore(directory: dir).loadOrGenerateAndPersist()
        let clientFingerprint = Self.fingerprint(
            of: try RemoteIdentityPublicKey(rawRepresentation: clientKey.publicKey.rawRepresentation)
        )

        let serverKey = Curve25519.Signing.PrivateKey()
        let host = try Self.makePairedHost(directory: dir, serverKey: serverKey)

        let userauthCounter = CallCounter()
        let box = ConnectionBox()
        let negotiationCounter = CallCounter()

        let coordinator = RemoteConnectionCoordinator(
            directory: dir,
            signaling: SignalingClient(transport: Self.hostSideSSHTransport(
                serverKey: serverKey,
                trustedClientFingerprint: clientFingerprint,
                userauthCounter: userauthCounter,
                box: box
            )),
            connectionFactory: { key, fp in
                negotiationCounter.increment()
                let connection = RemoteHostConnection(clientKey: key, expectedHostFingerprint: fp)
                box.set(connection)
                return connection
            }
        )

        // First negotiation.
        let first = await coordinator.connection(for: host)
        #expect(first != nil, "first negotiation should succeed")
        #expect(negotiationCounter.count == 1)
        try await Self.pollUntil(timeout: .seconds(15)) { userauthCounter.count >= 1 }

        // Background teardown (the exact call Task 4 wires into
        // `RootView`'s / `WorktreeDetailView`'s scenePhase handling).
        await coordinator.invalidate(host: host)
        #expect(await first?.state == .closed)

        // Foreground rebuild: re-asking the coordinator must re-negotiate
        // from signaling onward — fresh WebRTC, fresh SSH userauth — not
        // reuse or redial the torn-down connection.
        let second = await coordinator.connection(for: host)
        let liveSecond = try #require(second, "reconnect should succeed")
        #expect(liveSecond !== first, "must be a genuinely new connection, not the invalidated one")
        #expect(negotiationCounter.count == 2, "a second WebRTC negotiation must have occurred")
        try await Self.pollUntil(timeout: .seconds(15)) { userauthCounter.count >= 2 }

        await coordinator.invalidate(host: host)
    }

    // MARK: - Host-side SSH transport stub

    /// Fresh answerer + SSH server stack PER `signaling.exchange` call —
    /// each invocation mirrors a completely new `POST /v1/rtc/offer` to
    /// a real host agent. `userauthCounter` is shared across every
    /// invocation so the test can observe a second full userauth on
    /// reconnect.
    private nonisolated static func hostSideSSHTransport(
        serverKey: Curve25519.Signing.PrivateKey,
        trustedClientFingerprint: RemoteIdentityFingerprint,
        userauthCounter: CallCounter,
        box: ConnectionBox
    ) -> SignalingClient.Transport {
        { request, body in
            let offer = try JSONDecoder().decode(SignalingOffer.self, from: body)
            let answerer = LoopbackPeer(role: .answerer)
            let rtcAnswer = try await answerer.accept(offer: RTCSessionDescription(type: .offer, sdp: offer.sdp))
            if let connection = box.get() {
                await connection.bindIceCandidates(to: answerer)
                await answerer.bindIceCandidates(to: connection)
            }
            box.retain(answerer)

            // Fire-and-forget: once the answerer's DataChannel opens
            // (asynchronously, after the offerer applies this answer and
            // ICE completes), build the server-side SSH stack and start
            // it. `SSHNIOTransport.init` reassigns the DataChannel's
            // delegate and buffers any inbound bytes that arrive before
            // `start()` runs, so there's no hard ordering requirement
            // against the client side's own handshake start.
            Task {
                guard let dc = try? await answerer.openedDataChannel() else { return }
                let serverTransport = SSHNIOTransport(dataChannel: dc)
                box.retainTransport(serverTransport)
                do {
                    try await serverTransport.eventLoop.submit {
                        let serverConfig = SSHServerConfiguration(
                            hostKeys: [NIOSSHPrivateKey(ed25519Key: serverKey)],
                            userAuthDelegate: CountingServerUserAuthDelegate(
                                trustedFingerprint: trustedClientFingerprint,
                                counter: userauthCounter
                            )
                        )
                        let sshHandler = NIOSSHHandler(
                            role: .server(serverConfig),
                            allocator: serverTransport.channel.allocator,
                            // No channels needed for this test — it only
                            // asserts userauth completed, not that a
                            // terminal/exec session opened on top.
                            inboundChildChannelInitializer: nil
                        )
                        try serverTransport.channel.pipeline.syncOperations.addHandler(sshHandler)
                    }.get()
                    try await serverTransport.start()
                } catch {
                    // Best-effort: a failure here surfaces as the test's
                    // `pollUntil` timing out, which is diagnostic enough.
                }
            }

            let answer = SignalingAnswer(sdp: rtcAnswer.sdp)
            let data = try JSONEncoder().encode(answer)
            return Self.httpResponseSuccess(for: request, data: data)
        }
    }

    // MARK: - Helpers

    private nonisolated static func httpResponseSuccess(for request: URLRequest, data: Data) -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
    }

    private static func makeTempDirectory() throws -> URL {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Pairs `host` with a pinned host record for `serverKey`, mirroring
    /// what a real pairing flow persists to `PinnedHostStore`.
    private static func makePairedHost(directory: URL, serverKey: Curve25519.Signing.PrivateKey) throws -> Host {
        let hostPublicKey = try RemoteIdentityPublicKey(rawRepresentation: serverKey.publicKey.rawRepresentation)
        let remoteDeviceID = RemoteDeviceID.generate()
        let pinnedStore = PinnedHostStore(directory: directory)
        try pinnedStore.add(PinnedHost(
            id: remoteDeviceID,
            kind: .mac,
            publicKey: hostPublicKey,
            displayName: "Test host",
            pinnedAt: Date(),
            pairingURL: URL(string: "https://host.local:9999")!
        ))
        return Host(
            label: "Test host",
            baseURL: URL(string: "https://host.local:9999")!,
            remoteDeviceID: remoteDeviceID
        )
    }

    private nonisolated static func fingerprint(of key: RemoteIdentityPublicKey) -> RemoteIdentityFingerprint {
        RemoteIdentityFingerprint(of: key)
    }

    private static func pollUntil(
        timeout: Duration,
        interval: Duration = .milliseconds(50),
        condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: interval)
        }
        throw PollTimeout(timeout: timeout)
    }

    private struct PollTimeout: Error, CustomStringConvertible {
        let timeout: Duration
        var description: String { "pollUntil timed out after \(timeout)" }
    }
}

/// Thread-safe call counter — mirrors `RemoteConnectionCoordinatorTests.CallCounter`
/// (copy-don't-extract precedent already established across this test
/// target's loopback suites).
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    func increment() { lock.lock(); _count += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
}

/// Holds the most-recently factory-created `RemoteHostConnection` (so the
/// fake transport can route ICE candidates to/from it), every `LoopbackPeer`
/// answerer created (so they aren't deallocated before their handshake
/// completes), and every server-side `SSHNIOTransport` built (ditto).
/// Test-only plumbing; production has no equivalent.
private final class ConnectionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: RemoteHostConnection?
    private var retainedAnswerers: [LoopbackPeer] = []
    private var retainedTransports: [SSHNIOTransport] = []

    func set(_ connection: RemoteHostConnection) {
        lock.lock(); current = connection; lock.unlock()
    }

    func get() -> RemoteHostConnection? {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func retain(_ answerer: LoopbackPeer) {
        lock.lock(); retainedAnswerers.append(answerer); lock.unlock()
    }

    func retainTransport(_ transport: SSHNIOTransport) {
        lock.lock(); retainedTransports.append(transport); lock.unlock()
    }
}

/// Mirror of `SSHAuthLoopbackTests.TrustSetServerUserAuthDelegate`, plus
/// a shared attempt counter incremented on every successful userauth —
/// this IS the "mirror auth delegate's attempt counter" the reconnect
/// test asserts against.
private struct CountingServerUserAuthDelegate: NIOSSHServerUserAuthenticationDelegate {
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .publicKey

    let trustedFingerprint: RemoteIdentityFingerprint
    let counter: CallCounter

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        switch request.request {
        case .publicKey(let publicKeyRequest):
            do {
                let fp = try Self.fingerprint(of: publicKeyRequest.publicKey)
                if fp == trustedFingerprint {
                    counter.increment()
                    responsePromise.succeed(.success)
                } else {
                    responsePromise.succeed(.failure)
                }
            } catch {
                responsePromise.succeed(.failure)
            }
        case .password, .hostBased, .none:
            responsePromise.succeed(.failure)
        @unknown default:
            responsePromise.succeed(.failure)
        }
    }

    /// Verbatim mirror of `SSHAuthLoopbackTests.TrustSetServerUserAuthDelegate.fingerprint(of:)`.
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

// MARK: - LoopbackPeer (copy of R2/R3's LoopbackPeer — copy-don't-extract precedent)

private actor LoopbackPeer: WebRTCIceCandidateReceiver {
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

private enum LoopbackError: Error {
    case dataChannelNeverOpened
}

private final class LoopbackPeerConnectionDelegate: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
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

private final class OpenTrackerDelegate: NSObject, RTCDataChannelDelegate, @unchecked Sendable {
    nonisolated(unsafe) var onOpen: (@Sendable () -> Void)?
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        if dataChannel.readyState == .open { onOpen?() }
    }
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {}
}
#endif
