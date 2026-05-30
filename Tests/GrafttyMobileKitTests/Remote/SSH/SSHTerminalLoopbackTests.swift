#if canImport(UIKit)
import CryptoKit
import Foundation
import GrafttyProtocol
import NIOCore
import NIOSSH
import Testing
import WebRTC
@testable import GrafttyMobileKit

/// End-to-end SSH-over-WebRTC terminal-session-channel tests.
///
/// Uses R3's `LoopbackPeer` pattern + real `SSHServerSetup`-equivalent
/// + real `SSHClientSetup` + a fake echoing `TerminalByteStream`. The
/// fake replaces the production `ZmxAttachStream` because iOS Simulator
/// doesn't have host binaries — real `zmx attach` integration is
/// verified at the manual TestFlight gate, not in CI.
///
/// `.serialized` per R3 precedent (one SSH-over-WebRTC stack at a time
/// on the iOS Simulator's resource-constrained runtime).
@Suite(
    "SSH-over-WebRTC terminal channel — env+pty+shell + bytes round-trip (R4)",
    .serialized
)
struct SSHTerminalLoopbackTests {

    /// End-to-end: client opens session channel, sends env+pty+shell,
    /// writes "hi\n", server-side echo stream returns "hi\n".
    @Test(.timeLimit(.minutes(3)))
    func bytesRoundTripThroughTerminalSessionChannel() async throws {
        let serverKey = Curve25519.Signing.PrivateKey()
        let clientKey = Curve25519.Signing.PrivateKey()
        let peerStore = InMemoryTrustedPeerSet()
        peerStore.add(fingerprint: Self.fingerprint(of: clientKey))

        let echoFactory: @Sendable (String) async throws -> TerminalByteStream = { _ in
            EchoStream()
        }

        let received = try await runTerminalLoopback(
            serverKey: serverKey,
            trustedPeers: peerStore,
            clientKey: clientKey,
            expectedHostFingerprint: Self.fingerprint(of: serverKey),
            streamFactory: echoFactory,
            sessionName: "alpha",
            outboundBytes: Data("hi\n".utf8)
        )

        #expect(received == Data("hi\n".utf8))
    }

    /// streamFactory throws -> client `receive()` throws on the next
    /// call (channel closes via exit-status: 1 + close on the server).
    @Test(.timeLimit(.minutes(3)))
    func streamFactoryThrowsClosesChannel() async throws {
        let serverKey = Curve25519.Signing.PrivateKey()
        let clientKey = Curve25519.Signing.PrivateKey()
        let peerStore = InMemoryTrustedPeerSet()
        peerStore.add(fingerprint: Self.fingerprint(of: clientKey))

        let failingFactory: @Sendable (String) async throws -> TerminalByteStream = { _ in
            throw FactoryError.notFound
        }

        await #expect(throws: (any Error).self) {
            _ = try await runTerminalLoopback(
                serverKey: serverKey,
                trustedPeers: peerStore,
                clientKey: clientKey,
                expectedHostFingerprint: Self.fingerprint(of: serverKey),
                streamFactory: failingFactory,
                sessionName: "missing",
                outboundBytes: Data("hi\n".utf8),
                responseDeadline: .seconds(10)
            )
        }
    }

    // MARK: - Loopback driver

    private func runTerminalLoopback(
        serverKey: Curve25519.Signing.PrivateKey,
        trustedPeers: InMemoryTrustedPeerSet,
        clientKey: Curve25519.Signing.PrivateKey,
        expectedHostFingerprint: RemoteIdentityFingerprint,
        streamFactory: @escaping @Sendable (String) async throws -> TerminalByteStream,
        sessionName: String,
        outboundBytes: Data,
        responseDeadline: Duration = .seconds(180)
    ) async throws -> Data {
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

        // Server: SSHServerSetup-equivalent with TerminalSessionHandler
        // factory for incoming session channels.
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
                        let h = TerminalSessionHandler(streamFactory: streamFactory)
                        try childChannel.pipeline.syncOperations.addHandler(h)
                    }
                }
            )
            try serverTransport.channel.pipeline.syncOperations.addHandler(sshHandler)
        }.get()

        // Client: real SSHClientSetup. Capture the handler for
        // TerminalSessionClient to use.
        let handlerPromise = clientTransport.eventLoop.makePromise(of: NIOSSHHandler.self)
        try await clientTransport.eventLoop.submit {
            let h = SSHClientSetup.makeHandler(
                clientKey: clientKey,
                expectedHostFingerprint: expectedHostFingerprint,
                allocator: clientTransport.channel.allocator
            )
            try clientTransport.channel.pipeline.syncOperations.addHandler(h)
            handlerPromise.succeed(h)
        }.get()
        let sshHandler = try await handlerPromise.futureResult.get()

        try await serverTransport.start()
        try await clientTransport.start()

        // Open the terminal session channel via TerminalSessionClient.
        let client = TerminalSessionClient(
            parentChannel: clientTransport.channel,
            parentHandler: sshHandler,
            sessionName: sessionName
        )

        // Belt-and-suspenders deadline (same pattern as R3 — wall-clock
        // Task rather than NIO scheduler).
        let deadlineTask = Task { [client] in
            try? await Task.sleep(for: responseDeadline)
            client.close()
        }
        defer { deadlineTask.cancel() }

        try await client.connect()
        try await client.send(.binary(outboundBytes))

        let frame = try await client.receive()
        let received: Data
        switch frame {
        case .binary(let d): received = d
        case .text(let s): received = Data(s.utf8)
        }

        client.close()
        await clientTransport.close()
        await serverTransport.close()
        await offerer.close()
        await answerer.close()

        return received
    }

    private static func fingerprint(of key: Curve25519.Signing.PrivateKey) -> RemoteIdentityFingerprint {
        let pubkey = try! RemoteIdentityPublicKey(rawRepresentation: key.publicKey.rawRepresentation)
        return RemoteIdentityFingerprint(of: pubkey)
    }
}

// MARK: - Fakes / helpers

private enum FactoryError: Error { case notFound }

private final class EchoStream: TerminalByteStream, @unchecked Sendable {
    private let continuation: AsyncStream<Data>.Continuation
    let inboundBytes: AsyncStream<Data>

    init() {
        var cont: AsyncStream<Data>.Continuation!
        self.inboundBytes = AsyncStream { c in cont = c }
        self.continuation = cont
    }

    func send(_ bytes: Data) async throws {
        continuation.yield(bytes)
    }

    func close() async {
        continuation.finish()
    }
}

// MARK: - Inlined TerminalSessionHandler (copy of GrafttyHostAgent's production type)
//
// `TerminalSessionHandler` lives in `GrafttyHostAgent`, which transitively
// pulls in `GrafttyKit`'s AppKit-importing files and is therefore not
// importable from this iOS-only test target. The inline below mirrors the
// production implementation exactly, using `TerminalByteStream` from
// `GrafttyMobileKit` instead of `GrafttyKit`. Per R3's precedent for the
// server-side userauth delegate — copy, don't extract; post-R6 work.

fileprivate final class TerminalSessionHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let streamFactory: @Sendable (String) async throws -> TerminalByteStream
    private var envSessionName: String?
    private var ptyAccepted = false
    private var stream: TerminalByteStream?
    private var inboundForwardingTask: Task<Void, Never>?
    private var isShuttingDown = false

    init(streamFactory: @escaping @Sendable (String) async throws -> TerminalByteStream) {
        self.streamFactory = streamFactory
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard stream != nil else { return }
        let channelData = unwrapInboundIn(data)
        guard case let .byteBuffer(buf) = channelData.data else { return }
        var view = buf
        guard let bytes = view.readBytes(length: view.readableBytes) else { return }
        let snapshot = stream
        Task { [snapshot] in
            try? await snapshot?.send(Data(bytes))
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let envEvent as SSHChannelRequestEvent.EnvironmentRequest:
            if envEvent.name == "GRAFTTY_SESSION" {
                envSessionName = envEvent.value
            }
            if envEvent.wantReply {
                context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
            }

        case let ptyEvent as SSHChannelRequestEvent.PseudoTerminalRequest:
            ptyAccepted = true
            if ptyEvent.wantReply {
                context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
            }

        case let shellEvent as SSHChannelRequestEvent.ShellRequest:
            guard let name = envSessionName else {
                if shellEvent.wantReply {
                    context.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil)
                }
                context.close(promise: nil)
                return
            }
            attach(context: context, sessionName: name, wantReply: shellEvent.wantReply)

        case let winEvent as SSHChannelRequestEvent.WindowChangeRequest:
            guard let snapshot = stream else { return }
            let cols = winEvent.terminalCharacterWidth
            let rows = winEvent.terminalRowHeight
            Task { [snapshot] in
                await snapshot.resize(cols: cols, rows: rows)
            }

        default:
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        isShuttingDown = true
        inboundForwardingTask?.cancel()
        let snapshot = stream
        stream = nil
        Task { [snapshot] in
            await snapshot?.close()
        }
        context.fireChannelInactive()
    }

    private func attach(context: ChannelHandlerContext, sessionName: String, wantReply: Bool) {
        let factory = streamFactory
        let channel = context.channel
        let loop = context.eventLoop
        let pipeline = context.pipeline

        Task { [weak self] in
            do {
                let stream = try await factory(sessionName)
                loop.execute { [weak self] in
                    guard let self else {
                        Task { await stream.close() }
                        return
                    }
                    if self.isShuttingDown {
                        Task { await stream.close() }
                        return
                    }
                    self.stream = stream
                    if wantReply {
                        pipeline.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
                    }
                    self.startInboundForwarding(stream: stream, channel: channel, loop: loop)
                }
            } catch {
                loop.execute {
                    if wantReply {
                        pipeline.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil)
                    }
                    let exit = SSHChannelRequestEvent.ExitStatus(exitStatus: 1)
                    pipeline.triggerUserOutboundEvent(exit, promise: nil)
                    channel.close(promise: nil)
                }
            }
        }
    }

    private func startInboundForwarding(stream: TerminalByteStream, channel: Channel, loop: EventLoop) {
        let task = Task {
            for await chunk in stream.inboundBytes {
                let buffer = channel.allocator.buffer(bytes: chunk)
                let data = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
                loop.execute {
                    channel.writeAndFlush(data, promise: nil)
                }
            }
        }
        inboundForwardingTask = task
    }
}

// MARK: - Copied SSH+WebRTC helpers from R3's SSHAuthLoopbackTests
//
// Each helper below is a verbatim copy of the corresponding type in
// `SSHAuthLoopbackTests.swift`. Per R3's precedent (and the parent
// design's "copy don't extract" approach), the dup is intentional;
// consolidation happens post-R6 when a shared fixture can replace
// both files.

fileprivate final class InMemoryTrustedPeerSet: @unchecked Sendable {
    private let lock = NSLock()
    private var fingerprints: Set<RemoteIdentityFingerprint> = []
    private var lookupError: (any Error)?

    func add(fingerprint: RemoteIdentityFingerprint) {
        lock.lock(); defer { lock.unlock() }
        fingerprints.insert(fingerprint)
    }

    func get(fingerprint: RemoteIdentityFingerprint) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let error = lookupError { throw error }
        return fingerprints.contains(fingerprint)
    }

    func injectLookupError(_ error: any Error) {
        lock.lock(); defer { lock.unlock() }
        lookupError = error
    }
}

fileprivate struct TrustSetServerUserAuthDelegate: NIOSSHServerUserAuthenticationDelegate {
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .publicKey

    let store: InMemoryTrustedPeerSet

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        switch request.request {
        case .publicKey(let publicKeyRequest):
            do {
                let fp = try Self.fingerprint(of: publicKeyRequest.publicKey)
                if try store.get(fingerprint: fp) {
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

fileprivate enum LoopbackError: Error {
    case unexpectedChannelType
    case dataChannelNeverOpened
    case timedOut
    case channelInactiveBeforeResponse
}

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
